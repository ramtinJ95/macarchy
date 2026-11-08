import ArgumentParser
import Foundation
import ThemeCore

/// The microphone's clock companion: lit and slashed while the default input is muted.
enum SketchyBarMicrophoneIndicator {
  /// A click runs the menu's mute toggle on the default input. Without an input that can be
  /// muted, the toggle's error alert says so and nothing changes.
  static func toggle(_ status: MicrophoneStatus) -> CompanionToggle {
    func make(muted: Bool, _ detail: String) -> CompanionToggle {
      CompanionToggle(
        lit: muted, olderBarClick: muted ? ["mic", "unmute"] : nil,
        icon: muted
          ? SketchyBarClockCompanion.microphoneMutedIcon
          : SketchyBarClockCompanion.microphoneLiveIcon,
        detail: detail, click: ["mic", "toggle"])
    }
    switch status {
    case .noInput:
      return make(muted: false, "There is no default microphone, so there is nothing to mute.")
    case .input(let device, .live):
      return make(muted: false, "\(device.subject) is live. Click to mute.")
    case .input(let device, .unsupported):
      return make(
        muted: false,
        "\(device.subject) has no mute or input-level control, so it cannot be muted.")
    case .input(let device, .hardwareMuted):
      return make(muted: true, "\(device.subject) muted (hardware mute). Click to unmute.")
    case .input(let device, .silencedByLevel):
      return make(
        muted: true,
        "\(device.subject) silenced by input level, not a hardware mute. Click to restore.")
    }
  }
}

extension Desktop {
  struct MicrophoneIndicator: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: SketchyBarClockCompanion.microphone.helperCommand, shouldDisplay: false)
    @OptionGroup var options: CompanionToggleOptions

    mutating func run() throws {
      try options.execute(.microphone) { root in
        let engine = Microphone.live(stateRoot: root)
        return { try SketchyBarMicrophoneIndicator.toggle(engine.status()) }
      }
    }
  }
}
