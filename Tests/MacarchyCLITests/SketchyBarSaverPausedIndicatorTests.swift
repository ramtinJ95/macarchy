import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarSaverPausedIndicatorTests {
  @Test func clickResumesIdleActivationAndHidesTheIndicator() throws {
    let bar = BarCalls()
    var paused = true
    var resumed = 0
    try SketchyBarSaverPausedIndicator(
      processRunner: recorder(bar), paused: { paused },
      resume: {
        resumed += 1
        paused = false
      }
    ).execute(sender: "mouse.clicked", accent: "accent")
    #expect(resumed == 1)
    #expect(
      bar.value.withLock { $0 } == [
        ["--set", "macarchy.saver-paused", "popup.drawing=off"],
        ["--set", "macarchy.saver-paused", "drawing=off", "popup.drawing=off"],
      ])
  }

  @Test(arguments: ["mouse.entered", "mouse.exited", "mouse.exited.global"])
  func hoverOnlyTogglesTheDetailPopup(sender: String) throws {
    let bar = BarCalls()
    try SketchyBarSaverPausedIndicator(
      processRunner: recorder(bar),
      paused: {
        Issue.record("hover must not inspect idle activation")
        return false
      },
      resume: { Issue.record("hover must not resume idle activation") }
    ).execute(sender: sender, accent: "accent")
    let popup = sender == "mouse.entered" ? "popup.drawing=on" : "popup.drawing=off"
    #expect(bar.value.withLock { $0 } == [["--set", "macarchy.saver-paused", popup]])
  }

  /// Only idle activation that runs and is paused shows the icon.
  @Test(arguments: [
    "off", "on", "paused", "paused-not-loaded", "paused-without-agent", "paused-conflict",
  ])
  func refreshShowsTheIconOnlyWhileRunningIdleActivationIsPaused(state: String) throws {
    let paused = SaverIdleRecord(timeout: 300, paused: true)
    let conflict = URL(filePath: "/Users/me/Library/LaunchAgents/saver-idle.plist")
    let activation =
      switch state {
      case "off": SaverIdleActivation(agent: .absent, loaded: false, record: nil)
      case "on":
        SaverIdleActivation(
          agent: .owned, loaded: true, record: SaverIdleRecord(timeout: 300, paused: false))
      case "paused": SaverIdleActivation(agent: .owned, loaded: true, record: paused)
      case "paused-not-loaded": SaverIdleActivation(agent: .owned, loaded: false, record: paused)
      case "paused-without-agent":
        SaverIdleActivation(agent: .absent, loaded: true, record: paused)
      default: SaverIdleActivation(agent: .conflict(conflict), loaded: true, record: paused)
      }
    let bar = BarCalls()
    try SketchyBarSaverPausedIndicator(
      processRunner: recorder(bar), paused: { activation.isPaused },
      resume: { Issue.record("a refresh must not resume idle activation") }
    ).execute(sender: SaverIdle.barEvent, accent: "0xffaabbcc")
    let shown = [
      "--set", "macarchy.saver-paused", "drawing=on", "icon=⏸\u{FE0E}", "icon.color=0xffaabbcc",
      "--set", "macarchy.saver-paused.detail", "label=Idle screensaver paused. Click to resume.",
    ]
    let hidden = ["--set", "macarchy.saver-paused", "drawing=off", "popup.drawing=off"]
    let calls = bar.value.withLock { $0 }
    #expect(calls.count == 1)
    #expect(calls.first == (state == "paused" ? shown : hidden))
  }

  @Test(arguments: ["resume", "state", "bar"])
  func failuresPropagateForTheScriptWarning(failing: String) {
    let indicator = SketchyBarSaverPausedIndicator(
      processRunner: ProcessRunner { _ in
        .init(terminationStatus: failing == "bar" ? 1 : 0, output: "")
      },
      paused: {
        if failing == "state" { throw SaverError("unreadable record") }
        return false
      },
      resume: { if failing == "resume" { throw SaverError("Idle activation is not on") } })
    #expect(throws: SaverError.self) {
      try indicator.execute(sender: "mouse.clicked", accent: "accent")
    }
  }

  @Test func theCompanionSitsLeftOfTheClockAndRefreshesOnIdleChanges() {
    let companion = ClockCompanion.saverPaused
    #expect(companion.side == .left)
    #expect(companion.plugin == "saver-paused")
    #expect(companion.updateFrequency == 30)
    #expect(companion.events.last == "macarchy_saver_idle_changed")
    #expect(companion.events.contains("mouse.clicked"))
    #expect(ClockCompanion.all.last?.item == "macarchy.saver-paused")
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
