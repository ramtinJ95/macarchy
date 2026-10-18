import ArgumentParser
import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarKeepAwakeIndicatorTests {
  @Test(arguments: ["bounded", "indefinite", "off"])
  func refreshAlwaysDrawsTheCupLitOnlyWhileASessionRuns(state: String) throws {
    let end = Date(timeIntervalSince1970: 1_800_005_400)
    let local = Calendar.current.dateComponents([.hour, .minute], from: end)
    let clock = String(format: "%02d:%02d", local.hour!, local.minute!)
    let status = Self.status(state, expires: end)
    let run = try CompanionToggleHarness.run(
      .keepAwake, sender: KeepAwake.barEvent,
      read: { SketchyBarKeepAwakeIndicator.toggle(status) })
    let until = state == "bounded" ? "until \(clock)" : "until turned off"
    let detail =
      state == "off"
      ? "Keep-awake is off. Click to keep the display awake."
      : "Keep-awake on \(until). Idle screensaver and idle lock won't start. Click to turn off."
    let color = state == "off" ? CompanionToggleHarness.muted : CompanionToggleHarness.accent
    #expect(
      run.bar == [
        [
          "--set", "macarchy.keep-awake", "drawing=on", "icon=☕\u{FE0E}", "icon.color=\(color)",
          "--set", "macarchy.keep-awake.detail", "label=\(detail)",
        ]
      ])
  }

  /// Off starts a session until turned off and on stops it, like the menu's toggle.
  @Test(arguments: ["bounded", "indefinite", "off"])
  func clickRunsTheKeepAwakeToggleInEveryState(state: String) throws {
    let status = Self.status(state, expires: Date(timeIntervalSince1970: 1_800_005_400))
    let run = try CompanionToggleHarness.run(
      .keepAwake, sender: "mouse.clicked",
      read: { SketchyBarKeepAwakeIndicator.toggle(status) })
    #expect(
      run.launched == [
        [
          "keep-awake", "toggle", "--state-root", CompanionToggleHarness.stateRoot.path,
          "--alert-on-error",
        ]
      ])
  }

  /// Bars generated before the toggles still show the cup only while keep-awake is on.
  @Test(arguments: ["indefinite", "off"])
  func olderBarsShowTheCupOnlyWhileASessionRuns(state: String) throws {
    let status = Self.status(state, expires: Date(timeIntervalSince1970: 1_800_005_400))
    let run = try CompanionToggleHarness.run(
      .keepAwake, sender: KeepAwake.barEvent, muted: nil,
      read: { SketchyBarKeepAwakeIndicator.toggle(status) })
    let shown = [
      "--set", "macarchy.keep-awake", "drawing=on", "icon=☕\u{FE0E}",
      "icon.color=\(CompanionToggleHarness.accent)", "--set", "macarchy.keep-awake.detail",
      "label=Keep-awake on until turned off. Idle screensaver and idle lock won't start. "
        + "Click to turn off.",
    ]
    let hidden = ["--set", "macarchy.keep-awake", "drawing=off", "popup.drawing=off"]
    #expect(run.bar == [state == "off" ? hidden : shown])
    #expect(
      SketchyBarKeepAwakeIndicator.toggle(status).olderBarClick
        == (state == "off" ? nil : ["keep-awake", "off"]))
  }

  @Test func theHelperAcceptsOlderAndCurrentBarArguments() throws {
    let older = try Desktop.KeepAwakeIndicator.parse([
      "--sender", "mouse.clicked", "--state-root", "/Users/me/.config/macarchy", "--accent",
      "0xffaabbcc",
    ])
    #expect(older.muted == nil)
    let current = try Desktop.KeepAwakeIndicator.parse([
      "--sender", "forced", "--state-root", "/Users/me/.config/macarchy", "--accent",
      "0xffaabbcc", "--muted", "0xff585b70",
    ])
    #expect(current.muted == "0xff585b70")
  }

  private static func status(_ state: String, expires: Date) -> KeepAwakeStatus {
    state == "off"
      ? .off : .on(.init(pid: 7, started: 1, expires: state == "bounded" ? expires : nil))
  }
}
