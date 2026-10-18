import Foundation
import Testing

@testable import MacarchyCLI

/// Idle time, the session, keep-awake, the clock and the saver engine are scripted. No test
/// queries CoreGraphics, subscribes to a notification center or reaches launchd, Kitty or ttfx.
struct SaverIdleObserverTests {
  private static let suppressions: [String: SaverIdleSuppression] = [
    "paused": .paused, "keep-awake": .keepAwake, "locked": .locked, "off-console": .offConsole,
    "unknown-session": .sessionUnknown, "lock-notification": .locked,
    "native-saver": .nativeSaver, "displays-asleep": .displaysAsleep,
    "native-saver-already-running": .nativeSaver, "displays-already-asleep": .displaysAsleep,
    "session-resigned": .sessionInactive, "saver-running": .saverRunning,
  ]

  @Test func startsOnceAtTheTimeoutAndAgainOnlyAfterNewActivity() {
    let machine = IdleMachine()
    var observer = machine.observer()

    machine.idle = 100
    let early = observer.poll()
    #expect(early == 30)
    machine.idle = 290
    let close = observer.poll()
    #expect(close == 10)
    #expect(machine.starts == 0)
    #expect(observer.state == .armed)

    machine.idle = 300
    let started = observer.poll()
    #expect(started == 5)
    #expect(machine.starts == 1)
    #expect(observer.state == .showing)
    #expect(machine.logs == ["Started the screensaver after 5 minutes idle."])

    machine.idle = 600
    let showing = observer.poll()
    #expect(showing == 5)
    // Ended without input, as by `macarchy saver stop`.
    machine.running = false
    let ended = observer.poll()
    #expect(ended == 30)
    #expect(observer.state == .waitingForActivity)
    machine.idle = 900
    _ = observer.poll()
    #expect(machine.starts == 1)

    machine.idle = 2
    let rearmed = observer.poll()
    #expect(rearmed == 30)
    #expect(observer.state == .armed)
    machine.idle = 300
    _ = observer.poll()
    #expect(machine.starts == 2)
  }

  @Test(arguments: [
    (0.0, 60, 30.0), (45.0, 60, 15.0), (299.5, 300, 1.0), (100.0, 14_400, 30.0),
  ])
  func waitsUntilTheTimeoutCouldPassBetweenOneAndThirtySeconds(
    idle: TimeInterval, timeout: Int, wait: TimeInterval
  ) {
    let machine = IdleMachine()
    machine.record = SaverIdleRecord(timeout: timeout, paused: false)
    machine.idle = idle
    var observer = machine.observer()
    let next = observer.poll()
    #expect(next == wait)
    #expect(machine.starts == 0)
  }

  /// The already-running and already-asleep cases began before the observer started, so no
  /// notification reports them.
  @Test(arguments: [
    "paused", "keep-awake", "locked", "off-console", "unknown-session", "lock-notification",
    "native-saver", "displays-asleep", "native-saver-already-running", "displays-already-asleep",
    "session-resigned", "saver-running",
  ])
  func eachSuppressionHoldsOffTheStartUntilItClears(reason: String) throws {
    let expected = try #require(Self.suppressions[reason])
    let machine = IdleMachine()
    var observer = machine.observer()
    switch reason {
    case "paused": machine.record = SaverIdleRecord(timeout: 300, paused: true)
    case "keep-awake": machine.keepAwake = true
    case "locked": machine.console = .locked
    case "off-console": machine.console = .offConsole
    case "unknown-session": machine.console = .unknown
    case "lock-notification": observer.handle(.screenLocked)
    case "native-saver": observer.handle(.nativeSaverStarted)
    case "displays-asleep": observer.handle(.displaysSlept)
    case "native-saver-already-running": machine.nativeSaver = true
    case "displays-already-asleep": machine.displaysAsleep = true
    case "session-resigned": observer.handle(.sessionResigned)
    default: machine.running = true
    }
    machine.idle = 400
    let held = observer.poll()
    #expect(held == 30)
    #expect(machine.starts == 0)
    #expect(observer.state == .suppressed(expected))
    #expect(
      machine.logs.last == "Idle for 5 minutes; the screensaver waits because \(expected.summary).")
    _ = observer.poll()
    #expect(machine.logs.filter { $0.hasPrefix("Idle for") }.count == 1)

