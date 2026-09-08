import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarCalendarTests {
  @Test(arguments: ["auto-internal", "auto-external", "left", "center", "right"])
  func adaptsOnlyAutomaticPlacementAndUsesPersonalSpacing(mode: String) throws {
    let state = State()
    var probes = 0
    let automatic = mode.hasPrefix("auto")
    let position = automatic ? (mode == "auto-external" ? "center" : "right") : mode
    let calendar = SketchyBarCalendar(
      processRunner: runner(state),
      hasExternalDisplay: {
        probes += 1
        return mode == "auto-external"
      }, uptime: { 100 }, sleep: { _ in Issue.record("unexpected sleep") })
    try calendar.execute(
      sender: "display_change", position: automatic ? "auto" : mode, format: "+%a %d %b  %H:%M")
    let args = try #require(state.value.withLock { $0.calls.last })
    #expect(args.contains("position=\(position)"))
    #expect(args.contains("padding_right=\(position == "right" ? 2 : 8)"))
    #expect(
      state.value.withLock { $0.formats } == [
        position == "right" ? "+%a %d %b %H:%M" : "+%a %d %b  %H:%M"
      ])
    #expect(probes == (automatic ? 1 : 0))
  }

  @Test(arguments: [false, true])
  func clickPreviewRestoresAfterFourSecondsWithoutOverridingALaterClick(laterClick: Bool) throws {
    let state = State()
    var now = 100.0
    let calendar = SketchyBarCalendar(
      processRunner: runner(state), hasExternalDisplay: { false }, uptime: { now },
      sleep: {
        #expect($0 == 4)
        now += $0
        if laterClick { state.value.withLock { $0.deadline = "106000" } }
      })
    try calendar.execute(sender: "mouse.clicked", position: "auto", format: "+%H:%M")
    let updates = state.value.withLock { $0.calls.filter { $0.first == "--set" } }
    #expect(updates.first?.contains("label=104000") == true)
    #expect(updates.first?.contains("label=Week 36") == true)
    #expect(updates.count == (laterClick ? 1 : 2))
    if !laterClick { #expect(updates.last?.contains("label=12:00") == true) }
  }

  @Test func routinePreservesActivePreviewAndRejectsMalformedState() throws {
    let state = State()
    state.value.withLock { $0.deadline = "104000" }
    let calendar = SketchyBarCalendar(
      processRunner: runner(state), hasExternalDisplay: { false }, uptime: { 100 }, sleep: { _ in })
    try calendar.execute(sender: "routine", position: "right", format: "+%H:%M")
    #expect(state.value.withLock { $0.calls.last?.contains("label=Week 36") } == true)
    state.value.withLock { $0.deadline = "broken" }
    #expect(throws: CalendarError.self) {
      try calendar.execute(sender: "routine", position: "right", format: "+%H:%M")
    }
  }

  private final class State: Sendable {
    struct Value {
      var deadline = "0"
      var calls: [[String]] = []
      var formats: [String] = []
    }
    let value = Mutex(Value())
  }

  private func runner(_ state: State) -> ProcessRunner {
    ProcessRunner { request in
      if request.executableURL.path == "/bin/date" {
        state.value.withLock { $0.formats.append(request.arguments[0]) }
        return ProcessResult(
          terminationStatus: 0, output: request.arguments == ["+%V"] ? "36\n" : "12:00\n")
      }
      #expect(request.executableURL.path == "/opt/homebrew/bin/sketchybar")
      return state.value.withLock {
        $0.calls.append(request.arguments)
        if request.arguments == ["--query", SketchyBarCalendar.previewItem] {
          return ProcessResult(
            terminationStatus: 0, output: "{\"label\":{\"value\":\"\($0.deadline)\"}}")
        }
        if request.arguments.prefix(2) == ["--set", SketchyBarCalendar.previewItem] {
          $0.deadline = String(request.arguments[2].dropFirst("label=".count))
        }
        return ProcessResult(terminationStatus: 0, output: "")
      }
    }
  }
}
