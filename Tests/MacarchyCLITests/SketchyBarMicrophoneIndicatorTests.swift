import ArgumentParser
import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarMicrophoneIndicatorTests {
  private static let usb = AudioDevice(
    id: 57, name: "USB Mic", identity: AudioDevices.digest("usb-mic-uid"))

  /// Muted shows the slashed microphone lit with how it is muted; anything else shows the
  /// microphone dimmed, with why it cannot be muted when that applies.
  @Test(arguments: ["hardware", "level", "live", "unsupported", "no-input"])
  func refreshAlwaysDrawsTheMicrophoneLitOnlyWhileMuted(state: String) throws {
    let status = Self.status(state)
    let run = try CompanionToggleHarness.run(
      .microphone, sender: Microphone.barEvent,
      read: { SketchyBarMicrophoneIndicator.toggle(status) })
    let detail =
      switch state {
      case "hardware": "Microphone 'USB Mic' muted (hardware mute). Click to unmute."
      case "level":
        "Microphone 'USB Mic' silenced by input level, not a hardware mute. Click to restore."
      case "live": "Microphone 'USB Mic' is live. Click to mute."
      case "unsupported":
        "Microphone 'USB Mic' has no mute or input-level control, so it cannot be muted."
      default: "There is no default microphone, so there is nothing to mute."
      }
    let muted = ["hardware", "level"].contains(state)
    #expect(
      run.bar == [
        [
          "--set", "macarchy.microphone", "drawing=on",
          "icon=\(muted ? "\u{1002B3}" : "\u{1002B1}")",
          "icon.color=\(muted ? CompanionToggleHarness.accent : CompanionToggleHarness.muted)",
          "--set", "macarchy.microphone.detail", "label=\(detail)",
        ]
      ])
  }

  /// Every state runs the menu's mute toggle. Without a default input, or with one that has
  /// neither control, the toggle fails with its alert and changes nothing (see MicrophoneTests).
  @Test(arguments: ["hardware", "level", "live", "unsupported", "no-input"])
  func clickRunsTheMicrophoneToggleInEveryState(state: String) throws {
    let status = Self.status(state)
    let run = try CompanionToggleHarness.run(
      .microphone, sender: "mouse.clicked",
      read: { SketchyBarMicrophoneIndicator.toggle(status) })
    #expect(
      run.launched == [
        [
          "mic", "toggle", "--state-root", CompanionToggleHarness.stateRoot.path,
          "--alert-on-error",
        ]
      ])
  }

  /// Bars generated before the toggles still show the microphone only while it is muted.
  @Test(arguments: ["hardware", "level", "live", "unsupported", "no-input"])
  func olderBarsShowTheMicrophoneOnlyWhileMuted(state: String) throws {
    let status = Self.status(state)
    let run = try CompanionToggleHarness.run(
      .microphone, sender: Microphone.barEvent, muted: nil,
      read: { SketchyBarMicrophoneIndicator.toggle(status) })
    #expect(
      (run.bar.first?.contains("drawing=on") == true) == ["hardware", "level"].contains(state))
    #expect(
      SketchyBarMicrophoneIndicator.toggle(status).olderBarClick
        == (["hardware", "level"].contains(state) ? ["mic", "unmute"] : nil))
  }

  @Test func theHelperAcceptsOlderAndCurrentBarArguments() throws {
    let base = ["--state-root", "/Users/me/.config/macarchy", "--accent", "0xffaabbcc"]
    #expect(try Desktop.MicrophoneIndicator.parse(base).muted == nil)
    #expect(
      try Desktop.MicrophoneIndicator.parse(base + ["--muted", "0xff585b70"]).muted
        == "0xff585b70")
  }

  private static func status(_ state: String) -> MicrophoneStatus {
    switch state {
    case "hardware": .input(usb, .hardwareMuted)
    case "level": .input(usb, .silencedByLevel)
    case "unsupported": .input(usb, .unsupported)
    case "no-input": .noInput
    default: .input(usb, .live)
    }
  }
}
