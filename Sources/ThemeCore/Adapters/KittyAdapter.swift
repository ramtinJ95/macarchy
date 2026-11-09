import Darwin
import Foundation

enum KittyAdapterError: AdapterBridgeFileError, CustomStringConvertible, Sendable {
  case missingInclude(String)
  case bridgeIsNotRegularFile(URL)
  case bridgeDoesNotMatch(URL)
  case cannotReadBridge(URL, String)
  case cannotPublishBridge(URL, String)

  var description: String {
    switch self {
    case .missingInclude(let directive):
      "Kitty configuration must contain '\(directive)'"
    case .bridgeIsNotRegularFile(let url):
      "Kitty bridge at \(url.path) must be an ordinary regular file"
    case .bridgeDoesNotMatch(let url):
      "Kitty bridge at \(url.path) does not match the active generation"
    case .cannotReadBridge(let url, let cause):
      "Cannot read Kitty bridge at \(url.path): \(cause)"
    case .cannotPublishBridge(let url, let cause):
      "Cannot publish Kitty bridge at \(url.path): \(cause)"
    }
  }
}

package struct KittyAdapter: Sendable {
  private static let killallURL = URL(filePath: "/usr/bin/killall")
  static let id = "kitty"
  package static let bridgePath = "state/adapters/kitty.conf"

  /// The Kitty directive that includes the theme bridge under `stateRoot`.
  package static func includeDirective(stateRoot: URL) -> String {
    "include \(stateRoot.appending(path: bridgePath).path)"
  }

  /// Explicit first-connection preparation; never signals an application.
  /// Existing noncanonical bridges are drift, not permission to replace them.
  package static func prepareBridge(root: URL) throws {
    let desired = try activeConfiguration(root: root)
    let url = root.appending(path: bridgePath)
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 {
      try validatePreparedBridge(root: root)
      return
    }
    guard errno == ENOENT else {
      throw KittyAdapterError.cannotReadBridge(url, "Cannot inspect bridge")
    }
    try AdapterBridgeFile<KittyAdapterError>(url: url).publish(desired)
  }

  package static func validatePreparedBridge(root: URL) throws {
    let desired = try activeConfiguration(root: root)
    let url = root.appending(path: bridgePath)
    guard try AdapterBridgeFile<KittyAdapterError>(url: url).read() == desired else {
      throw KittyAdapterError.bridgeDoesNotMatch(url)
    }
  }

  static let outputPath = "generated/kitty.conf"
  static let rendererVersion = 3

  let root: URL
  let configurationURL: URL
  let includeDirective: String
  let processRunner: ProcessRunner

  private var bridge: AdapterBridgeFile<KittyAdapterError> {
    AdapterBridgeFile(url: root.appending(path: Self.bridgePath))
  }

  func preflight() throws {
    let resolvedConfigurationURL = configurationURL.resolvingSymlinksInPath()
    let configuration = try AdapterConfigurationFile.readUTF8(
      at: resolvedConfigurationURL,
      tooLarge: AdapterConfigurationError.configurationTooLarge(
        "Kitty configuration", configurationURL),
      unreadable: AdapterConfigurationError.cannotReadConfiguration(
        "Kitty configuration", configurationURL)
    )
    guard containsExactLine(includeDirective, in: configuration) else {
      throw KittyAdapterError.missingInclude(includeDirective)
    }
  }

  /// Inspection only: reconciliation reports every preflight failure as drift.
  private var runtime: OrdinaryAdapterRuntime {
    OrdinaryAdapterRuntime(
      .kitty,
      preflight: preflight,
      isIntegrationDrift: Self.isIntegrationDrift
    )
  }

  func inspection() -> AdapterInspection {
    runtime.inspection(readyMessage: nil) {
      do {
        try ActivationLock(root: root).withLock {
          try Self.validatePreparedBridge(root: root)
        }
      } catch ReconciliationStatusError.noActiveGeneration {
        // The include seam can be healthy before the first activation creates a bridge.
      }
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(.kitty) {
      let bridgeOutcome: AdapterOutcome? = try ActivationLock(root: root).withLock {
        do {
          try preflight()
        } catch {
          return AdapterOutcome(status: .drifted, message: String(describing: error))
        }

        let desired = try Self.activeConfiguration(root: root)
        do {
          try bridge.publish(desired)
        } catch {
          return AdapterOutcome(status: .failed, message: String(describing: error))
        }
        return nil
      }
      if let bridgeOutcome { return bridgeOutcome }

      let reload = try processRunner.run(
        ProcessRequest(
          executableURL: Self.killallURL,
          arguments: ["-USR1", "kitty"]
        )
      )
      guard reload.terminationStatus != 0 else {
        return AdapterOutcome(status: .applied)
      }

      let stillRunning = try processRunner.run(
        ProcessRequest(
          executableURL: Self.killallURL,
          arguments: ["-0", "kitty"]
        )
      )
      guard stillRunning.terminationStatus == 0 else {
        return AdapterOutcome(status: .applied)
      }
      return AdapterOutcome(
        status: .failed,
        message: reload.output.isEmpty ? "Kitty rejected its reload signal" : reload.output
      )
    }
  }

  private static func activeConfiguration(root: URL) throws -> Data {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    return try BoundedRegularFile.read(
      at: manifest.artifactURL(root: root, path: Self.outputPath)
    ).data
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case KittyAdapterError.missingInclude, KittyAdapterError.bridgeDoesNotMatch:
      true
    default:
      false
    }
  }

  /// Sets every color option Kitty's bundled themes set, so switching from one of them leaves
  /// none of its colors showing (KittyRenderCoverageTests pins the list).
  static func render(package: ThemePackage) -> String {
    let terminal = package.terminal
    let semantic = package.semantic
    var lines = [
      "# Generated by Macarchy. Do not edit.",
      "foreground \(terminal.foreground.rawValue)",
      "background \(terminal.background.rawValue)",
      "cursor \(terminal.cursor.rawValue)",
      "cursor_text_color \(terminal.background.rawValue)",
      "cursor_trail_color \(terminal.cursor.rawValue)",
      "selection_foreground \(terminal.selectionForeground.rawValue)",
      "selection_background \(terminal.selectionBackground.rawValue)",
      "url_color \(semantic.info.rawValue)",
      // Flashes the selection background, Kitty's default.
      "visual_bell_color none",
      "active_border_color \(semantic.accent.rawValue)",
      "inactive_border_color \(semantic.border.rawValue)",
      "bell_border_color \(semantic.warning.rawValue)",
      "macos_titlebar_color background",
      "wayland_titlebar_color background",
      "tab_bar_background \(semantic.background.rawValue)",
      "tab_bar_margin_color \(semantic.background.rawValue)",
      "active_tab_foreground \(semantic.accent.rawValue)",
      "active_tab_background \(semantic.background.rawValue)",
      "inactive_tab_foreground \(semantic.mutedText.rawValue)",
      "inactive_tab_background \(semantic.background.rawValue)",
      "mark1_foreground \(terminal.background.rawValue)",
      "mark1_background \(semantic.info.rawValue)",
      "mark2_foreground \(terminal.background.rawValue)",
      "mark2_background \(semantic.success.rawValue)",
      "mark3_foreground \(terminal.background.rawValue)",
      "mark3_background \(semantic.warning.rawValue)",
    ]
    lines.append(
      contentsOf: terminal.ansi.enumerated().map {
        "color\($0.offset) \($0.element.rawValue)"
      }
    )
    lines.append(contentsOf: (16..<256).map { "color\($0) \(xtermColor($0))" })
    return lines.joined(separator: "\n") + "\n"
  }

  /// The standard xterm color for palette index 16–255: the 6×6×6 cube, then 24 grays. Set
  /// explicitly so a theme that changed them leaves nothing behind on any Kitty version.
  static func xtermColor(_ index: Int) -> String {
    precondition((16..<256).contains(index))
    let components: [Int]
    if index < 232 {
      let levels = [0, 95, 135, 175, 215, 255]
      let cube = index - 16
      components = [levels[cube / 36], levels[cube / 6 % 6], levels[cube % 6]]
    } else {
      let gray = 8 + 10 * (index - 232)
      components = [gray, gray, gray]
    }
    return "#" + components.map { String(format: "%02x", $0) }.joined()
  }
}
