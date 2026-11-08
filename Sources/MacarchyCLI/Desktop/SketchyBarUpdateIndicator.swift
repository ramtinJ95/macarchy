import ArgumentParser
import Foundation
import ThemeCore

struct SketchyBarUpdateIndicator: Sendable {
  private static let companion = SketchyBarClockCompanion.update

  let processRunner: ProcessRunner
  let buildInformation: @Sendable () throws -> MacarchyBuildInformation
  let readCache: @Sendable (URL) -> UpdateCacheRead
  let checkIfDue: @Sendable (URL) -> UpdateCheckExecution
  let checkNow: @Sendable (URL) -> UpdateCheckExecution
  let launchReview: @Sendable (URL) throws -> Void

  static let live = Self(
    processRunner: .live,
    buildInformation: RuntimeEnvironment.live.buildInformation,
    readCache: { UpdateCacheStore(root: $0).read() },
    checkIfDue: {
      UpdateChecker(root: $0, httpClient: .live, now: Date.init)
        .check(
          ifStaleOnly: true, freshnessInterval: UpdateCheckPolicy.indicatorCheckInterval,
          failureRetryInterval: UpdateCheckPolicy.indicatorFailedRetryInterval)
    },
    checkNow: {
      UpdateChecker(root: $0, httpClient: .live, now: Date.init).check(ifStaleOnly: false)
    },
    launchReview: { root in
      let runtime = RuntimeEnvironment.live
      let theme = try loadPopupTheme(stateRoot: root, bundledThemesRoot: runtime.builtInThemesURL)
      _ = try MenuTerminal.launch(
        .maintenance, arguments: [MenuMaintenance.commandName, MaintenanceAction.update.rawValue],
        theme: theme, executableURL: runtime.executableURL)
    })

  func execute(
    sender: String, stateRoot: URL, automaticChecksEnabled: Bool,
    accent: String, warning: String
  ) throws {
    switch sender {
    case "mouse.clicked":
      try bar(["--set", Self.companion.item, "popup.drawing=off"])
      if let installed = try installedVersion(),
        UpdateCheckPolicy.newerRelease(in: readCache(stateRoot), than: installed) == nil
      {
        // Without a release to review, a click retries the failed check behind the warning.
        try render(
          installed: installed, cache: .available(checkNow(stateRoot).cache),
          accent: accent, warning: warning)
      } else {
        try launchReview(stateRoot)
      }
      return
    case "mouse.entered":
      try bar(["--set", Self.companion.item, "popup.drawing=on"])
      return
    case "mouse.exited", "mouse.exited.global":
      try bar(["--set", Self.companion.item, "popup.drawing=off"])
      return
    default:
      break
    }

    let installed = try installedVersion()
    let cache =
      installed != nil && automaticChecksEnabled
      ? UpdateCacheRead.available(checkIfDue(stateRoot).cache) : readCache(stateRoot)
    try render(installed: installed, cache: cache, accent: accent, warning: warning)
  }

  private func installedVersion() throws -> StableVersion? {
    try UpdateCheckPolicy.checkableVersion(buildInformation())
  }

  private func render(
    installed: StableVersion?, cache: UpdateCacheRead, accent: String, warning: String
  ) throws {
    guard let installed else {
      try present(
        available: nil, error: "Update checks require a stable Homebrew installation.",
        accent: accent, warning: warning)
      return
    }
    let error: String?
    switch cache {
    case .missing:
      error = nil
    case .invalid(let message):
      error = "Update cache invalid: \(message)"
    case .available(let document):
      error =
        document.lastAttempt.outcome == .failure
        ? "Last update check failed: \(document.lastAttempt.error ?? "unknown error")" : nil
    }
    try present(
      available: UpdateCheckPolicy.newerRelease(in: cache, than: installed), error: error,
      accent: accent, warning: warning)
  }

  private func present(available: String?, error: String?, accent: String, warning: String) throws {
    let visible = available != nil || error != nil
    let icon = available == nil ? "!" : error == nil ? "↻" : "↻!"
    let detail = [available.map { "Macarchy \($0) available" }, error]
      .compactMap { $0 }.joined(separator: " — ")
      .components(separatedBy: .controlCharacters).joined(separator: " ")
    try bar(
      [
        "--set", Self.companion.item, "drawing=\(visible ? "on" : "off")", "icon=\(icon)",
        "icon.color=\(error == nil ? accent : warning)",
        "--set", Self.companion.detailItem, "label=\(String(detail.prefix(240)))",
      ] + (visible ? [] : ["--set", Self.companion.item, "popup.drawing=off"]))
  }

  private var bar: SketchyBarControl {
    SketchyBarControl(processRunner: processRunner) { _, output in
      UpdateIndicatorError(description: "SketchyBar update indicator failed: \(output)")
    }
  }
}

private struct UpdateIndicatorError: Error, CustomStringConvertible {
  let description: String
}

extension Desktop {
  struct UpdateIndicator: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: SketchyBarClockCompanion.update.helperCommand, shouldDisplay: false)
    @Option var sender = "forced"
    @Option var stateRoot: String
    @Option var accent: String
    @Option var warning: String

    mutating func run() throws {
      try SketchyBarUpdateIndicator.live.execute(
        sender: sender, stateRoot: URL(filePath: stateRoot),
        automaticChecksEnabled: UpdateCheckPolicy.automaticChecksEnabled,
        accent: accent, warning: warning)
    }
  }
}
