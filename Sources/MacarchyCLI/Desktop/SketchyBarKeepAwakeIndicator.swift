import ArgumentParser
import Foundation
import ThemeCore

/// Keep-awake's clock companion: a cup, lit while Macarchy's session runs.
enum SketchyBarKeepAwakeIndicator {
  static let item = "macarchy.keep-awake"
  static let detailItem = "macarchy.keep-awake.detail"

  /// A click runs the menu's toggle: off starts a session until turned off, on stops it.
  static func toggle(_ status: KeepAwakeStatus) -> CompanionToggle {
    let click = ["keep-awake", "toggle"]
    let icon = SketchyBarConfigurationComposer.keepAwakeIcon
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
      commandName: "_keep-awake-indicator", shouldDisplay: false)
    @Option var sender = "forced"
    @Option var stateRoot: String
    @Option var accent: String
    /// The dimmed color. Bars generated before the toggles omit it.
    @Option var muted: String?

    mutating func run() throws {
      let root = URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
      let engine = KeepAwake.live(stateRoot: root)
      try SketchyBarCompanionToggle(
        companion: .keepAwake, stateRoot: root, processRunner: .live,
        read: { try SketchyBarKeepAwakeIndicator.toggle(engine.status()) },
        launch: SketchyBarCompanionToggle.launchMacarchy
      )
      .execute(sender: sender, accent: accent, muted: muted)
    }
  }
}
