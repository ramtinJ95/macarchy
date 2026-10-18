import ArgumentParser
import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct KeepAwakeTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let caffeinate = "/usr/bin/caffeinate"
  private static let effect =
    "The display stays on; the idle screensaver and idle lock will not start."

  @Test func indefiniteSessionIsOwnedOnceAndTurnedOff() throws {
    try withEngine { engine, machine, record in
      let change = try engine.apply(.on(nil))
      guard case .started(let session) = change else {
        Issue.record("expected a started session, got \(change)")
        return
      }
      #expect(machine.spawned == [["-d", "-i"]])
      #expect(session.expires == nil)
      #expect(try record.read() == session)
      #expect(try engine.status() == .on(session))
      #expect(
        change.message == "Keep-awake on until turned off. \(Self.effect)")

      #expect(try engine.apply(.on(nil)) == .alreadyOn(session))
      #expect(machine.spawned.count == 1)
      #expect(machine.notifications == 1)

      #expect(try engine.apply(.off) == .stopped)
      #expect(machine.terminated == [session.pid])
      #expect(machine.processes[session.pid] == nil)
      #expect(try record.read() == nil)
      #expect(try engine.status() == .off)
      #expect(machine.notifications == 2)

      #expect(try engine.apply(.off) == .alreadyOff)
      #expect(machine.terminated == [session.pid])
      #expect(machine.notifications == 2)
    }
  }

  @Test func onReplacesAnyOtherShapeWithTheRequestedOne() throws {
    try withEngine { engine, machine, record in
      guard case .started(let bounded) = try engine.apply(.on(.seconds(5400))) else {
        Issue.record("bounded request did not start")
        return
      }
      #expect(machine.spawned.last == ["-d", "-i", "-t", "5400"])
      #expect(bounded.expires == Self.now.addingTimeInterval(5400))

      guard case .started(let indefinite) = try engine.apply(.on(nil)) else {
        Issue.record("indefinite request did not replace the bounded session")
        return
      }
      #expect(machine.terminated == [bounded.pid])
      #expect(indefinite.expires == nil)

      guard case .started(let shorter) = try engine.apply(.on(.seconds(1800))) else {
        Issue.record("bounded request did not replace the indefinite session")
        return
      }
      #expect(machine.terminated == [bounded.pid, indefinite.pid])
      #expect(machine.spawned.last == ["-d", "-i", "-t", "1800"])
      #expect(try record.read() == shorter)
      #expect(machine.processes.count == 1)
      #expect(machine.notifications == 3)
    }
  }

  @Test func toggleStartsUntilTurnedOffThenStops() throws {
    try withEngine { engine, machine, _ in
      guard case .started(let session) = try engine.apply(.toggle) else {
        Issue.record("toggle did not start")
        return
      }
      #expect(machine.spawned == [["-d", "-i"]])
      #expect(session.expires == nil)
      #expect(try engine.apply(.toggle) == .stopped)
      #expect(machine.terminated == [session.pid])
      #expect(try engine.status() == .off)
    }
  }

  @Test(arguments: ["dead", "reused", "foreign", "corrupt", "invalid-pid"])
  func staleRecordsReadOffAreRemovedAndNeverSignalled(kind: String) throws {
    try withEngine { engine, machine, record in
      try FileManager.default.createDirectory(
        at: record.directory, withIntermediateDirectories: true)
      let stale = KeepAwakeSession(
        pid: kind == "invalid-pid" ? -1 : 777, started: 1_000, expires: nil)
      switch kind {
      case "corrupt": try Data("{\"pid\":".utf8).write(to: record.url)
      default: try record.write(stale)
      }
      switch kind {
      case "reused": machine.processes[777] = .init(started: 2_000, executablePath: Self.caffeinate)
      case "foreign": machine.processes[777] = .init(started: 1_000, executablePath: "/bin/sleep")
      case "invalid-pid":
        machine.processes[-1] = .init(started: 1_000, executablePath: Self.caffeinate)
      default: break
      }

      #expect(try engine.status() == .off)
      #expect(!FileManager.default.fileExists(atPath: record.url.path))
      #expect(try engine.apply(.off) == .alreadyOff)
      guard case .started = try engine.apply(.on(nil)) else {
        Issue.record("a stale record blocked a fresh session")
        return
      }
      #expect(machine.terminated.isEmpty)
      #expect(machine.notifications == 1)
    }
  }

  @Test(arguments: ["ignores-sigterm", "signal-error"])
  func failedStopKeepsTheOwnedRecordAndFails(mode: String) throws {
    try withEngine { engine, machine, record in
      guard case .started(let session) = try engine.apply(.on(nil)) else {
        Issue.record("session did not start")
        return
      }
      if mode == "ignores-sigterm" {
        machine.exitsOnSIGTERM = false
      } else {
        machine.signalFails = true
      }
      #expect(throws: KeepAwakeError.self) { try engine.apply(.off) }
      #expect(try record.read() == session)
      #expect(try engine.status() == .on(session))
      #expect(machine.notifications == 1)
    }
  }

  @Test func childWithoutEstablishedIdentityIsStoppedAndNotRecorded() throws {
    try withEngine { engine, machine, record throws in
      machine.spawnedIdentityVisible = false
      #expect(throws: KeepAwakeError.self) { try engine.apply(.on(nil)) }
      #expect(machine.terminated == [machine.lastPID])
      #expect(try record.read() == nil)
      #expect(try engine.status() == .off)
      #expect(machine.notifications == 0)
    }
  }

  @Test(arguments: [
    ("1m", 60), ("30m", 1_800), ("2h", 7_200), ("1h30m", 5_400), ("24h", 86_400),
  ])
  func durationsAcceptMinutesAndHoursUpToADay(text: String, seconds: Int) throws {
    #expect(try KeepAwake.duration.parse(text) == .seconds(seconds))
  }

  @Test(arguments: [
    "0m", "-5m", "25h", "24h1m", "1441m", "garbage", "", "30", "m", "30m1h", "1h1h", "1.5h",
  ])
  func durationsRejectAnythingElse(text: String) {
    #expect(throws: ValidationError.self) { try KeepAwake.duration.parse(text) }
  }

  @Test func durationErrorsNameTheOptionAndItsRange() {
    let error = #expect(throws: ValidationError.self) { try KeepAwake.duration.parse("25h") }
    #expect(
      error?.message
        == "--for takes a duration from 1m to 24h, such as 30m, 2h or 1h30m; got '25h'")
  }

  @Test func commandLineParsesTheOptionalBound() throws {
    #expect(try KeepAwakeCommand.On.parse(["--for", "1h30m"]).duration == .seconds(5_400))
    #expect(try KeepAwakeCommand.On.parse([]).duration == nil)
    #expect(throws: (any Error).self) { try KeepAwakeCommand.On.parse(["--for", "0m"]) }
    #expect(try KeepAwakeCommand.Toggle.parse(["--alert-on-error"]).options.alertOnError)
    #expect(try KeepAwakeCommand.Status.parse(["--json"]).json)
  }

  @Test(arguments: ["absent", "delivered", "failed", "timeout"])
  func barHintSkipsAMissingBarAndOnlyWarnsWhenItFails(outcome: String) {
    let calls = Mutex([[String]]())
    var warnings: [String] = []
    ClockCompanion.hintBar(
      event: KeepAwake.barEvent,
      processRunner: ProcessRunner { request in
        calls.withLock { $0.append(request.arguments) }
        #expect(request.executableURL == SketchyBarCoreRuntimeVerifier.controlURL)
        if outcome == "timeout" { throw ProcessRunnerError.timedOut(request.executableURL, 1) }
        return .init(terminationStatus: outcome == "failed" ? 1 : 0, output: "")
      }, installed: outcome != "absent", warn: { warnings.append($0) })
    #expect(
      calls.withLock { $0 }
        == (outcome == "absent" ? [] : [["--trigger", "macarchy_keep_awake_changed"]]))
    #expect(warnings.count == (["failed", "timeout"].contains(outcome) ? 1 : 0))
    #expect(warnings.allSatisfy { $0.contains("refreshes within 30 seconds") })
  }

  @Test func statusRendersOneLineAndStableJSON() throws {
    let end = Self.now.addingTimeInterval(5_400)
    let local = Calendar.current.dateComponents([.hour, .minute], from: end)
    let clock = String(format: "%02d:%02d", local.hour!, local.minute!)
    let bounded = KeepAwakeStatus.on(.init(pid: 7, started: 1, expires: end))
    let indefinite = KeepAwakeStatus.on(.init(pid: 7, started: 1, expires: nil))
    #expect(KeepAwakeStatus.off.message == "Keep-awake is off.")
    #expect(bounded.message == "Keep-awake is on until \(clock). \(Self.effect)")
    #expect(indefinite.message == "Keep-awake is on until turned off. \(Self.effect)")
    #expect(try KeepAwakeStatus.off.renderJSON() == #"{"expires":null,"state":"off"}"#)
    #expect(try indefinite.renderJSON() == #"{"expires":null,"state":"on"}"#)
    #expect(try bounded.renderJSON() == #"{"expires":"2027-01-15T09:30:00Z","state":"on"}"#)
    #expect(KeepAwakeChange.stopped.message == "Keep-awake off.")
    #expect(KeepAwakeChange.alreadyOff.message == "Keep-awake was already off.")
  }

  /// The processes and side effects the engine can observe or cause.
  private final class Machine {
    var processes: [Int32: KeepAwakeProcess] = [:]
    var spawned: [[String]] = []
    var terminated: [Int32] = []
    var notifications = 0
    var lastPID: Int32 = 500
    var spawnedIdentityVisible = true
    var exitsOnSIGTERM = true
    var signalFails = false
  }

  private func withEngine(
    _ body: (KeepAwake, Machine, RunStateRecord<KeepAwakeSession>) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keep-awake-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let machine = Machine()
    let engine = KeepAwake(
      stateRoot: root,
      spawn: { arguments in
        machine.spawned.append(arguments)
        machine.lastPID += 1
        if machine.spawnedIdentityVisible {
          machine.processes[machine.lastPID] = .init(
            started: UInt64(machine.lastPID) * 1_000, executablePath: Self.caffeinate)
        }
        return machine.lastPID
      },
      process: { machine.processes[$0] },
      terminate: { pid in
        if machine.signalFails { throw KeepAwakeError("signal refused") }
        machine.terminated.append(pid)
        if machine.exitsOnSIGTERM { machine.processes[pid] = nil }
      },
      pause: {},
      now: { Self.now },
      notifyBar: { machine.notifications += 1 })
    try body(engine, machine, KeepAwake.sessionRecord(stateRoot: root))
  }
}
