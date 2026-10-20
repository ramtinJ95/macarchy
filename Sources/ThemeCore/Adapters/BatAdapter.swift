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
    try CanonicalThemeLink.validate([themeLink]) {
      guard containsExactLine(Self.themeDirective, in: try readConfiguration()) else {
        throw BatAdapterError.missingThemeDirective(Self.themeDirective)
      }
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
      let build = try runBat(["cache", "--build"])
      guard build.terminationStatus == 0 else {
        return AdapterOutcome(
          status: .failed,
          message: build.output.isEmpty ? "bat rejected the generated theme" : build.output
        )
      }
      // bat skips every custom theme, and still exits 0, when one file in its
      // themes directory cannot be read, so only the rebuilt list proves the load.
      let themes = try runBat(["--no-config", "--color=never", "--paging=never", "--list-themes"])
      guard themes.terminationStatus == 0 else {
        return AdapterOutcome(
          status: .failed,
          message: themes.output.isEmpty ? "bat could not list its themes" : themes.output
        )
      }
      guard Self.listsTheme(themes.output) else {
        let themesDirectory = configurationDirectoryURL.appending(path: "themes").path
        return AdapterOutcome(
          status: .drifted,
          message: "bat rebuilt its cache without '\(Self.themeName)', so bat falls back to "
            + "its default theme. Fix or remove the theme file bat could not load in "
            + "\(themesDirectory), then run 'macarchy reconcile bat'."
            + (build.output.isEmpty ? "" : " bat reported: \(build.output)")
        )
      }
      return AdapterOutcome(
        status: .applied,
        message: "bat rebuilt its cache for the active palette"
      )
    }
  }

  private func runBat(_ arguments: [String]) throws -> ProcessResult {
    try processRunner.run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: arguments,
        timeout: 5,
        environmentOverrides: [
          "BAT_CACHE_PATH": cacheDirectoryURL.path,
          "BAT_CONFIG_DIR": configurationDirectoryURL.path,
        ]
      )
    )
  }

  /// Captured output lists one theme per line; some modes append a marker
  /// such as " (default)" to the name.
  private static func listsTheme(_ output: String) -> Bool {
    output.split(whereSeparator: \.isNewline).contains { line in
      let name = line.trimmingCharacters(in: .whitespaces)
      return name == themeName || name.hasPrefix("\(themeName) (")
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