    switch reason {
    case "paused": machine.record = SaverIdleRecord(timeout: 300, paused: false)
    case "keep-awake": machine.keepAwake = false
    case "locked", "off-console", "unknown-session": machine.console = .unlocked
    case "lock-notification": observer.handle(.screenUnlocked)
    case "native-saver": observer.handle(.nativeSaverStopped)
    case "displays-asleep": observer.handle(.displaysWoke)
    case "native-saver-already-running": machine.nativeSaver = false
    case "displays-already-asleep": machine.displaysAsleep = false
    case "session-resigned": observer.handle(.sessionActivated)
    default: machine.running = false
    }
    _ = observer.poll()
    #expect(machine.starts == 1)
    #expect(observer.state == .showing)
  }

  @Test(arguments: [
    SaverIdleSessionEvent.screenLocked, .displaysSlept, .sessionResigned, .nativeSaverStarted,
  ])
  func aShowingSaverYieldsToLockSleepAnInactiveSessionAndTheNativeSaver(
    event: SaverIdleSessionEvent
  ) {
    let machine = IdleMachine()
    var observer = machine.observer()
    machine.idle = 300
    _ = observer.poll()
    #expect(observer.state == .showing)

    observer.handle(event)
    #expect(machine.running == false)
    #expect(machine.stops == 1)
    #expect(observer.state == .waitingForActivity)
    #expect(machine.logs.last == "Stopped the screensaver because \(event.suppression.summary).")
    machine.idle = 900
    _ = observer.poll()
    #expect(machine.starts == 1)

    let end: SaverIdleSessionEvent =
      switch event {
      case .screenLocked: .screenUnlocked
      case .displaysSlept: .displaysWoke
      case .sessionResigned: .sessionActivated
      default: .nativeSaverStopped
      }
    observer.handle(end)
    #expect(machine.stops == 1)
    machine.idle = 1
    _ = observer.poll()
    #expect(observer.state == .armed)
    machine.idle = 300
    _ = observer.poll()
    #expect(machine.starts == 2)
  }

  @Test func aPollStopsAShowingSaverOnceTheSessionReportsALock() {
    let machine = IdleMachine()
    var observer = machine.observer()
    machine.idle = 300
    _ = observer.poll()
    #expect(observer.state == .showing)

    machine.console = .locked
    machine.idle = 320
    let wait = observer.poll()
    #expect(wait == 30)
    #expect(machine.stops == 1)
    #expect(machine.running == false)
    #expect(observer.state == .waitingForActivity)
    #expect(machine.starts == 1)
  }

  /// The record's lock spans a poll from its read to its start, so a pause lands either before the
  /// read or after the start returns.
  @Test func aPauseThatTakesTheLockFirstHoldsOffTheStartAndStartsHoldTheLock() {
    let machine = IdleMachine()
    var observer = machine.observer()
    machine.idle = 300
    machine.beforeLock = { machine.record = SaverIdleRecord(timeout: 300, paused: true) }
    let held = observer.poll()
    #expect(held == 30)
    #expect(machine.starts == 0)
    #expect(observer.state == .suppressed(.paused))

    machine.beforeLock = { machine.record = SaverIdleRecord(timeout: 300, paused: false) }
    _ = observer.poll()
    #expect(machine.starts == 1)
    #expect(machine.unlockedStarts == 0)
    #expect(observer.state == .showing)
  }

  @Test func pausingDoesNotStopAShowingSaver() {
    let machine = IdleMachine()
    var observer = machine.observer()
    machine.idle = 300
    _ = observer.poll()
    machine.record = SaverIdleRecord(timeout: 300, paused: true)
    machine.keepAwake = true
    _ = observer.poll()
    #expect(machine.running)
    #expect(machine.stops == 0)
    #expect(observer.state == .showing)
  }

  @Test func theSessionDictionaryFailsClosed() {
    let console = "kCGSSessionOnConsoleKey"
    let locked = "CGSSessionScreenIsLocked"
    let sessions: [([String: Any]?, SaverIdleConsole)] = [
      (nil, .unknown), ([:], .unknown), ([console: "yes"], .unknown),
      ([console: false], .offConsole), ([console: true], .unlocked),
      ([console: true, locked: true], .locked), ([console: true, locked: false], .unlocked),
      ([console: true, locked: "1"], .unknown), ([console: false, locked: true], .offConsole),
    ]
    for (session, expected) in sessions {
      #expect(SaverIdleConsole(session: session) == expected)
    }
  }

  @Test func aStartFailureIsLoggedEachTimeButAlertsOncePerHourPerFailure() {
    let machine = IdleMachine()
    machine.startFailure = "Kitty is missing"
    var observer = machine.observer()
    machine.idle = 300
    _ = observer.poll()
    #expect(machine.starts == 1)
    #expect(observer.state == .waitingForActivity)
    #expect(machine.alerts == ["Kitty is missing"])
    machine.idle = 400
    _ = observer.poll()
    #expect(machine.starts == 1)

    for period in 1...3 {
      machine.now = IdleMachine.start.addingTimeInterval(TimeInterval(period * 600))
      machine.idle = 1
      _ = observer.poll()
      machine.idle = 300
      _ = observer.poll()
    }
    #expect(machine.starts == 4)
    #expect(machine.alerts == ["Kitty is missing"])
    let failures = machine.logs.filter { $0 == "The screensaver did not start: Kitty is missing" }
    #expect(failures.count == 4)

    machine.startFailure = "open failed"
    machine.idle = 1
    _ = observer.poll()
    machine.idle = 300
    _ = observer.poll()
    #expect(machine.alerts == ["Kitty is missing", "open failed"])

    machine.startFailure = "Kitty is missing"
    machine.now = IdleMachine.start.addingTimeInterval(3_600)
    machine.idle = 1
    _ = observer.poll()
    machine.idle = 300
    _ = observer.poll()
    #expect(machine.alerts == ["Kitty is missing", "open failed", "Kitty is missing"])
  }

  @Test func aStartThatFindsAnotherSaverWaitsForIt() {
    let machine = IdleMachine()
    machine.startAnswer = .alreadyStarting
    var observer = machine.observer()
    machine.idle = 300
    _ = observer.poll()
    #expect(machine.starts == 1)
    #expect(observer.state == .suppressed(.saverRunning))
    #expect(machine.alerts.isEmpty)
  }

  @Test(arguments: ["keep-awake", "native-saver", "displays"])
  func aFailedCheckStartsNothingAndIsLoggedOnce(check: String) {
    let machine = IdleMachine()
    machine.failures[check] = "cannot read \(check)"
    var observer = machine.observer()
    machine.idle = 300
    let first = observer.poll()
    #expect(first == 30)
    _ = observer.poll()
    #expect(machine.starts == 0)
    #expect(
      machine.logs == [
        "Idle check failed, so no screensaver starts until it succeeds: cannot read \(check)"
      ])

    machine.failures[check] = nil
    _ = observer.poll()
    #expect(machine.starts == 1)
  }

  @Test func aNewTimeoutAppliesOnTheNextPoll() {
    let machine = IdleMachine()
    var observer = machine.observer()
    machine.idle = 100
    _ = observer.poll()
    #expect(machine.starts == 0)
    machine.record = SaverIdleRecord(timeout: 60, paused: false)
    _ = observer.poll()
    #expect(machine.starts == 1)
    #expect(machine.logs == ["Started the screensaver after 1 minute idle."])
  }

  @Test func removingTheRecordEndsTheObserver() {
    let machine = IdleMachine()
    var observer = machine.observer()
    machine.idle = 100
    _ = observer.poll()
    machine.record = nil
    machine.idle = 400
    let wait = observer.poll()
    #expect(wait == nil)
    #expect(machine.starts == 0)
  }

  @Test func idleDurationsReadNaturally() {
    #expect(idleDuration(60) == "1 minute")
    #expect(idleDuration(300) == "5 minutes")
    #expect(idleDuration(3_600) == "1 hour")
    #expect(idleDuration(5_400) == "1 hour 30 minutes")
    #expect(idleDuration(14_400) == "4 hours")
    #expect(idleDuration(90) == "90 seconds")
  }
}

