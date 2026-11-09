import Darwin
import Foundation

package struct ZedAdapter: Sendable {
  package static let id = "zed"
  package static let outputPath = "generated/zed.json"
  static let rendererVersion = 1
  package static let applicationURL = URL(filePath: "/Applications/Zed.app")

  let root: URL
  let configurationDirectory: URL
  let version: @Sendable () throws -> [Int]
  let validateOwnership: @Sendable (URL) throws -> Void

  package enum Failure: Error, CustomStringConvertible {
    case unsupported(String)
    case drift
    case invalidPublicationReceipt

    package var description: String {
      switch self {
      case .unsupported(let version):
        "Zed requires version 0.122.2 or newer for watched user themes; found \(version)."
      case .drift: "The owned Zed theme member or theme family drifted."
      case .invalidPublicationReceipt: "The Zed family publication receipt is invalid."
      }
    }
  }

  package static func installedVersion() throws -> [Int] {
    try installedVersion(applicationURL: applicationURL)
  }

  package static func installedVersion(applicationURL: URL) throws -> [Int] {
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw AdapterConfigurationError.controlUnavailable("Zed", applicationURL)
    }
    let info = try BoundedRegularFile.read(
      at: applicationURL.appending(path: "Contents/Info.plist")
    ).data
    let object = try PropertyListSerialization.propertyList(from: info, format: nil)
    let value = (object as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "unknown"
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    let numbers = parts.compactMap { Int($0) }
    guard parts.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else {
      throw Failure.unsupported(value)
    }
    try requireSupported(numbers)
    return numbers
  }

  package static func requireSupported(_ version: [Int]) throws {
    guard version.count == 3, version.allSatisfy({ $0 >= 0 }),
      !version.lexicographicallyPrecedes([0, 122, 2])
    else { throw Failure.unsupported(version.map(String.init).joined(separator: ".")) }
  }

  func preflight() throws {
    try Self.requireSupported(version())
    try validateOwnership(configurationDirectory.appending(path: "themes/macarchy.json"))
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      return AdapterInspection(.zed)
    } catch Failure.unsupported(let version) {
      return AdapterInspection(
        .zed, status: .unsupported,
        message: Failure.unsupported(version).description)
    } catch Failure.drift {
      return AdapterInspection(.zed, status: .drifted, message: Failure.drift.description)
    } catch {
      return AdapterInspection(.zed, status: .failed, message: String(describing: error))
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .required) {
      let inspection = inspection()
      guard inspection.status == .ready else {
        let status: AdapterStatus =
          switch inspection.status {
          case .unsupported: .unsupported
          case .drifted: .drifted
          default: .failed
          }
        return AdapterOutcome(status: status, message: inspection.message)
      }
      let data = try Self.activeFamily(root: root)
      let target = configurationDirectory.appending(path: "themes/macarchy.json")
      let parent = try PinnedFilesystem.openDirectory(at: target.deletingLastPathComponent())
      defer { Darwin.close(parent) }
      // Refresh the watched directory entry, not a symlink whose target Zed does not watch.
      try validateOwnership(configurationDirectory.appending(path: "themes/macarchy.json"))
      try PinnedFilesystem.replaceRegularFileAtomically(
        parentDescriptor: parent, name: target.lastPathComponent, url: target,
        data: data, mode: 0o600)
      guard try PinnedFilesystem.readRegularFile(at: target).data == data else {
        throw Failure.drift
      }
      try Self.recordPublication(data, at: target, root: root)
      return AdapterOutcome(
        status: .applied, message: "Zed watches its settings and theme family; live reload.")
    }
  }

  private struct PublicationReceipt: Codable {
    let path: String
    let digest: String
  }

  static func publicationReceiptURL(root: URL) -> URL {
    root.appending(path: "state/zed-family.json")
  }

  /// Persist only after the family rename/readback, and before reporting success. Unlike
  /// generation artifacts, this evidence survives collection after interrupted activation.
  private static func recordPublication(_ data: Data, at target: URL, root: URL) throws {
    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    let url = publicationReceiptURL(root: root)
    let state = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: parent, name: "state", url: url.deletingLastPathComponent(), mode: 0o700)
    defer { Darwin.close(state) }
    try StateFile.write(
      PublicationReceipt(path: target.standardizedFileURL.path, digest: sha256Digest(data)),
      parentDescriptor: state, name: url.lastPathComponent, url: url)
  }

  /// A last-published digest is authority for exactly that owned destination. The active
  /// render also permits retry if publication succeeded but receipt persistence failed.
  package static func matchesPublishedFamily(_ data: Data, at target: URL, root: URL) throws -> Bool
  {
    let receiptData: Data?
    do {
      receiptData = try PinnedFilesystem.readRegularFile(at: publicationReceiptURL(root: root)).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      receiptData = nil
    }
    if let receiptData {
      guard let receipt = try? JSONDecoder().decode(PublicationReceipt.self, from: receiptData),
        receipt.path.hasPrefix("/"), isSHA256Digest(receipt.digest)
      else { throw Failure.invalidPublicationReceipt }
      if receipt.path == target.standardizedFileURL.path, receipt.digest == sha256Digest(data) {
        return true
      }
    }
    do {
      return try data == activeFamily(root: root)
    } catch ReconciliationStatusError.noActiveGeneration {
      return false
    }
  }

  /// Older sealed generations have no Zed artifact. Derive it from their validated
  /// normalized theme without mutating the generation or changing the current pointer.
  package static func activeFamily(root: URL) throws -> Data {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    if manifest.artifacts[outputPath] != nil {
      return try BoundedRegularFile.read(at: manifest.artifactURL(root: root, path: outputPath))
        .data
    }
    let theme = try manifest.normalizedTheme(root: root)
    return Data(
      try render(
        appearance: theme.appearance, semantic: theme.semantic,
        terminal: theme.terminal
      ).utf8)
  }

  package static func render(package: ThemePackage) throws -> String {
    try render(
      appearance: package.appearance, semantic: package.semantic, terminal: package.terminal)
  }

  private static func render(
    appearance: ThemeAppearance, semantic s: SemanticColors, terminal t: TerminalColors
  ) throws -> String {
    var style: [String: Any] = [
      "background": s.background.rawValue,
      "editor.background": s.background.rawValue,
      "editor.foreground": s.text.rawValue,
      "editor.gutter.background": s.background.rawValue,
      "editor.line_number": s.mutedText.rawValue,
      "editor.active_line_number": s.accent.rawValue,
      "editor.active_line.background": s.surface.rawValue,
      "text": s.text.rawValue, "text.muted": s.mutedText.rawValue, "text.accent": s.accent.rawValue,
      "border": s.border.rawValue, "border.variant": s.overlay.rawValue,
      "surface.background": s.surface.rawValue, "elevated_surface.background": s.overlay.rawValue,
      "panel.background": s.surface.rawValue, "title_bar.background": s.surface.rawValue,
      "status_bar.background": s.surface.rawValue, "tab_bar.background": s.surface.rawValue,
      "tab.active_background": s.background.rawValue, "tab.inactive_background": s.surface.rawValue,
      "element.hover": s.overlay.rawValue, "element.selected": s.selection.rawValue,
      "ghost_element.hover": s.overlay.rawValue, "ghost_element.selected": s.selection.rawValue,
      "players": [
        [
          "cursor": t.cursor.rawValue, "background": s.accent.rawValue,
          "selection": s.selection.rawValue,
        ]
      ],
      "error": s.error.rawValue, "warning": s.warning.rawValue,
      "info": s.info.rawValue, "success": s.success.rawValue,
      "terminal.background": t.background.rawValue, "terminal.foreground": t.foreground.rawValue,
    ]
    let hues = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
    for (index, color) in t.ansi.enumerated() {
      style["terminal.ansi.\(index < 8 ? "" : "bright_")\(hues[index % 8])"] = color.rawValue
    }
    var syntax: [String: Any] = [:]
    for (name, color) in [
      "comment": s.mutedText.rawValue, "string": t.ansi[2].rawValue,
      "keyword": t.ansi[5].rawValue, "function": t.ansi[4].rawValue,
      "type": t.ansi[3].rawValue, "number": t.ansi[6].rawValue,
      "constant": t.ansi[1].rawValue, "variable": s.text.rawValue,
    ] { syntax[name] = ["color": color] }
    style["syntax"] = syntax
    let family: [String: Any] = [
      "$schema": "https://zed.dev/schema/themes/v0.2.0.json",
      "name": "Macarchy", "author": "Macarchy",
      "themes": [["name": "Macarchy", "appearance": appearance.rawValue, "style": style]],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: family, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self) + "\n"
  }
}
