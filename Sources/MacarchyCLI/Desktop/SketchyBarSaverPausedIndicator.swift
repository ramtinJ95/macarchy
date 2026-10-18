import ArgumentParser
import Foundation
import ThemeCore

/// Idle activation's clock companion: a screensaver lit while idle activation runs, and a pause
/// sign while it is paused. The state comes from idle activation's record and launch agent,
/// never from process names.
enum SketchyBarSaverPausedIndicator {
  static let item = "macarchy.saver-paused"
  static let detailItem = "macarchy.saver-paused.detail"

  /// A click resumes paused idle starts and otherwise runs `saver idle toggle`, which refuses a
  /// launch agent Macarchy did not write with its own error alert.
  static func toggle(_ activation: SaverIdleActivation) -> CompanionToggle {
    let icon = SketchyBarConfigurationComposer.saverIdleIcon
    let click = ["saver", "idle", "toggle"]
    if case .conflict(let plist) = activation.agent {
      return CompanionToggle(
        lit: false, olderBarClick: nil, icon: icon,
        detail: "Warning: \(plist.path) is not the launch agent this Macarchy writes, so the "
          + "idle screensaver cannot change. Click for details.",
        click: click)
    }
    guard let enabled = activation.enabled else {
      let timeout = activation.record?.timeout ?? SaverIdleRecord.defaultTimeout
      return CompanionToggle(
        lit: false, olderBarClick: nil, icon: icon,
        detail: "Idle screensaver is off. Click to start it after \(idleDuration(timeout)) idle.",
        click: click)
    }
    if enabled.paused {
      return CompanionToggle(
        lit: true, olderBarClick: ["saver", "resume"],
        icon: SketchyBarConfigurationComposer.saverPausedIcon,
        detail: "Idle screensaver paused. Click to resume.", click: ["saver", "resume"])
    }
    return CompanionToggle(
      lit: true, olderBarClick: nil, icon: icon,
      detail: "Idle screensaver on: it starts after \(idleDuration(enabled.timeout)) idle. Click "
        + "to turn it off.",
      click: click)
  }
}

extension Desktop {
  struct SaverPausedIndicator: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_saver-paused-indicator", shouldDisplay: false)
    @Option var sender = "forced"
    @Option var stateRoot: String
    @Option var accent: String
    /// The dimmed color. Bars generated before the toggles omit it.
    @Option var muted: String?

    mutating func run() throws {
      let root = URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
      let idle = SaverIdle.live(stateRoot: root)
      try SketchyBarCompanionToggle(
        companion: .saverPaused, stateRoot: root, processRunner: .live,
        read: { try SketchyBarSaverPausedIndicator.toggle(idle.activation()) },
        launch: SketchyBarCompanionToggle.launchMacarchy
      )
      .execute(sender: sender, accent: accent, muted: muted)
    }
  }
}
