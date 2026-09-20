import ArgumentParser
import Foundation
import ThemeCore

struct SketchyBarUpdateIndicator: Sendable {
  static let item = "macarchy.update"
  static let detailItem = "macarchy.update.detail"
  static let checkInterval: TimeInterval = 6 * 60 * 60

  let processRunner: ProcessRunner
  let buildInformation: @Sendable () throws -> MacarchyBuildInformation
  let readCache: @Sendable (URL) -> UpdateCacheRead
  let checkIfDue: @Sendable (URL) -> UpdateCheckExecution
  let launchReview: @Sendable (URL) throws -> Void

  static let live = Self(
    processRunner: .live,
    buildInformation: RuntimeEnvironment.live.buildInformation,
    readCache: { UpdateCacheStore(root: $0).read() },
    checkIfDue: {
      UpdateChecker(root: $0, httpClient: .live, now: Date.init)
        .check(ifStaleOnly: true, freshnessInterval: checkInterval)
    },
    launchReview: { root in
      let runtime = RuntimeEnvironment.live
      let theme = try loadPopupTheme(stateRoot: root, bundledThemesRoot: runtime.builtInThemesURL)
      _ = try MenuMaintenance.launch(.update, theme: theme, executableURL: runtime.executableURL)
    })

  func execute(
    sender: String, stateRoot: URL, automaticChecksEnabled: Bool,
    accent: String, warning: String
  ) throws {
    switch sender {
    case "mouse.clicked":
      try bar(["--set", Self.item, "popup.drawing=off"])
      try launchReview(stateRoot)
      return
    case "mouse.entered":
      try bar(["--set", Self.item, "popup.drawing=on"])
      return
    case "mouse.exited", "mouse.exited.global":
      try bar(["--set", Self.item, "popup.drawing=off"])
      return
    default:
      break
    }

    let build = try buildInformation()
    guard build.installation == .homebrew, let installed = StableVersion(build.version) else {
      try present(
        available: nil, error: "Update checks require a stable Homebrew installation.",
        accent: accent, warning: warning)
      return
    }
    let cache =
      automaticChecksEnabled
      ? UpdateCacheRead.available(checkIfDue(stateRoot).cache) : readCache(stateRoot)
    let available: String?
    let error: String?
    switch cache {
    case .missing:
      available = nil
      error = nil
    case .invalid(let message):
      available = nil
      error = "Update cache invalid: \(message)"
    case .available(let document):
      if let release = document.lastSuccess?.release,
        let upstream = StableVersion(release.version), upstream > installed
      {
        available = release.version
      } else {
        available = nil
      }
      error =
        document.lastAttempt.outcome == .failure
        ? "Last update check failed: \(document.lastAttempt.error ?? "unknown error")" : nil
    }
    try present(available: available, error: error, accent: accent, warning: warning)
  }

  private func present(available: String?, error: String?, accent: String, warning: String) throws {
    let visible = available != nil || error != nil
    let icon = available == nil ? "!" : error == nil ? "↻" : "↻!"
    let detail = [available.map { "Macarchy \($0) available" }, error]
      .compactMap { $0 }.joined(separator: " — ")
      .components(separatedBy: .controlCharacters).joined(separator: " ")
    try bar(
      [
        "--set", Self.item, "drawing=\(visible ? "on" : "off")", "icon=\(icon)",
        "icon.color=\(error == nil ? accent : warning)",
        "--set", Self.detailItem, "label=\(String(detail.prefix(240)))",
      ] + (visible ? [] : ["--set", Self.item, "popup.drawing=off"]))
  }

  private func bar(_ arguments: [String]) throws {
    let result = try processRunner.run(
      .init(
        executableURL: SketchyBarCoreRuntimeVerifier.controlURL, arguments: arguments, timeout: 1))
    guard result.terminationStatus == 0 else {
      throw UpdateIndicatorError(
        description: "SketchyBar update indicator failed: \(result.output)")
    }
  }
}

private struct UpdateIndicatorError: Error, CustomStringConvertible {
  let description: String
}

extension Desktop {
  struct UpdateIndicator: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_update-indicator", shouldDisplay: false)
    @Option var sender = "forced"
    @Option var stateRoot: String
    @Option var accent: String
    @Option var warning: String

    mutating func run() throws {
      try SketchyBarUpdateIndicator.live.execute(
        sender: sender, stateRoot: URL(filePath: stateRoot),
        automaticChecksEnabled: ProcessInfo.processInfo.environment[
          "MACARCHY_DISABLE_UPDATE_CHECKS"] != "1",
        accent: accent, warning: warning)
    }
  }
}
