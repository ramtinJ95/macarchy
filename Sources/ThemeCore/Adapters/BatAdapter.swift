import Foundation

enum BatAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case configurationTooLarge(URL)
  case controlUnavailable(URL)
  case missingThemeDirective(String)
  case unexpectedConfigurationLink(URL, actual: String, expected: String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read bat configuration at \(url.path)"
    case .configurationTooLarge(let url):
      "bat configuration at \(url.path) exceeds 1 MiB"
    case .controlUnavailable(let url):
      "bat is not executable at \(url.path)"
    case .missingThemeDirective(let directive):
      "bat configuration must contain '\(directive)'"
    case .unexpectedConfigurationLink(let url, let actual, let expected):
      "bat configuration at \(url.path) is a symbolic link to \(actual); "
        + "only the Macarchy-managed link to \(expected) is accepted"
    }
  }
}

package struct BatAdapter: Sendable {
  static let id = "bat"
  package static let themeName = TextMateThemeArtifact.themeName
  package static let themeDirective = "--theme=\"\(themeName)\""
  package static let themeFileName = "\(themeName).tmTheme"
  /// The only symbolic-link destination accepted for the bat configuration
  /// leaf, relative to the Macarchy state root. Environment apply installs
  /// `~/.config/bat/config` as a link to exactly this path.
  package static let managedConfigurationPath = "environment/current/bat/config"
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/bat")

  let root: URL
  let configurationDirectoryURL: URL
  let cacheDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner

  private var configurationURL: URL {
    configurationDirectoryURL.appending(path: "config")
  }

  private var themeLink: CanonicalThemeLink {
    CanonicalThemeLink(
      url: configurationDirectoryURL.appending(path: "themes/\(Self.themeFileName)"),
      destination: root.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
    )
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw BatAdapterError.controlUnavailable(executableURL)
    }
    try themeLink.validate()

    let configuration = try readConfiguration()
    guard containsExactLine(Self.themeDirective, in: configuration) else {
      throw BatAdapterError.missingThemeDirective(Self.themeDirective)
    }
  }

  private var runtime: OrdinaryAdapterRuntime {
    OrdinaryAdapterRuntime(
      adapterID: Self.id,
      requirement: .required,
      preflight: preflight,
      isIntegrationDrift: Self.isIntegrationDrift
    )
  }

  func inspection() -> AdapterInspection {
    runtime.inspection(readyMessage: "Fresh bat invocations select the Macarchy-managed theme")
  }

  func reconciliation() -> AdapterReconciliation {
    runtime.reconciliation {
      let result = try processRunner.run(
        ProcessRequest(
          executableURL: executableURL,
          arguments: ["cache", "--build"],
          timeout: 5,
          environmentOverrides: [
            "BAT_CACHE_PATH": cacheDirectoryURL.path,
            "BAT_CONFIG_DIR": configurationDirectoryURL.path,
          ]
        )
      )
      guard result.terminationStatus == 0 else {
        return AdapterOutcome(
          status: .failed,
          message: result.output.isEmpty ? "bat rejected the generated theme" : result.output
        )
      }
      return AdapterOutcome(
        status: .applied,
        message: "bat rebuilt its cache for the active palette"
      )
    }
  }

  private func readConfiguration() throws -> String {
    let managedDestination = root.appending(path: Self.managedConfigurationPath)
    return try AdapterConfigurationFile.readUTF8(
      at: configurationURL,
      managedDestination: managedDestination,
      tooLarge: BatAdapterError.configurationTooLarge(configurationURL),
      unreadable: BatAdapterError.cannotReadConfiguration(configurationURL),
      unexpectedLink: {
        BatAdapterError.unexpectedConfigurationLink(
          configurationURL,
          actual: $0,
          expected: managedDestination.path
        )
      }
    )
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case is CanonicalThemeLinkError, BatAdapterError.missingThemeDirective:
      true
    default:
      false
    }
  }
}
