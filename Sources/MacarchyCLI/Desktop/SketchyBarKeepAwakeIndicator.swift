import ArgumentParser
import Foundation
import ThemeCore

/// Keep-awake's clock companion: a cup, lit while Macarchy's session runs.
enum SketchyBarKeepAwakeIndicator {
  /// A click runs the menu's toggle: off starts a session until turned off, on stops it.
  static func toggle(_ status: KeepAwakeStatus) -> CompanionToggle {
    let click = ["keep-awake", "toggle"]
    let icon = SketchyBarClockCompanion.keepAwakeIcon
    switch status {
    case .off:
      return CompanionToggle(
        lit: false, olderBarClick: nil, icon: icon,
        detail: "Keep-awake is off. Click to keep the display awake.", click: click)
    case .on(let session):
      return CompanionToggle(
        lit: true, olderBarClick: ["keep-awake", "off"], icon: icon,
        detail: "Keep-awake on \(session.until). Idle screensaver and idle lock won't start. "
          + "Click to turn off.",
        click: click)
    }
  }
}

extension Desktop {
  struct KeepAwakeIndicator: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: SketchyBarClockCompanion.keepAwake.helperCommand, shouldDisplay: false)
    @OptionGroup var options: CompanionToggleOptions

    mutating func run() throws {
      try options.execute(.keepAwake) { root in
        let engine = KeepAwake.live(stateRoot: root)
        return { try SketchyBarKeepAwakeIndicator.toggle(engine.status()) }
      }
    }
  }
}
