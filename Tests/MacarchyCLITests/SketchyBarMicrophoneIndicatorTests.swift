import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarMicrophoneIndicatorTests {
  private static let usb = AudioDevice(
    id: 57, name: "USB Mic", identity: AudioDevices.digest("usb-mic-uid"))

  @Test func clickUnmutesTheDefaultInputAndHidesTheIndicator() throws {
    let bar = BarCalls()
    var status = MicrophoneStatus.input(Self.usb, .hardwareMuted)
    var unmuted = 0
    try SketchyBarMicrophoneIndicator(
      processRunner: recorder(bar), status: { status },
      unmute: {
        unmuted += 1
        status = .input(Self.usb, .live)
      }
    ).execute(sender: "mouse.clicked", accent: "accent")
    #expect(unmuted == 1)
    #expect(
      bar.value.withLock { $0 } == [
        ["--set", "macarchy.microphone", "popup.drawing=off"],
        ["--set", "macarchy.microphone", "drawing=off", "popup.drawing=off"],
      ])
  }

  @Test(arguments: [
    ("mouse.entered", "popup.drawing=on"), ("mouse.exited", "popup.drawing=off"),
    ("mouse.exited.global", "popup.drawing=off"),
  ])
  func hoverOnlyTogglesTheDetailPopup(sender: String, popup: String) throws {
    let bar = BarCalls()
    try SketchyBarMicrophoneIndicator(
      processRunner: recorder(bar),
      status: {
        Issue.record("hover must not inspect the microphone")
        return .noInput
      },
      unmute: { Issue.record("hover must not unmute") }
    ).execute(sender: sender, accent: "accent")
    #expect(bar.value.withLock { $0 } == [["--set", "macarchy.microphone", popup]])
  }

  @Test(arguments: ["hardware", "level", "live", "unsupported", "no-input"])
  func refreshShowsOnlyAMutedDefaultInputAndHowItIsMuted(state: String) throws {
    let bar = BarCalls()
    let status: MicrophoneStatus =
      switch state {
      case "hardware": .input(Self.usb, .hardwareMuted)
      case "level": .input(Self.usb, .silencedByLevel)
      case "unsupported": .input(Self.usb, .unsupported)
      case "no-input": .noInput
      default: .input(Self.usb, .live)
      }
    try SketchyBarMicrophoneIndicator(
      processRunner: recorder(bar), status: { status },
      unmute: { Issue.record("a refresh must not unmute") }
    ).execute(sender: "macarchy_microphone_changed", accent: "0xffaabbcc")
    let detail: String? =
      switch state {
      case "hardware": "Microphone \"USB Mic\" muted (hardware mute). Click to unmute."
      case "level":
        "Microphone \"USB Mic\" silenced by input level, not a hardware mute. Click to restore."
      default: nil
      }
    let hidden = ["--set", "macarchy.microphone", "drawing=off", "popup.drawing=off"]
    let expected: [String] =
      detail.map {
        [
          "--set", "macarchy.microphone", "drawing=on", "icon=\u{1002B3}",
          "icon.color=0xffaabbcc", "--set", "macarchy.microphone.detail", "label=\($0)",
        ]
      } ?? hidden
    #expect(bar.value.withLock { $0 } == [expected])
  }

  @Test(arguments: ["unmute", "status", "bar"])
  func failuresPropagateForTheScriptWarning(failing: String) {
    let indicator = SketchyBarMicrophoneIndicator(
      processRunner: ProcessRunner { _ in
        .init(terminationStatus: failing == "bar" ? 1 : 0, output: "")
      },
      status: {
        if failing == "status" { throw MicrophoneError("unreadable input") }
        return .noInput
      },
      unmute: { if failing == "unmute" { throw AudioDeviceError.notSettable } })
    #expect(throws: (any Error).self) {
      try indicator.execute(sender: "mouse.clicked", accent: "accent")
    }
  }

  private final class BarCalls: Sendable {
    let value = Mutex([[String]]())
  }

  private func recorder(_ calls: BarCalls) -> ProcessRunner {
    ProcessRunner { request in
      #expect(request.executableURL == SketchyBarCoreRuntimeVerifier.controlURL)
      calls.value.withLock { $0.append(request.arguments) }
      return .init(terminationStatus: 0, output: "")
    }
  }
}
