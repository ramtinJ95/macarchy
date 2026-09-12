import CoreGraphics
import Darwin
import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarToggleTests {
  private let token = "00000000-0000-0000-0000-000000000001"

  @Test func asyncCLIDispatchReachesTheLockWithoutRequiringTheMainThread() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-toggle-cli-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let blockedRoot = root.appending(path: "not-a-directory")
    try Data().write(to: blockedRoot)
    let binary = Bundle(for: SketchyBarToggleCLIBundleToken.self).bundleURL
      .deletingLastPathComponent().appending(path: "macarchy")
    // Failure to create the lock is deliberate and precedes any native bar query
    // or cursor observation. Exercise the real async CLI dispatcher in a child.
    let result = try ProcessRunner.live.run(
      .init(
        executableURL: binary,
        arguments: ["desktop", "_bar-toggle", "--state-root", blockedRoot.path, "--token", token],
        timeout: 3))
    #expect(result.terminationStatus != 0)
    #expect(result.output.contains("lock("), Comment(rawValue: result.output))
    #expect(!result.output.contains("invalidToken"))
  }

  @Test func cursorCoordinatesUseEachDisplaysTopEdge() throws {
    for origin in [CGPoint.zero, CGPoint(x: -1920, y: 0), CGPoint(x: 0, y: -1080)] {
      let bounds = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
      let point = CGPoint(x: origin.x + 10, y: origin.y + 42)
      #expect(try SketchyBarToggle.distanceFromTop(point: point, bounds: bounds) == 42)
      #expect(throws: ToggleError.self) {
        try SketchyBarToggle.distanceFromTop(
          point: CGPoint(x: origin.x - 1, y: origin.y), bounds: bounds)
      }
    }
  }

  @Test func periodicLaunchDoesNotQueueBehindAnExistingOwner() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-toggle-lock-\(UUID())")
    let run = root.appending(path: "run")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = open(
      run.appending(path: "sketchybar-toggle.lock").path, O_RDWR | O_CREAT, 0o600)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    #expect(lockf(descriptor, F_LOCK, 0) == 0)
    let binary = Bundle(for: SketchyBarToggleCLIBundleToken.self).bundleURL
      .deletingLastPathComponent().appending(path: "macarchy")
    let result = try ProcessRunner.live.run(
      .init(
        executableURL: binary,
        arguments: [
          "desktop", "_bar-toggle",
          "--state-root", root.path, "--token", token,
        ], timeout: 3))
    #expect(result.terminationStatus == 0, Comment(rawValue: result.output))
  }

  @Test(arguments: ["cursor", "empty-query"])
  func failedWorkerRetainsOwnershipForRecoveryAndClearsErrorPresentation(failure: String) throws {
    let state = State(token: token)
    let base = runner(state)
    let failed = Mutex(false)
    let flaky = ProcessRunner { request in
      let inject = failed.withLock { value in
        if failure == "empty-query", !value, request.arguments == ["--query", "bar"] {
          value = true
          return true
        }
        return false
      }
      return inject ? .init(terminationStatus: 0, output: "") : try base.run(request)
    }
    let worker = SketchyBarToggle(
      processRunner: flaky, uptime: { 100 },
      distance: { throw ToggleError.cursorScreenUnavailable },
      wait: {}, stopping: { false }, foreignToggleAbsent: { true }, pid: 7, started: 1_000_000)
    #expect(throws: (any Error).self) { try worker.execute(token: token) }
    #expect(state.value.withLock { $0.label.hasPrefix(token + "|Toggle ERR:") })
    state.value.withLock { $0.calls.removeAll() }
    var stopped = false
    try SketchyBarToggle(
      processRunner: base, uptime: { 101 }, distance: { 60 },
      wait: { stopped = true }, stopping: { stopped }, foreignToggleAbsent: { true },
      pid: 8, started: 2_000_000
    ).execute(token: token)
    #expect(state.value.withLock { $0.calls.contains { $0.contains("label.drawing=off") } })
    #expect(
      state.value.withLock { $0.calls.contains { $0.contains("label=\(token)|8|101000|2000000") } })
  }

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
      state.value.withLock { $0.calls.last?.contains("label=\(token)|Toggle ERR: foreignProcess") }
        == true)
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
      return try state.value.withLock {
        $0.calls.append(request.arguments)
        if request.arguments == ["--query", "bar"] {
          return .init(
            terminationStatus: 0,
            output: "{\"items\":\($0.present ? "[\"macarchy.toggle\"]" : "[]")}")
        }
        if request.arguments == ["--query", "macarchy.toggle"] {
          return .init(
            terminationStatus: 0,
            output: String(
              decoding: try JSONSerialization.data(withJSONObject: ["label": ["value": $0.label]]),
              as: UTF8.self))
        }
        if let label = request.arguments.first(where: { $0.hasPrefix("label=") }) {
          $0.label = String(label.dropFirst(6))
        }
        return .init(terminationStatus: 0, output: "")
      }
    }
  }
}

private final class SketchyBarToggleCLIBundleToken: NSObject {}
