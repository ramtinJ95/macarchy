import ArgumentParser
import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarSaverPausedIndicatorTests {
  private static let conflict = URL(filePath: "/Users/me/Library/LaunchAgents/saver-idle.plist")

  @Test(arguments: [
    "off", "incomplete", "on", "paused", "paused-not-loaded", "paused-without-agent", "conflict",
  ])
  func refreshAlwaysDrawsTheScreensaverLitWhileIdleActivationRuns(state: String) throws {
    let activation = Self.activation(state)
    let run = try CompanionToggleHarness.run(
      .saverPaused, sender: SaverIdle.barEvent,
      read: { SketchyBarSaverPausedIndicator.toggle(activation) })
    let detail =
      switch state {
      case "on": "Idle screensaver on: it starts after 5 minutes idle. Click to turn it off."
      case "paused": "Idle screensaver paused. Click to resume."
      case "incomplete": "Idle screensaver is off. Click to start it after 30 minutes idle."
      case "conflict":
        "Warning: \(Self.conflict.path) is not the launch agent this Macarchy writes, so the idle "
          + "screensaver cannot change. Click for details."
      default: "Idle screensaver is off. Click to start it after 5 minutes idle."
      }
    let lit = ["on", "paused"].contains(state)
    let icon = state == "paused" ? "⏸\u{FE0E}" : "\u{10114B}"
    #expect(
      run.bar == [
        [
          "--set", "macarchy.saver-paused", "drawing=on", "icon=\(icon)",
          "icon.color=\(lit ? CompanionToggleHarness.accent : CompanionToggleHarness.muted)",
          "--set", "macarchy.saver-paused.detail", "label=\(detail)",
        ]
      ])
  }

  /// A paused activation resumes; every other state toggles idle activation, and a foreign launch
  /// agent makes the toggle fail with its alert and change nothing (see SaverIdleTests).
  @Test(arguments: ["off", "incomplete", "on", "paused", "paused-not-loaded", "conflict"])
  func clickResumesAPauseAndOtherwiseTogglesIdleActivation(state: String) throws {
    let activation = Self.activation(state)
    let run = try CompanionToggleHarness.run(
      .saverPaused, sender: "mouse.clicked",
      read: { SketchyBarSaverPausedIndicator.toggle(activation) })
    let command = state == "paused" ? ["saver", "resume"] : ["saver", "idle", "toggle"]
    #expect(
      run.launched == [
        command + ["--state-root", CompanionToggleHarness.stateRoot.path, "--alert-on-error"]
      ])
  }

  /// Bars generated before the toggles still show only the pause sign, only while paused.
  @Test(arguments: ["off", "on", "paused", "paused-not-loaded", "conflict"])
  func olderBarsShowOnlyThePauseSignWhilePaused(state: String) throws {
    let activation = Self.activation(state)
    let run = try CompanionToggleHarness.run(
      .saverPaused, sender: SaverIdle.barEvent, muted: nil,
      read: { SketchyBarSaverPausedIndicator.toggle(activation) })
    let shown = [
      "--set", "macarchy.saver-paused", "drawing=on", "icon=⏸\u{FE0E}",
      "icon.color=\(CompanionToggleHarness.accent)", "--set", "macarchy.saver-paused.detail",
      "label=Idle screensaver paused. Click to resume.",
    ]
    let hidden = ["--set", "macarchy.saver-paused", "drawing=off", "popup.drawing=off"]
    #expect(run.bar == [state == "paused" ? shown : hidden])
    #expect(
      SketchyBarSaverPausedIndicator.toggle(activation).olderBarClick
        == (state == "paused" ? ["saver", "resume"] : nil))
  }

  @Test func theHelperAcceptsOlderAndCurrentBarArguments() throws {
    let base = ["--state-root", "/Users/me/.config/macarchy", "--accent", "0xffaabbcc"]
    #expect(try Desktop.SaverPausedIndicator.parse(base).muted == nil)
    #expect(
      try Desktop.SaverPausedIndicator.parse(base + ["--muted", "0xff585b70"]).muted
        == "0xff585b70")
  }

  @Test func theCompanionSitsLeftOfTheClockAndRefreshesOnIdleChanges() {
    let companion = ClockCompanion.saverPaused
    #expect(companion.side == .left)
    #expect(companion.plugin == "saver-paused")
    #expect(companion.updateFrequency == 30)
    #expect(companion.events.last == "macarchy_saver_idle_changed")
    #expect(companion.events.contains("mouse.clicked"))
    #expect(
      ClockCompanion.all.map(\.item) == [
        "macarchy.update", "macarchy.keep-awake", "macarchy.microphone", "macarchy.saver-paused",
      ])
  }

  private static func activation(_ state: String) -> SaverIdleActivation {
    let paused = SaverIdleRecord(timeout: 300, paused: true)
    return switch state {
    case "off": SaverIdleActivation(agent: .absent, loaded: false, record: nil)
    case "incomplete":
      SaverIdleActivation(
        agent: .owned, loaded: false, record: SaverIdleRecord(timeout: 1_800, paused: false))
    case "on":
      SaverIdleActivation(
        agent: .owned, loaded: true, record: SaverIdleRecord(timeout: 300, paused: false))
    case "paused": SaverIdleActivation(agent: .owned, loaded: true, record: paused)
    case "paused-not-loaded": SaverIdleActivation(agent: .owned, loaded: false, record: paused)
    case "paused-without-agent": SaverIdleActivation(agent: .absent, loaded: true, record: paused)
    default: SaverIdleActivation(agent: .conflict(conflict), loaded: true, record: paused)
    }
  }
}
