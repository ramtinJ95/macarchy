import Foundation
import ThemeCore

struct EnvironmentAlacrittyOwnership: Codable, Equatable, Sendable {
  let path: String
  let originalFileExisted: Bool
  let edit: AlacrittyImportEdit
  enum CodingKeys: String, CodingKey {
    case path, edit
    case originalFileExisted = "original_file_existed"
  }
  var hasValidShape: Bool { path.hasPrefix("/") && edit.hasValidShape }
  static func adopting(_ current: Data?, at url: URL, root: URL) throws -> Self {
    do {
      return Self(
        path: url.path, originalFileExisted: current != nil,
        edit: try AlacrittyImportEdit.adopting(
          current ?? Data(),
          themePath: root.appending(path: AlacrittyAdapter.bridgePath).path))
    } catch {
      throw EnvironmentLifecycleError.blocked("\(url.path): \(error)")
    }
  }
}

typealias EnvironmentAlacrittyFileTransaction = EnvironmentPresetFileTransaction<
  EnvironmentAlacrittyOwnership
>

extension EnvironmentAlacrittyOwnership: EnvironmentPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Alacritty configuration", residueLabel: "Alacritty transaction residue",
    nonRegularMessage: "Alacritty configuration is not an ordinary file")
  static let driftLabel = "Alacritty"
  static let ownershipChangedMessage = "Alacritty ownership changed unexpectedly"
  static let replacementLabel = "Alacritty general.import element"
  static let replacementFailureLabel: String? = nil
  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.alacritty }
  func managed(from current: Data?, at url: URL) throws -> Data {
    guard try AlacrittyImportEdit.adopting(current ?? Data(), themePath: edit.themePath) == edit
    else {
      throw EnvironmentLifecycleError.drift(path)
    }
    return try edit.apply(to: current ?? Data())
  }
  func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    do {
      try edit.validateManaged(data)
      return true
    } catch is AlacrittyImportEdit.Failure { return false }
  }
  func restored(in current: Data, at url: URL) throws -> Data? {
    let result = try edit.restore(current)
    return !originalFileExisted && result.isEmpty ? nil : result
  }
  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return !originalFileExisted }
    return try !AlacrittyImportEdit.imports(Self.filesystem.utf8(data, at: url)).contains(
      edit.themePath)
  }
}

extension EnvironmentProviderInspector {
  func inspectAlacritty(
    enabled: Bool, ownership: EnvironmentAlacrittyOwnership?, home: URL, root: URL
  ) throws -> KeyOwnedInspection<EnvironmentAlacrittyOwnership> {
    guard enabled || ownership != nil else { return (nil, nil, nil) }
    if enabled { try AlacrittyAdapter.requireSupported(alacrittyVersion()) }
    let files = ThemeConsumerPaths.alacrittyConfigurationFiles(home: home)
    let selected = try AlacrittyConfiguration.selectedFile(in: files)
    let url = ownership.map { URL(filePath: $0.path) } ?? selected
    guard !enabled || selected == url else {
      throw EnvironmentLifecycleError.blocked(
        "Alacritty loads \(selected.path), not the owned file \(url.path). Restore/disable before changing configuration priority."
      )
    }
    guard url.path.hasPrefix(home.path + "/"),
      try !hasSymlinkAncestor(url, stoppingAt: home)
    else {
      throw EnvironmentLifecycleError.blocked(
        "Alacritty manual boundary: \(url.path) is outside the selected home or redirected. Move configuration to an ordinary home-contained default file; Macarchy will not write it."
      )
    }
    let evidence = try capture(url, directoryLink: nil)
    let current = try EnvironmentAlacrittyOwnership.filesystem.read(url)
    func entry(_ status: EnvironmentInspectionStatus, _ owner: String, _ message: String)
      -> EnvironmentEntryInspection
    {
      EnvironmentEntryInspection(
        id: "alacritty_configuration", path: url.path, status: status,
        ownership: owner, message: message, evidence: evidence)
    }
    if let ownership {
      guard ownership.edit.themePath == root.appending(path: AlacrittyAdapter.bridgePath).path
      else {
        throw EnvironmentLifecycleError.blocked("Unexpected Alacritty theme import path")
      }
      let exact = try current.map { try ownership.matchesManaged($0, at: url) } ?? false
      return (
        entry(
          exact ? (enabled ? .managed : .restorationRequired) : .drifted, "macarchy",
          exact
            ? "The owned Alacritty import is intact; other configuration stays user-owned."
            : "The owned Alacritty import element was edited, moved or removed."),
        enabled ? ownership : nil, nil
      )
    }
    // A pre-existing bridge has no ownership authority and must not be overwritten.
    for path in AlacrittyAdapter.statePaths
    where FileManager.default.fileExists(
      atPath: root.appending(path: path).path)
    {
      throw EnvironmentLifecycleError.blocked(
        "Unowned Alacritty adapter state exists: \(root.appending(path: path).path)"
      )
    }
    let proposed = try EnvironmentAlacrittyOwnership.adopting(current, at: url, root: root)
    return (
      entry(
        current == nil ? .installRequired : .adoptionRequired, "external",
        "Append one owned general.import element, last; preserve all other Alacritty settings."),
      proposed, evidence
    )
  }
}
