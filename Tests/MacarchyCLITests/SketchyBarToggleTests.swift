import Darwin
import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarToggleTests {
  private let token = "00000000-0000-0000-0000-000000000001"

  @Test func cursorZonesAndDebounceMatchThePersonalBehavior() {
    var state = NativeMenuToggleState()
    #expect(state.step(distanceFromTop: 11, now: 0) == nil)
    #expect(state.step(distanceFromTop: 10, now: 0) == .hide)
    #expect(state.step(distanceFromTop: 50, now: 1) == nil)
    #expect(state.step(distanceFromTop: 51, now: 1) == nil)
    #expect(state.step(distanceFromTop: 51, now: 1.14) == nil)
    #expect(state.step(distanceFromTop: 40, now: 1.15) == nil)
    #expect(state.step(distanceFromTop: 51, now: 2) == nil)
    #expect(state.step(distanceFromTop: 51, now: 2.16) == .show)
    #expect(!state.hidden)
  }

  @Test func heartbeatRejectsStaleFutureAndReusedProcessIdentity() throws {
    let value = try #require(ToggleHeartbeat.parse(token + "|7|1000|1000000"))
    #expect(value.fresh(at: 1))
    #expect(value.fresh(at: 3.5))
    #expect(!value.fresh(at: 3.501))
    #expect(!value.fresh(at: 0.9))
    #expect(ToggleHeartbeat.parse(token + "|007|1000|1000000") == nil)
    #expect(ToggleHeartbeat.parse(token + "|starting") == nil)
    let start = try #require(SketchyBarToggle.processStart(getpid()))
    #expect(
      SketchyBarToggle.matchesProcess(
        .init(token: token, pid: getpid(), milliseconds: 0, started: start)))
    #expect(
      !SketchyBarToggle.matchesProcess(
        .init(token: token, pid: getpid(), milliseconds: 0, started: start + 1)))
  }

  @Test(arguments: ["stop", "replacement", "disable"])
  func stopsOnlyItsOwnGenerationAndRestoresVisibilityOnSignal(mode: String) throws {
    let state = State(token: token)
    var stopped = false
    var now = 100.0
    let worker = SketchyBarToggle(
      processRunner: runner(state), uptime: { now }, distance: { 5 },
      wait: {
        now += 1
        if mode == "stop" {
          stopped = true
        } else {
          state.value.withLock {
            if mode == "replacement" { $0.label = "other|starting" } else { $0.present = false }
          }
        }
      }, stopping: { stopped }, foreignToggleAbsent: { true }, pid: 7, started: 1_000_000)
    try worker.execute(token: token)
    let mutations = state.value.withLock { $0.calls.filter { $0.first != "--query" } }
    #expect(mutations.contains { $0 == ["--bar", "hidden=on"] })
    #expect(mutations.contains { $0.contains("label=\(token)|7|100000|1000000") })
    if mode == "stop" {
      #expect(mutations.last?.contains("hidden=off") == true)
    } else {
      #expect(mutations.last == ["--bar", "hidden=on"])
    }
  }

  @Test func refusesForeignProcessWithoutKillingItAndReportsFailure() {
    let state = State(token: token)
    let worker = SketchyBarToggle(
      processRunner: runner(state), uptime: { 100 }, distance: { 0 }, wait: {}, stopping: { false },
      foreignToggleAbsent: { false }, pid: 7, started: 1_000_000)
    #expect(throws: ToggleError.self) { try worker.execute(token: token) }
    #expect(
      state.value.withLock { $0.calls.last?.contains("label=Toggle ERR: foreignProcess") } == true)
    #expect(state.value.withLock { $0.calls.allSatisfy { !$0.contains("kill") } })
  }

  @Test(arguments: [Int32(0), 1, 2])
  func foreignProcessInspectionDistinguishesAbsentFromFailed(status: Int32) throws {
    let runner = ProcessRunner { request in
      #expect(request.executableURL.path == "/usr/bin/pgrep")
      #expect(request.arguments == ["-u", String(getuid()), "-x", "sketchybar-toggle"])
      return .init(terminationStatus: status, output: "")
    }
    if status == 2 {
      #expect(throws: ToggleError.self) {
        try SketchyBarToggle.noForeignToggle(processRunner: runner)
      }
    } else {
      #expect(try SketchyBarToggle.noForeignToggle(processRunner: runner) == (status == 1))
    }
  }

  private final class State: Sendable {
    struct Value {
      var calls: [[String]] = []
      var label: String
      var present = true
    }
    let value: Mutex<Value>
    init(token: String) { value = Mutex(.init(label: token + "|starting")) }
  }
  private func runner(_ state: State) -> ProcessRunner {
    ProcessRunner { request in
      #expect(request.executableURL == SketchyBarCoreRuntimeVerifier.controlURL)
      return state.value.withLock {
        $0.calls.append(request.arguments)
        if request.arguments == ["--query", "bar"] {
          return .init(
            terminationStatus: 0,
            output: "{\"items\":\($0.present ? "[\"macarchy.toggle\"]" : "[]")}")
        }
        if request.arguments == ["--query", "macarchy.toggle"] {
          return .init(terminationStatus: 0, output: "{\"label\":{\"value\":\"\($0.label)\"}}")
        }
        if let label = request.arguments.first(where: { $0.hasPrefix("label=") }) {
          $0.label = String(label.dropFirst(6))
        }
        return .init(terminationStatus: 0, output: "")
      }
    }
  }
}
