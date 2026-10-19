import Foundation
import ThemeCore

/// What an always-visible clock companion shows and what a click on it runs. The owning
/// engine's state decides it on every refresh; nothing here is stored.
struct CompanionToggle: Equatable {
  /// Lit in the accent color; otherwise dimmed, whether the feature is off or cannot change.
  let lit: Bool
  /// Bars generated before the toggles drew the item only in one state: keep-awake on, the
  /// microphone muted, idle starts paused. In that state this is the command that reverts it,
  /// which their clicks run instead of a toggle; otherwise nil, and those bars hide the item.
  let olderBarClick: [String]?
  let icon: String
  /// The hover text. It says why when the feature cannot change.
  let detail: String
  /// The `macarchy` command a click runs. It changes the feature through its engine and hints
  /// the bar, or shows the engine's error in an alert, so a feature that cannot change explains
  /// itself and stays as it is.
  let click: [String]
}

/// Drives one always-visible clock companion that toggles its feature on click.
struct SketchyBarCompanionToggle {
  let companion: ClockCompanion
  let stateRoot: URL
  let processRunner: ProcessRunner
  let read: () throws -> CompanionToggle
  /// Starts `macarchy` with these arguments without waiting for it.
  let launch: ([String]) throws -> Void

  /// `muted` is the dimmed color. Bars generated before the toggles omit it; they keep the item
  /// hidden without an `olderBarClick`, and lit with one.
  func execute(sender: String, accent: String, muted: String?) throws {
    switch sender {
    case "mouse.clicked":
      try bar(["--set", companion.item, "popup.drawing=off"])
      let toggle = try read()
      var click = toggle.click
      if muted == nil {
        // An older bar offered only the revert. Its explicit command cannot flip the feature the
        // other way if the state changes before it runs; a stale icon is just hidden.
        guard let revert = toggle.olderBarClick else {
          try present(toggle, accent: accent, muted: muted)
          return
        }
        click = revert
      }
      // The command hints the bar once the feature changes, and that refresh shows the result.
      try launch(click + ["--state-root", stateRoot.path, "--alert-on-error"])
    case "mouse.entered":
      try bar(["--set", companion.item, "popup.drawing=on"])
    case "mouse.exited", "mouse.exited.global":
      try bar(["--set", companion.item, "popup.drawing=off"])
    default:
      try present(read(), accent: accent, muted: muted)
    }
  }

  private func present(_ toggle: CompanionToggle, accent: String, muted: String?) throws {
    let color: String
    switch (muted, toggle.olderBarClick != nil) {
    case (let muted?, _): color = toggle.lit ? accent : muted
    case (nil, true): color = accent
    case (nil, false):
      try bar(["--set", companion.item, "drawing=off", "popup.drawing=off"])
      return
    }
    // SketchyBar's --query output does not escape quotes or backslashes in a label, and the
    // bar's runtime check decodes every item, so one in the hover text fails setup apply.
    let detail = toggle.detail.replacing("\"", with: "'").replacing("\\", with: "/")
    try bar([
      "--set", companion.item, "drawing=on", "icon=\(toggle.icon)", "icon.color=\(color)",
      "--set", companion.detailItem, "label=\(detail)",
    ])
  }

  /// Starts this binary detached, as the action menu does, so the bar script returns at once.
  static func launchMacarchy(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = RuntimeEnvironment.live.executableURL
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    try process.run()
  }

  private func bar(_ arguments: [String]) throws {
    let result = try processRunner.run(
      .init(
        executableURL: SketchyBarCoreRuntimeVerifier.controlURL, arguments: arguments, timeout: 1))
    guard result.terminationStatus == 0 else {
      throw CompanionToggleError(
        description: "SketchyBar \(companion.item) failed: \(result.output)")
    }
  }
}

struct CompanionToggleError: Error, CustomStringConvertible {
  let description: String
}
