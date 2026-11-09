import Foundation
import ThemeCore

/// Owns just the appended physical line, its original position and a separator we introduced.
/// User settings and includes remain user-owned; no whole-file snapshot is restored over edits.
struct EnvironmentGhosttyOwnership: Codable, Equatable, Sendable {
  let path: String
  let originalFileExisted: Bool
  let lineIndex: Int
  let insertedSeparatorBefore: Bool
  let directive: String

  enum CodingKeys: String, CodingKey {
    case path, directive
    case originalFileExisted = "original_file_existed"
    case lineIndex = "line_index"
    case insertedSeparatorBefore = "inserted_separator_before"
  }

  var hasValidShape: Bool {
    path.hasPrefix("/") && lineIndex >= 0 && lineIndex <= 4 * 1_048_576
      && (!insertedSeparatorBefore || lineIndex > 0)
      && directive.hasPrefix("config-file = ?\"/") && directive.hasSuffix("\"")
      && !directive.contains("\n") && !directive.contains("\r") && !directive.contains("\0")
      && directive.utf8.count <= 16_384
      && (originalFileExisted || (lineIndex == 0 && !insertedSeparatorBefore))
  }

  static func adopting(_ current: Data?, at url: URL, root: URL) throws -> Self {
    if let current { _ = try filesystem.utf8(current, at: url) }
    let bytes = current ?? Data()
    let directive = GhosttyConfiguration.includeDirective(root: root)
    guard
      !bytes.split(separator: 10, omittingEmptySubsequences: false).contains(Data(directive.utf8))
    else {
      throw EnvironmentLifecycleError.blocked(
        "Ghostty already contains an unowned Macarchy include; remove it before reviewed adoption")
    }
    let separator = !bytes.isEmpty && bytes.last != 10
    let count = bytes.filter { $0 == 10 }.count
    let ownership = Self(
      path: url.path, originalFileExisted: current != nil,
      lineIndex: count + (separator ? 1 : 0), insertedSeparatorBefore: separator,
      directive: directive)
    guard ownership.hasValidShape else {
      throw EnvironmentLifecycleError.blocked("Ghostty include path cannot be represented safely")
    }
    return ownership
  }
}

typealias EnvironmentGhosttyFileTransaction = EnvironmentPresetFileTransaction<
  EnvironmentGhosttyOwnership
>

extension EnvironmentGhosttyOwnership: EnvironmentPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Ghostty configuration", residueLabel: "Ghostty transaction residue",
    nonRegularMessage: "Ghostty configuration is not an ordinary file")
  static let driftLabel = "Ghostty"
  static let ownershipChangedMessage = "Ghostty ownership changed unexpectedly"
  static let replacementLabel = "Ghostty config-file include"
  static let replacementFailureLabel: String? = nil

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.ghostty }

  func managed(from current: Data?, at url: URL) throws -> Data {
    var result = current ?? Data()
    if insertedSeparatorBefore { result.append(10) }
    result.append(contentsOf: (directive + "\n").utf8)
    guard result.count <= BoundedRegularFile.maximumSize else {
      throw EnvironmentLifecycleError.blocked(
        "Ghostty include would exceed the bounded configuration size")
    }
    guard try matchesManaged(result, at: url) else { throw EnvironmentLifecycleError.drift(path) }
    return result
  }

  func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    _ = try Self.filesystem.utf8(data, at: url)
    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
    let matches = lines.indices.filter { lines[$0] == Data(directive.utf8) }
    return matches == [lineIndex] && lineIndex < lines.count - 1
  }

  func restored(in current: Data, at url: URL) throws -> Data? {
    guard try matchesManaged(current, at: url) else { throw EnvironmentLifecycleError.drift(path) }
    let lines = current.split(separator: 10, omittingEmptySubsequences: false)
    var start = lines.prefix(lineIndex).reduce(0) { $0 + $1.count + 1 }
    let end = start + directive.utf8.count + 1
    // Preserve the separating LF if the user appended configuration after our line. Operate
    // on bytes: Swift treats CRLF as one Character, but we own only the introduced LF.
    if insertedSeparatorBefore, end == current.count { start -= 1 }
    var result = current
    result.removeSubrange(start..<end)
    return !originalFileExisted && result.isEmpty ? nil : result
  }

  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return !originalFileExisted }
    _ = try Self.filesystem.utf8(data, at: url)
    return !data.split(separator: 10, omittingEmptySubsequences: false).contains(
      Data(directive.utf8))
  }
}

extension EnvironmentProviderInspector {
  func inspectGhostty(
    enabled: Bool, ownership: EnvironmentGhosttyOwnership?, home: URL, root: URL
  ) throws -> KeyOwnedInspection<EnvironmentGhosttyOwnership> {
    guard enabled || ownership != nil else { return (nil, nil, nil) }
    let allFiles = ThemeConsumerPaths.ghosttyConfigurationFiles(home: home)
    // Disabling/restoring must still work after a downgrade or app removal.
    let version = try enabled ? ghosttyVersion() : nil
    let files =
      version.map { GhosttyConfiguration.filesRead(in: allFiles, version: $0) } ?? allFiles
    let notice = version.flatMap {
      GhosttyConfiguration.ignoredFilesMessage(in: allFiles, version: $0)
    }
    let url =
      try ownership.map { URL(filePath: $0.path) }
      ?? GhosttyConfiguration.selectedFile(in: files)
    guard files.contains(url) else {
      throw EnvironmentLifecycleError.blocked(
        "The installed Ghostty version does not load the owned configuration: \(url.path). Disable the preset before adopting a supported file."
      )
    }
    guard url.path.hasPrefix(home.path + "/"),
      try !hasSymlinkAncestor(url, stoppingAt: home)
    else {
      throw EnvironmentLifecycleError.blocked(
        "Ghostty adoption requires an ordinary configuration path within the selected home")
    }
    let evidence = try capture(url, directoryLink: nil)
    let current = try EnvironmentGhosttyOwnership.filesystem.read(url)
    func entry(_ status: EnvironmentInspectionStatus, _ owner: String, _ message: String)
      -> EnvironmentEntryInspection
    {
      EnvironmentEntryInspection(
        id: "ghostty_configuration", path: url.path, status: status,
        ownership: owner,
        message: [message, notice].compactMap { $0 }.joined(separator: " "), evidence: evidence)
    }
    if let ownership {
      let exact = try current.map { try ownership.matchesManaged($0, at: url) } ?? false
      guard ownership.directive == GhosttyConfiguration.includeDirective(root: root) else {
        throw EnvironmentLifecycleError.blocked(
          "Ghostty ownership contains an unexpected theme include")
      }
      return (
        entry(
          exact ? (enabled ? .managed : .restorationRequired) : .drifted, "macarchy",
          exact
            ? "The owned Ghostty include is intact; all other configuration remains user-owned."
            : "The owned Ghostty include was edited, moved or removed."),
        enabled ? ownership : nil, nil
      )
    }
    let proposed = try EnvironmentGhosttyOwnership.adopting(current, at: url, root: root)
    return (
      entry(
        current == nil ? .installRequired : .adoptionRequired, "external",
        "Append one optional config-file include to Ghostty's last existing default file."),
      proposed, evidence
    )
  }
}
