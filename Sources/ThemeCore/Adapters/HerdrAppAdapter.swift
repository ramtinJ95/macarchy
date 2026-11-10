import Darwin
import Foundation

package struct HerdrAppAdapter: Sendable {
  package static let id = "herdr-app"
  package static let outputPath = "generated/herdr-app.json"
  static let rendererVersion = 1
  package static let themeName = "macarchy-current"
  package static var applicationURL: URL {
    applicationURL(home: FileManager.default.homeDirectoryForCurrentUser)
  }
  package static func applicationURL(home: URL) -> URL {
    let shared = URL(filePath: "/Applications/Herdr.app")
    return FileManager.default.fileExists(atPath: shared.path)
      ? shared : home.appending(path: "Applications/Herdr.app")
  }

  let root: URL
  let configurationDirectory: URL
  let version: @Sendable () throws -> [Int]
  let validateOwnership: @Sendable (URL) throws -> Void

  package enum Failure: Error, CustomStringConvertible {
    case unsupported(String)
    case drift
    case unsupportedHome(String)

    package var description: String {
      switch self {
      case .unsupported(let version):
        "Herdr app requires version 0.1.14 or newer for watched user themes; found \(version)."
      case .unsupportedHome(let home):
        "Herdr app uses HERDR_APP_HOME=\(home); this preset supports only ~/.config/herdr-app. No files were changed."
      case .drift: "The owned Herdr app theme member or theme palette drifted."
      }
    }
  }

  package static func installedVersion() throws -> [Int] {
    try installedVersion(applicationURL: applicationURL)
  }

  package static func installedVersion(applicationURL: URL) throws -> [Int] {
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw AdapterConfigurationError.controlUnavailable("Herdr app", applicationURL)
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
      !version.lexicographicallyPrecedes([0, 1, 14])
    else { throw Failure.unsupported(version.map(String.init).joined(separator: ".")) }
  }

  package static func requireConfigurationHome(
    _ directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    if let value = environment["HERDR_APP_HOME"], !value.isEmpty,
      !value.hasPrefix("/")
        || URL(filePath: value).standardizedFileURL != directory.standardizedFileURL
    {
      throw Failure.unsupportedHome(value)
    }
  }

  func preflight() throws {
    try Self.requireConfigurationHome(configurationDirectory)
    try Self.requireSupported(version())
    try validateOwnership(configurationDirectory.appending(path: "themes/macarchy-current.json"))
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      return AdapterInspection(.herdrApp)
    } catch Failure.unsupported(let version) {
      return AdapterInspection(
        .herdrApp, status: .unsupported,
        message: Failure.unsupported(version).description)
    } catch Failure.drift {
      return AdapterInspection(.herdrApp, status: .drifted, message: Failure.drift.description)
    } catch {
      return AdapterInspection(.herdrApp, status: .failed, message: String(describing: error))
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
      return try ActivationLock(root: root).withLock {
        try preflight()
        let data = try Self.activePalette(root: root)
        let target = configurationDirectory.appending(path: "themes/macarchy-current.json")
        let parent = try PinnedFilesystem.openDirectory(at: target.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        // Refresh the watched directory entry, not a symlink whose target Herdr app does not watch.
        try validateOwnership(
          configurationDirectory.appending(path: "themes/macarchy-current.json"))
        try PinnedFilesystem.replaceRegularFileAtomically(
          parentDescriptor: parent, name: target.lastPathComponent, url: target,
          data: data, mode: 0o600)
        guard try PinnedFilesystem.readRegularFile(at: target).data == data else {
          throw Failure.drift
        }
        try Self.recordPublication(data, at: target, root: root)
        return AdapterOutcome(
          status: .applied,
          message:
            "Published Herdr app’s watched palette; live reload unless a layout or theme-picker override takes precedence."
        )
      }
    }
  }

  static func publicationReceiptURL(root: URL) -> URL {
    root.appending(path: "state/herdr-app-palette.json")
  }

  private static func recordPublication(_ data: Data, at target: URL, root: URL) throws {
    try WatchedThemePublication.recordPublication(
      data, at: target, root: root, receiptURL: publicationReceiptURL(root: root))
  }

  package static func matchesPublishedPalette(_ data: Data, at target: URL, root: URL) throws
    -> Bool
  {
    try WatchedThemePublication.matchesPublished(
      data, at: target, receiptURL: publicationReceiptURL(root: root),
      active: { try activePalette(root: root) })
  }

  /// Older sealed generations have no Herdr app artifact. Derive it from their validated
  /// normalized theme without mutating the generation or changing the current pointer.
  package static func activePalette(root: URL) throws -> Data {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    if manifest.artifacts[outputPath] != nil {
      return try BoundedRegularFile.read(at: manifest.artifactURL(root: root, path: outputPath))
        .data
    }
    let theme = try manifest.normalizedTheme(root: root)
    return Data(
      try render(
        semantic: theme.semantic,
        terminal: theme.terminal
      ).utf8)
  }

  package static func render(package: ThemePackage) throws -> String {
    try render(
      semantic: package.semantic, terminal: package.terminal)
  }

  private static func render(
    semantic s: SemanticColors, terminal t: TerminalColors
  ) throws -> String {
    let colors: [String: String] = [
      "background": t.background.rawValue, "terminal_foreground": t.foreground.rawValue,
      "canvas": s.background.rawValue, "chrome": s.surface.rawValue,
      "surface": s.surface.rawValue, "popover": s.overlay.rawValue,
      "raised": s.overlay.rawValue, "hover": s.overlay.rawValue,
      "selected": s.selection.rawValue, "selection": s.selection.rawValue,
      "border": s.border.rawValue, "input": s.border.rawValue, "ring": s.accent.rawValue,
      "foreground": s.text.rawValue, "muted": s.mutedText.rawValue,
      "dim": s.mutedText.rawValue, "accent": s.accent.rawValue,
      "accent_foreground": s.background.rawValue, "solid": s.accent.rawValue,
      "solid_foreground": s.background.rawValue,
      "working": s.warning.rawValue, "blocked": s.error.rawValue,
      "done": s.success.rawValue, "idle": s.mutedText.rawValue,
      "unknown": s.mutedText.rawValue,
    ]
    let palette: [String: Any] = [
      "background": t.background.rawValue, "foreground": t.foreground.rawValue,
      "cursor": t.cursor.rawValue, "selection": t.selectionBackground.rawValue,
      "ansi": t.ansi.map(\.rawValue), "colors": colors,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: palette, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self) + "\n"
  }
}
