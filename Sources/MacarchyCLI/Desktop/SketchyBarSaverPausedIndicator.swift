import ArgumentParser
import Foundation
import ThemeCore

/// Idle activation's clock companion: a screensaver lit while idle activation runs, and a pause
/// sign while it is paused. The state comes from idle activation's record and launch agent,
/// never from process names.
enum SketchyBarSaverPausedIndicator {
  /// A click resumes paused idle starts and otherwise runs `saver idle toggle`, which refuses a
  /// launch agent Macarchy did not write with its own error alert.
  static func toggle(_ activation: SaverIdleActivation) -> CompanionToggle {
    let icon = SketchyBarClockCompanion.saverIdleIcon
    let click = MacarchyInvocation.saverIdleToggle
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
        lit: true, olderBarClick: MacarchyInvocation.saverResume,
        icon: SketchyBarClockCompanion.saverPausedIcon,
        detail: "Idle screensaver paused. Click to resume.", click: MacarchyInvocation.saverResume)
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
      commandName: SketchyBarClockCompanion.saverPaused.helperCommand, shouldDisplay: false)
    @OptionGroup var options: CompanionToggleOptions

    mutating func run() throws {
      try options.execute(.saverPaused) { root in
        let idle = SaverIdle.live(stateRoot: root)
        return { try SketchyBarSaverPausedIndicator.toggle(idle.activation()) }
      }
    }
  }
}