/// What the observer reads and causes: the record and its lock, idle seconds, the session, the
/// native saver, the displays, keep-awake, the saver engine, the clock, its log and its alerts.
private final class IdleMachine {
  static let start = Date(timeIntervalSince1970: 1_800_000_000)

  var record: SaverIdleRecord? = SaverIdleRecord(timeout: 300, paused: false)
  /// A change that takes the record's lock just before the next poll does.
  var beforeLock: (() -> Void)?
  var locked = false
  var idle: TimeInterval = 0
  var console = SaverIdleConsole.unlocked
  var nativeSaver = false
  var displaysAsleep = false
  var keepAwake = false
  /// Why the keep-awake, native-saver or displays check fails.
  var failures: [String: String] = [:]
  var running = false
  var startFailure: String?
  var startAnswer = SaverStart.started(.mainOnly(reason: "a test"), .banner(rejected: nil))
  var starts = 0
  var unlockedStarts = 0
  var stops = 0
  var now = IdleMachine.start
  var logs: [String] = []
  var alerts: [String] = []

  func observer() -> SaverIdleObserver {
    SaverIdleObserver(
      record: { self.record },
      exclusively: { body in
        self.beforeLock?()
        self.beforeLock = nil
        self.locked = true
        defer { self.locked = false }
        try body()
      },
      idleSeconds: { self.idle },
      console: { self.console },
      nativeSaverRunning: {
        try self.check("native-saver")
        return self.nativeSaver
      },
      displaysAsleep: {
        try self.check("displays")
        return self.displaysAsleep
      },
      keepAwakeActive: {
        try self.check("keep-awake")
        return self.keepAwake
      },
      saverRunning: { self.running },
      startSaver: {
        self.starts += 1
        if !self.locked { self.unlockedStarts += 1 }
        if let failure = self.startFailure { throw SaverError(failure) }
        if case .started = self.startAnswer { self.running = true }
        return self.startAnswer
      },
      stopSaver: {
        self.stops += 1
        guard self.running else { return .notRunning }
        self.running = false
        return .stopped
      },
      now: { self.now },
      log: { self.logs.append($0) },
      alert: { self.alerts.append($0) })
  }

  private func check(_ name: String) throws {
    if let failure = failures[name] { throw SaverError(failure) }
  }
}
