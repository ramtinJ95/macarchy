import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

/// A recorder stands in for SketchyBar and another for the launched macarchy command. No test
/// starts a process, reaches SketchyBar or touches the feature's engine.
struct SketchyBarCompanionToggleTests {
  private static let on = CompanionToggle(
    lit: true, olderBarClick: ["keep-awake", "off"], icon: "on-icon",
    detail: "On. Click to turn off.", click: ["keep-awake", "toggle"])
  private static let onInNewBarsOnly = CompanionToggle(
    lit: true, olderBarClick: nil, icon: "on-icon", detail: "On. Click to turn off.",
    click: ["saver", "idle", "toggle"])
  private static let off = CompanionToggle(
    lit: false, olderBarClick: nil, icon: "off-icon", detail: "Off. Click to turn on.",
    click: ["saver", "idle", "toggle"])

  @Test(
    arguments: [ClockCompanion.keepAwake, .microphone, .saverPaused],
    ["mouse.entered", "mouse.exited", "mouse.exited.global"])
  func hoverOnlyTogglesTheDetailPopup(companion: ClockCompanion, sender: String) throws {
    let run = try CompanionToggleHarness.run(companion, sender: sender) {
      Issue.record("hover must not read the feature")
      return Self.off
    }
    let popup = sender == "mouse.entered" ? "popup.drawing=on" : "popup.drawing=off"
    #expect(run.bar == [["--set", companion.item, popup]])
    #expect(run.launched.isEmpty)
  }

  /// The launched command hints the bar once it changes the feature, so the click itself draws
  /// nothing that could overwrite that refresh.
  @Test(arguments: [true, false])
  func clickRunsTheCurrentStatesCommandWithTheStateRootAndAlerts(on: Bool) throws {
    let toggle = on ? Self.on : Self.off
    let run = try CompanionToggleHarness.run(
      .saverPaused, sender: "mouse.clicked", read: { toggle })
    #expect(run.bar == [["--set", "macarchy.saver-paused", "popup.drawing=off"]])
    #expect(
      run.launched == [
        toggle.click + [
          "--state-root", CompanionToggleHarness.stateRoot.path, "--alert-on-error",
        ]
      ])
  }

  /// An older bar's icon offered only the revert, so its click runs that explicit command. A
  /// state change before the command runs then leaves the feature alone instead of reversing it.
  @Test func olderBarsRunTheExplicitRevertInsteadOfAToggle() throws {
    let run = try CompanionToggleHarness.run(
      .keepAwake, sender: "mouse.clicked", muted: nil, read: { Self.on })
    #expect(run.bar == [["--set", "macarchy.keep-awake", "popup.drawing=off"]])
    #expect(
      run.launched == [
        [
          "keep-awake", "off", "--state-root", CompanionToggleHarness.stateRoot.path,
          "--alert-on-error",
        ]
      ])
  }

  /// An older bar can still show the item for up to 30 seconds after its old state ended. A click
  /// then hides it instead of toggling the feature the other way.
  @Test func olderBarsIgnoreAClickOnAStaleItem() throws {
    let stale = try CompanionToggleHarness.run(
      .keepAwake, sender: "mouse.clicked", muted: nil, read: { Self.onInNewBarsOnly })
    #expect(
      stale.bar == [
        ["--set", "macarchy.keep-awake", "popup.drawing=off"],
        ["--set", "macarchy.keep-awake", "drawing=off", "popup.drawing=off"],
      ])
    #expect(stale.launched.isEmpty)
  }

  @Test(arguments: [true, false])
  func refreshDrawsTheItemLitInTheAccentOrDimmedInTheMutedColor(on: Bool) throws {
    let toggle = on ? Self.on : Self.off
    let run = try CompanionToggleHarness.run(.keepAwake, sender: "forced", read: { toggle })
    #expect(
      run.bar == [
        [
          "--set", "macarchy.keep-awake", "drawing=on", "icon=\(on ? "on-icon" : "off-icon")",
          "icon.color=\(on ? CompanionToggleHarness.accent : CompanionToggleHarness.muted)",
          "--set", "macarchy.keep-awake.detail",
          "label=\(on ? "On. Click to turn off." : "Off. Click to turn on.")",
        ]
      ])
    #expect(run.launched.isEmpty)
  }

  /// Bars generated before the toggles pass no muted color and drew the item only in the state
  /// it was made for.
  @Test(arguments: ["shown", "lit-in-new-bars-only", "off"])
  func olderBarsKeepTheirItemHiddenOutsideItsOldState(state: String) throws {
    let toggle =
      switch state {
      case "shown": Self.on
      case "lit-in-new-bars-only": Self.onInNewBarsOnly
      default: Self.off
      }
    let run = try CompanionToggleHarness.run(
      .microphone, sender: Microphone.barEvent, muted: nil, read: { toggle })
    let shown = [
      "--set", "macarchy.microphone", "drawing=on", "icon=on-icon",
      "icon.color=\(CompanionToggleHarness.accent)", "--set", "macarchy.microphone.detail",
      "label=On. Click to turn off.",
    ]
    let hidden = ["--set", "macarchy.microphone", "drawing=off", "popup.drawing=off"]
    #expect(run.bar == [state == "shown" ? shown : hidden])
  }

  @Test(arguments: ["bar", "read", "launch"])
  func failuresPropagateForTheScriptWarning(failing: String) {
    let toggle = SketchyBarCompanionToggle(
      companion: .keepAwake, stateRoot: CompanionToggleHarness.stateRoot,
      processRunner: ProcessRunner { _ in
        .init(terminationStatus: failing == "bar" ? 1 : 0, output: "bar refused")
      },
      read: {
        if failing == "read" { throw KeepAwakeError("unreadable record") }
        return Self.off
      },
      launch: { _ in if failing == "launch" { throw KeepAwakeError("cannot launch") } })
    let error = #expect(throws: (any Error).self) {
      try toggle.execute(sender: "mouse.clicked", accent: "accent", muted: "muted")
    }
    switch failing {
    case "bar":
      #expect(
        (error as? CompanionToggleError)?.description
          == "SketchyBar macarchy.keep-awake failed: bar refused")
    case "read": #expect((error as? KeepAwakeError)?.description == "unreadable record")
    default: #expect((error as? KeepAwakeError)?.description == "cannot launch")
    }
  }
}

/// Runs one companion toggle event against recorders for SketchyBar and the launched command.
enum CompanionToggleHarness {
  static let accent = "0xffaabbcc"
  static let muted = "0xff585b70"
  static let stateRoot = URL(filePath: "/Users/me/.config/macarchy", directoryHint: .isDirectory)

  struct Run {
    let bar: [[String]]
    let launched: [[String]]
  }

  static func run(
    _ companion: ClockCompanion, sender: String, muted: String? = CompanionToggleHarness.muted,
    read: @escaping () throws -> CompanionToggle
  ) throws -> Run {
    let bar = BarCalls()
    var launched: [[String]] = []
    try SketchyBarCompanionToggle(
      companion: companion, stateRoot: stateRoot,
      processRunner: ProcessRunner { request in
        #expect(request.executableURL == SketchyBarCoreRuntimeVerifier.controlURL)
        bar.value.withLock { $0.append(request.arguments) }
        return .init(terminationStatus: 0, output: "")
      },
      read: read, launch: { launched.append($0) }
    )
    .execute(sender: sender, accent: accent, muted: muted)
    return Run(bar: bar.value.withLock { $0 }, launched: launched)
  }

  private final class BarCalls: Sendable {
    let value = Mutex([[String]]())
  }
}
