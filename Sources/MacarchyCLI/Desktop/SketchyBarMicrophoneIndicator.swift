import ArgumentParser
import Foundation
import ThemeCore

/// The microphone's clock companion: lit and slashed while the default input is muted.
enum SketchyBarMicrophoneIndicator {
  static let item = "macarchy.microphone"
  static let detailItem = "macarchy.microphone.detail"

  /// A click runs the menu's mute toggle on the default input. Without an input that can be
  /// muted, the toggle's error alert says so and nothing changes.
  static func toggle(_ status: MicrophoneStatus) -> CompanionToggle {
    func make(muted: Bool, _ detail: String) -> CompanionToggle {
      CompanionToggle(
        lit: muted, olderBarClick: muted ? ["mic", "unmute"] : nil,
        icon: muted
          ? SketchyBarConfigurationComposer.microphoneMutedIcon
          : SketchyBarConfigurationComposer.microphoneLiveIcon,
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
      commandName: "_microphone-indicator", shouldDisplay: false)
    @Option var sender = "forced"
    @Option var stateRoot: String
    @Option var accent: String
    /// The dimmed color. Bars generated before the toggles omit it.
    @Option var muted: String?

    mutating func run() throws {
      let root = URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
      let engine = Microphone.live(stateRoot: root)
      try SketchyBarCompanionToggle(
        companion: .microphone, stateRoot: root, processRunner: .live,
        read: { try SketchyBarMicrophoneIndicator.toggle(engine.status()) },
        launch: SketchyBarCompanionToggle.launchMacarchy
      )
      .execute(sender: sender, accent: accent, muted: muted)
    }
  }
}
