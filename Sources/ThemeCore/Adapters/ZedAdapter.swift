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

    package var description: String {
      switch self {
      case .unsupported(let version):
        "Zed requires version 0.122.2 or newer for watched user themes; found \(version)."
      case .drift: "The owned Zed theme member or theme family drifted."
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
      let source = StateLayout(root: root).currentThemeArtifact(Self.outputPath)
      let data = try BoundedRegularFile.read(at: source).data
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
      return AdapterOutcome(
        status: .applied, message: "Zed watches its settings and theme family; live reload.")
    }
  }

  /// Only exact, validated generation artifacts count as Macarchy-rendered families. Merely
  /// retaining our name/author after editing a color does not authorize replacement or deletion.
  package static func isRenderedFamily(_ data: Data, root: URL) throws -> Bool {
    let directory = root.appending(path: "generations")
    guard FileManager.default.fileExists(atPath: directory.path) else { return false }
    for generation in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).sorted(by: { $0.path < $1.path })
    where generation.lastPathComponent.hasPrefix("g-") {
      guard (try? BoundedRegularFile.read(at: generation.appending(path: outputPath)).data) == data,
        let manifest = try? ThemeGenerationReader.manifest(in: generation, policy: .published),
        manifest.rendererVersions[Self.id] != nil
      else { continue }
      return true
    }
    return false
  }

  package static func render(package: ThemePackage) throws -> String {
    let s = package.semantic
    let t = package.terminal
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
      "themes": [["name": "Macarchy", "appearance": package.appearance.rawValue, "style": style]],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: family, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self) + "\n"
  }
}
