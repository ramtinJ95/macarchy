import Foundation
import TOMLDecoder

enum CodexAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case controlUnavailable(URL)
  case invalidConfiguration(URL)
  case wrongThemeSelection(String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Codex configuration at \(url.path)"
    case .controlUnavailable(let url):
      "Codex is not executable at \(url.path)"
    case .invalidConfiguration(let url):
      "Codex configuration at \(url.path) is not valid TOML"
    case .wrongThemeSelection(let expected):
      "Codex [tui] configuration must select theme \"\(expected)\""
    }
  }
}

struct CodexAdapter: Sendable {
  static let id = "codex"
  static let themeName = "macarchy-current"
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/codex")

  let root: URL
  let configurationDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool

  private var configurationURL: URL {
    configurationDirectoryURL.appending(path: "config.toml")
  }

  private var themeLink: CanonicalThemeLink {
    CanonicalThemeLink(
      url: configurationDirectoryURL.appending(path: "themes/\(Self.themeName).tmTheme"),
      destination: root.appending(path: "current/\(BatAdapter.outputPath)")
    )
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw CodexAdapterError.controlUnavailable(executableURL)
    }
    try themeLink.validate()
    guard try selectedTheme() == Self.themeName else {
      throw CodexAdapterError.wrongThemeSelection(Self.themeName)
    }
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message: "Fresh Codex TUI sessions use the generated syntax palette"
      )
    } catch {
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        status: Self.isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .required) {
      do {
        try preflight()
        return AdapterOutcome(
          status: .restartRequired,
          message: "Restart Codex TUI sessions to use the active syntax palette"
        )
      } catch {
        return AdapterOutcome(
          status: Self.isIntegrationDrift(error) ? .drifted : .failed,
          message: String(describing: error)
        )
      }
    }
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
