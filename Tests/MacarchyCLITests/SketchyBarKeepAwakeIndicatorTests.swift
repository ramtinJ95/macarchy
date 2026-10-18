import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarKeepAwakeIndicatorTests {
  @Test func clickTurnsOwnedKeepAwakeOffAndHidesTheIndicator() throws {
    let bar = BarCalls()
    var status = KeepAwakeStatus.on(.init(pid: 7, started: 1, expires: nil))
    var turnedOff = 0
    try SketchyBarKeepAwakeIndicator(
      processRunner: recorder(bar), status: { status },
      turnOff: {
        turnedOff += 1
        status = .off
      }
    ).execute(sender: "mouse.clicked", accent: "accent")
    #expect(turnedOff == 1)
    #expect(
      bar.value.withLock { $0 } == [
        ["--set", "macarchy.keep-awake", "popup.drawing=off"],
        ["--set", "macarchy.keep-awake", "drawing=off", "popup.drawing=off"],
      ])
  }

  @Test(arguments: [
    ("mouse.entered", "popup.drawing=on"), ("mouse.exited", "popup.drawing=off"),
    ("mouse.exited.global", "popup.drawing=off"),
  ])
  func hoverOnlyTogglesTheDetailPopup(sender: String, popup: String) throws {
    let bar = BarCalls()
    try SketchyBarKeepAwakeIndicator(
      processRunner: recorder(bar),
      status: {
        Issue.record("hover must not inspect the session")
        return .off
      },
      turnOff: { Issue.record("hover must not turn keep-awake off") }
    ).execute(sender: sender, accent: "accent")
    #expect(bar.value.withLock { $0 } == [["--set", "macarchy.keep-awake", popup]])
  }

  @Test(arguments: ["bounded", "indefinite", "off"])
  func refreshShowsOnlyALiveOwnedSession(state: String) throws {
    let end = Date(timeIntervalSince1970: 1_800_005_400)
    let local = Calendar.current.dateComponents([.hour, .minute], from: end)
    let clock = String(format: "%02d:%02d", local.hour!, local.minute!)
    let bar = BarCalls()
    let status: KeepAwakeStatus =
      state == "off"
      ? .off : .on(.init(pid: 7, started: 1, expires: state == "bounded" ? end : nil))
    try SketchyBarKeepAwakeIndicator(
      processRunner: recorder(bar), status: { status },
      turnOff: { Issue.record("a refresh must not turn keep-awake off") }
    ).execute(sender: "macarchy_keep_awake_changed", accent: "0xffaabbcc")
    let until = state == "bounded" ? "until \(clock)" : "until turned off"
    #expect(
      bar.value.withLock { $0 } == [
        state == "off"
          ? ["--set", "macarchy.keep-awake", "drawing=off", "popup.drawing=off"]
          : [
            "--set", "macarchy.keep-awake", "drawing=on", "icon=☕\u{FE0E}",
            "icon.color=0xffaabbcc", "--set", "macarchy.keep-awake.detail",
            "label=Keep-awake on \(until). Idle screensaver and idle lock won't start. "
              + "Click to turn off.",
          ]
      ])
  }

  @Test(arguments: ["turn-off", "status", "bar"])
  func failuresPropagateForTheScriptWarning(failing: String) {
    let indicator = SketchyBarKeepAwakeIndicator(
      processRunner: ProcessRunner { _ in
        .init(terminationStatus: failing == "bar" ? 1 : 0, output: "")
      },
      status: {
        if failing == "status" { throw KeepAwakeError("unreadable record") }
        return .off
      },
      turnOff: { if failing == "turn-off" { throw KeepAwakeError("still running") } })
    #expect(throws: KeepAwakeError.self) {
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
