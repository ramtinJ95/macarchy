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
  static let rendererVersion = 2

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

  static func render(package: ThemePackage) -> String {
    var lines = [
      "# Generated by Macarchy. Do not edit.",
      "foreground \(package.terminal.foreground.rawValue)",
      "background \(package.terminal.background.rawValue)",
      "cursor \(package.terminal.cursor.rawValue)",
      "cursor_text_color \(package.terminal.background.rawValue)",
      "selection_foreground \(package.terminal.selectionForeground.rawValue)",
      "selection_background \(package.terminal.selectionBackground.rawValue)",
      "active_border_color \(package.semantic.accent.rawValue)",
      "inactive_border_color \(package.semantic.border.rawValue)",
      "tab_bar_background \(package.semantic.background.rawValue)",
      "active_tab_foreground \(package.semantic.accent.rawValue)",
      "active_tab_background \(package.semantic.background.rawValue)",
      "inactive_tab_foreground \(package.semantic.mutedText.rawValue)",
      "inactive_tab_background \(package.semantic.background.rawValue)",
    ]
    lines.append(
      contentsOf: package.terminal.ansi.enumerated().map {
        "color\($0.offset) \($0.element.rawValue)"
      }
    )
    return lines.joined(separator: "\n") + "\n"
  }
}
