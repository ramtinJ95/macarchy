import Foundation
import TOMLDecoder

enum CodexAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case controlUnavailable(URL)
  case invalidVersion(String)
  case invalidConfiguration(URL)
  case unsupportedVersion(String)
  case wrongThemeSelection(String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Codex configuration at \(url.path)"
    case .controlUnavailable(let url):
      "Codex is not executable at \(url.path)"
    case .invalidVersion(let value):
      "Codex returned an unparseable version: \(value)"
    case .invalidConfiguration(let url):
      "Codex configuration at \(url.path) is not valid TOML"
    case .unsupportedVersion(let value):
      "Codex \(value) is unsupported; version \(CodexAdapter.minimumVersion) or newer is required"
    case .wrongThemeSelection(let expected):
      "Codex [tui] configuration must select theme \"\(expected)\""
    }
  }
}

package struct CodexAdapter: Sendable {
  package static let id = "codex"
  package static let themeName = "macarchy-current"
  package static let selectionTable = "tui"
  package static let selectionKey = "theme"
  package static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/codex")
  package static let minimumVersion = "0.151.0"

  let root: URL
  let configurationDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner

  package init(
    root: URL,
    configurationDirectoryURL: URL,
    executableURL: URL,
    controlIsAvailable: @escaping @Sendable () -> Bool,
    processRunner: ProcessRunner = .live
  ) {
    self.root = root
    self.configurationDirectoryURL = configurationDirectoryURL
    self.executableURL = executableURL
    self.controlIsAvailable = controlIsAvailable
    self.processRunner = processRunner
  }

  private var configurationURL: URL {
    configurationDirectoryURL.appending(path: "config.toml")
  }

  private var themeLink: CanonicalThemeLink {
    CanonicalThemeLink(
      url: configurationDirectoryURL.appending(path: "themes/\(Self.themeName).tmTheme"),
      destination: root.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
    )
  }

  func preflight() throws {
    try requireControl()
    _ = try supportedVersion()
    try validateManagedSeams()
  }

  private func integrationPreflight() throws {
    try requireControl()
    try validateManagedSeams()
  }

  private func requireControl() throws {
    guard controlIsAvailable() else {
      throw CodexAdapterError.controlUnavailable(executableURL)
    }
  }

  private func validateManagedSeams() throws {
    try themeLink.validate()
    guard try selectedTheme() == Self.themeName else {
      throw CodexAdapterError.wrongThemeSelection(Self.themeName)
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

  func inspection(includeRuntimeChecks: Bool = false) -> AdapterInspection {
    OrdinaryAdapterRuntime(
      adapterID: Self.id,
      requirement: .required,
      preflight: includeRuntimeChecks ? preflight : integrationPreflight,
      isIntegrationDrift: Self.isIntegrationDrift
    ).inspection(
      readyMessage: "Fresh Codex TUI sessions use the generated syntax palette"
    )
  }

  func reconciliation() -> AdapterReconciliation {
    runtime.reconciliation {
      AdapterOutcome(
        status: .restartRequired,
        message: "Restart Codex TUI sessions to use the active syntax palette"
      )
    }
  }

  package static func parseVersion(_ output: String) -> [Int]? {
    let tokens = output.split(whereSeparator: \Character.isWhitespace)
    guard tokens.count == 2, tokens[0] == "codex-cli" else { return nil }
    let components = tokens[1].split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    else { return nil }
    let version = components.compactMap { Int($0) }
    return version.count == 3 ? version : nil
  }

  package func supportedVersion() throws -> String {
    let result = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: ["--version"], timeout: 2)
    )
    guard result.terminationStatus == 0, let version = Self.parseVersion(result.output) else {
      throw CodexAdapterError.invalidVersion(result.output)
    }
    let minimum = Self.parseVersion("codex-cli \(Self.minimumVersion)")!
    guard !version.lexicographicallyPrecedes(minimum) else {
      throw CodexAdapterError.unsupportedVersion(result.output)
    }
    return version.map(String.init).joined(separator: ".")
  }

  private func selectedTheme() throws -> String? {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: configurationURL.resolvingSymlinksInPath()).data
    } catch {
      throw CodexAdapterError.cannotReadConfiguration(configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw CodexAdapterError.cannotReadConfiguration(configurationURL)
    }
    do {
      return try TOMLDecoder().decode(Configuration.self, from: configuration).tui?.theme
    } catch {
      throw CodexAdapterError.invalidConfiguration(configurationURL)
    }
  }

  private struct Configuration: Decodable {
    let tui: TUIConfiguration?
  }

  private struct TUIConfiguration: Decodable {
    let theme: String?
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case is CanonicalThemeLinkError, CodexAdapterError.wrongThemeSelection:
      true
    default:
      false
    }
  }
}
