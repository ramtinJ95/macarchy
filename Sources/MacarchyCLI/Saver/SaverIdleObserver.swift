import AppKit
import CoreGraphics
import Darwin
import Foundation
import Synchronization
import ThemeCore

/// Why the observer holds off a start once the user has been idle for the timeout.
enum SaverIdleSuppression: CaseIterable, Sendable {
  case paused
  case keepAwake
  case sessionUnknown
  case offConsole
  case locked
  case sessionInactive
  case nativeSaver
  case displaysAsleep
  case saverRunning

  /// The animation yields to these, so a showing saver is stopped.
  var stopsSaver: Bool {
    switch self {
    case .paused, .keepAwake, .saverRunning: false
    case .sessionUnknown, .offConsole, .locked, .sessionInactive, .nativeSaver, .displaysAsleep:
      true
    }
  }

  var summary: String {
    switch self {
    case .paused: "idle activation is paused"
    case .keepAwake: "keep-awake is on"
    case .sessionUnknown: "the login session's state is unknown"
    case .offConsole: "the login session is not on the console"
    case .locked: "the screen is locked"
    case .sessionInactive: "the login session is inactive"
    case .nativeSaver: "the macOS screensaver is running"
    case .displaysAsleep: "the displays are asleep"
    case .saverRunning: "a Macarchy screensaver is already running"
    }
  }
}

/// What the window server's session dictionary says about this login session.
enum SaverIdleConsole: Equatable, Sendable {
  case unlocked
  case locked
  case offConsole
  /// No dictionary, or one without a readable console state.
  case unknown

  /// macOS adds CGSSessionScreenIsLocked to the dictionary only while the screen is locked.
  init(session: [String: Any]?) {
    guard let session, let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool else {
      self = .unknown
      return
    }
    guard onConsole else {
      self = .offConsole
      return
    }
    let screenLocked = session["CGSSessionScreenIsLocked"]
    if screenLocked == nil {
      self = .unlocked
    } else if let locked = screenLocked as? Bool {
      self = locked ? .locked : .unlocked
    } else {
      self = .unknown
    }
  }

  var suppression: SaverIdleSuppression? {
    switch self {
    case .unlocked: nil
    case .locked: .locked
    case .offConsole: .offConsole
    case .unknown: .sessionUnknown
    }
  }
}

/// A session notification the observer subscribes to.
enum SaverIdleSessionEvent: CaseIterable, Sendable {
  case screenLocked
  case screenUnlocked
  case nativeSaverStarted
  case nativeSaverStopped
  case displaysSlept
  case displaysWoke
  case sessionResigned
  case sessionActivated

  /// The suppression this event begins or ends.
  var suppression: SaverIdleSuppression {
    switch self {
    case .screenLocked, .screenUnlocked: .locked
    case .nativeSaverStarted, .nativeSaverStopped: .nativeSaver
    case .displaysSlept, .displaysWoke: .displaysAsleep
    case .sessionResigned, .sessionActivated: .sessionInactive
    }
  }

  var begins: Bool {
    switch self {
    case .screenLocked, .nativeSaverStarted, .displaysSlept, .sessionResigned: true
    case .screenUnlocked, .nativeSaverStopped, .displaysWoke, .sessionActivated: false
    }
  }

  /// Whether macOS posts this event as a distributed notification rather than an NSWorkspace one.
  var isDistributed: Bool {
    switch self {
    case .screenLocked, .screenUnlocked, .nativeSaverStarted, .nativeSaverStopped: true
    case .displaysSlept, .displaysWoke, .sessionResigned, .sessionActivated: false
    }
  }

  var notificationName: Notification.Name {
    switch self {
    case .screenLocked: Notification.Name("com.apple.screenIsLocked")
    case .screenUnlocked: Notification.Name("com.apple.screenIsUnlocked")
    case .nativeSaverStarted: Notification.Name("com.apple.screensaver.didstart")
    case .nativeSaverStopped: Notification.Name("com.apple.screensaver.didstop")
    case .displaysSlept: NSWorkspace.ScreensDidSleepMessage.name
    case .displaysWoke: NSWorkspace.ScreensDidWakeMessage.name
    case .sessionResigned: NSWorkspace.SessionDidResignActiveMessage.name
    case .sessionActivated: NSWorkspace.SessionDidBecomeActiveMessage.name
    }
  }
}

/// Where the observer is in the current idle period.
enum SaverIdleObserverState: Equatable, Sendable {
  /// Counting idle time toward the timeout.
  case armed
  /// The timeout has passed, and this holds off the start.
  case suppressed(SaverIdleSuppression)
  /// The saver this observer started is showing.
  case showing
  /// This idle period already had its start, or a failed one; the next start needs new activity.
  case waitingForActivity
}

/// `macarchy saver _idle`, the launch agent's long-running observer. It starts the saver once per
/// idle period and only over an unlocked, active session with awake displays. It stops a showing
/// saver when the screen locks, the displays sleep, the session resigns or the native saver
/// starts. Each poll rereads the idle record, so a pause or a new timeout applies without a
/// restart. A poll holds the record's lock from that read until its start returns, so a pause
/// never lands between the check and the start.
struct SaverIdleObserver {
  static let longestWait: TimeInterval = 30
  static let showingWait: TimeInterval = 5
  /// The same failure shows an alert at most this often.
  static let alertInterval: TimeInterval = 60 * 60

  let record: () throws -> SaverIdleRecord?
  /// Runs a poll under the lock every change to the record takes.
  let exclusively: (() throws -> Void) throws -> Void
  /// Seconds since the last keyboard, mouse or tablet input in this login session.
  let idleSeconds: () -> TimeInterval
  let console: () -> SaverIdleConsole
  /// Read before each start, because session notifications report only changes, so a native
  /// saver or display sleep that began before the observer started sends none.
  let nativeSaverRunning: () throws -> Bool
  let displaysAsleep: () throws -> Bool
  let keepAwakeActive: () throws -> Bool
  let saverRunning: () throws -> Bool
  let startSaver: () throws -> SaverStart
  let stopSaver: () throws -> SaverStop
  let now: () -> Date
  let log: (String) -> Void
  let alert: (String) -> Void

  var state = SaverIdleObserverState.armed
  /// What session notifications reported, until a notification reports it over.
  var reported: Set<SaverIdleSuppression> = []
  /// When each failure message last showed an alert.
  var alerted: [String: Date] = [:]
  /// The check failure logged last, so a lasting one is logged once.
  var failure: String?

  /// One cycle. Returns how long to wait before the next one, or nil once the idle record is gone.
  /// A failed check starts nothing.
  mutating func poll() -> TimeInterval? {
    do {
      var wait: TimeInterval?
      let exclusively = self.exclusively
      try exclusively { wait = try cycle() }
      failure = nil
      return wait
    } catch {
      let message = String(describing: error)
      if message != failure {
        log("Idle check failed, so no screensaver starts until it succeeds: \(message)")
      }
      failure = message
      return Self.longestWait
    }
  }

  mutating func handle(_ event: SaverIdleSessionEvent) {
    guard event.begins else {
      reported.remove(event.suppression)
      return
    }
    reported.insert(event.suppression)
    stop(because: event.suppression)
  }

  private mutating func cycle() throws -> TimeInterval? {
    guard let record = try record() else { return nil }
    let timeout = TimeInterval(record.timeout)
    let idle = idleSeconds()
    let console = console()
    var running = try saverRunning()
    if running, let reason = yielding(console) {
      stop(because: reason)
      running = try saverRunning()
    }
    if idle < timeout {
      state = .armed
      return min(max(timeout - idle, 1), Self.longestWait)
    }
    switch state {
    case .showing where running:
      return Self.showingWait
    case .showing, .waitingForActivity:
      state = .waitingForActivity
      return Self.longestWait
    case .armed, .suppressed:
      return try launch(record, console: console, running: running)
    }
  }

  private mutating func launch(
    _ record: SaverIdleRecord, console: SaverIdleConsole, running: Bool
  ) throws -> TimeInterval {
    let idle = idleDuration(record.timeout)
    if let reason = try suppression(record, console: console, running: running) {
      if state != .suppressed(reason) {
        log("Idle for \(idle); the screensaver waits because \(reason.summary).")
      }
      state = .suppressed(reason)
      return Self.longestWait
    }
    do {
      switch try startSaver() {
      case .started:
        state = .showing
        log("Started the screensaver after \(idle) idle.")
        return Self.showingWait
      case .alreadyRunning, .alreadyStarting:
        state = .suppressed(.saverRunning)
        return Self.longestWait
      }
    } catch {
      state = .waitingForActivity
      report(error)
      return Self.longestWait
    }
  }

  private func suppression(
    _ record: SaverIdleRecord, console: SaverIdleConsole, running: Bool
  ) throws -> SaverIdleSuppression? {
    if record.paused { return .paused }
    if try keepAwakeActive() { return .keepAwake }
    if let reason = yielding(console) { return reason }
    if try nativeSaverRunning() { return .nativeSaver }
    if try displaysAsleep() { return .displaysAsleep }
    return running ? .saverRunning : nil
  }

  /// The session dictionary decides first; the notifications cover what it does not show.
  private func yielding(_ console: SaverIdleConsole) -> SaverIdleSuppression? {
    console.suppression ?? SaverIdleSuppression.allCases.first(where: reported.contains)
  }

  private mutating func stop(because reason: SaverIdleSuppression) {
    do {
      if try stopSaver() == .stopped {
        log("Stopped the screensaver because \(reason.summary).")
      }
    } catch {
      log("Could not stop the screensaver when \(reason.summary): \(error)")
    }
    if state == .showing { state = .waitingForActivity }
  }

  private mutating func report(_ error: any Error) {
    let message = String(describing: error)
    log("The screensaver did not start: \(message)")
    let date = now()
    if let last = alerted[message], abs(date.timeIntervalSince(last)) < Self.alertInterval {
      return
    }
    alerted[message] = date
    alert(message)
  }
}

/// Session notifications, which may arrive on any thread between polls.
final class SaverIdleInbox: Sendable {
  private let events = Mutex<[SaverIdleSessionEvent]>([])

  func post(_ event: SaverIdleSessionEvent) {
    events.withLock { $0.append(event) }
  }

  func drain() -> [SaverIdleSessionEvent] {
    events.withLock { pending in
      let drained = pending
      pending.removeAll()
      return drained
    }
  }
}

extension SaverIdleObserver {
  static func live(stateRoot: URL, alert: @escaping (String) -> Void) -> Self {
    let sessions = Saver.live(stateRoot: stateRoot)
    return Self(
      record: { try SaverIdleRecord.runState(stateRoot: stateRoot).read() },
      exclusively: { body in try SaverIdleRecord.lock.withLock(root: stateRoot, body) },
      idleSeconds: {
        // kCGAnyInputEventType, which Swift does not import.
        CGEventSource.secondsSinceLastEventType(
          .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
      },
      console: { SaverIdleConsole(session: CGSessionCopyCurrentDictionary() as? [String: Any]) },
      nativeSaverRunning: nativeSaverProcessRuns, displaysAsleep: noDisplayIsAwake,
      keepAwakeActive: { try KeepAwake.live(stateRoot: stateRoot).status() != .off },
      saverRunning: { try sessions.isRunning() },
      // A fresh engine each time finds a Kitty or ttfx installed since the observer started.
      startSaver: { try Saver.live(stateRoot: stateRoot).start() },
      stopSaver: { try sessions.stop() },
      now: Date.init,
      log: { line in
        let entry = "\(Date().formatted(.iso8601)) \(line)\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(entry.utf8))
      },
      alert: alert)
  }

  /// Whether one of this user's processes is the macOS screensaver. The kernel answers afresh on
  /// every call, unlike NSWorkspace's running applications, which change only as the main run
  /// loop delivers their updates. A list it cannot read in full, or a live process whose path it
  /// cannot resolve, throws, so the observer does not launch over a saver it failed to see.
  private static func nativeSaverProcessRuns() throws -> Bool {
    let user = UInt32(getuid())
    let pidSize = MemoryLayout<Int32>.stride
    let needed = proc_listpids(UInt32(PROC_UID_ONLY), user, nil, 0)
    guard needed > 0 else { throw SaverError("cannot list your processes (errno \(errno))") }
    // Room for processes that start between the two calls.
    var pids = [Int32](repeating: 0, count: Int(needed) / pidSize + 64)
    let capacity = Int32(pids.count * pidSize)
    let filled = proc_listpids(UInt32(PROC_UID_ONLY), user, &pids, capacity)
    guard filled > 0 else { throw SaverError("cannot list your processes (errno \(errno))") }
    guard filled < capacity else {
      throw SaverError("your process list grew faster than it could be read")
    }
    for pid in pids.prefix(Int(filled) / pidSize) where pid > 0 {
      guard let path = processExecutablePath(pid) else {
        if hasExited(pid) { continue }
        throw SaverError("cannot read the executable path of one of your processes")
      }
      if path.hasSuffix("/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine") { return true }
    }
    return false
  }

  /// A process that exited since the listing, or a zombie awaiting its parent, has no path and
  /// is not the screensaver.
  private static func hasExited(_ pid: Int32) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return kill(pid, 0) != 0 && errno == ESRCH
    }
    return info.pbi_status == UInt32(SZOMB)
  }

  /// A sleeping display is not drawable, so it may leave the active list. The online list keeps
  /// it, and an empty list counts as asleep too.
  private static func noDisplayIsAwake() throws -> Bool {
    var count: UInt32 = 0
    let counted = CGGetOnlineDisplayList(0, nil, &count)
    guard counted == .success else {
      throw SaverError("cannot list the displays (CGError \(counted.rawValue))")
    }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    let listed = CGGetOnlineDisplayList(count, &displays, &count)
    guard listed == .success else {
      throw SaverError("cannot list the displays (CGError \(listed.rawValue))")
    }
    return !displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
  }

  /// Polls until the idle record is gone. Session notifications are handled between polls, and a
  /// notification on the main run loop ends the wait at once.
  @MainActor
  static func run(_ observer: Self) {
    var observer = observer
    let inbox = SaverIdleInbox()
    let subscriptions = subscribe(inbox)
    defer {
      for (center, token) in subscriptions { center.removeObserver(token) }
    }
    var due = Date.distantPast
    while true {
      for event in inbox.drain() { observer.handle(event) }
      if Date() >= due {
        guard let wait = observer.poll() else { return }
        due = Date(timeIntervalSinceNow: wait)
      }
      // Without a timer, a run loop with no other source returns at once.
      RunLoop.current.add(Timer(fire: due, interval: 0, repeats: false) { _ in }, forMode: .default)
      _ = RunLoop.current.run(mode: .default, before: due)
    }
  }

  /// Delivery runs on the posting thread, because this process's main queue may not be serviced
  /// while the observer runs.
  @MainActor
  private static func subscribe(
    _ inbox: SaverIdleInbox
  ) -> [(NotificationCenter, any NSObjectProtocol)] {
    let distributed: NotificationCenter = DistributedNotificationCenter.default()
    let workspace = NSWorkspace.shared.notificationCenter
    return SaverIdleSessionEvent.allCases.map { event in
      let center = event.isDistributed ? distributed : workspace
      let token = center.addObserver(
        forName: event.notificationName, object: nil, queue: nil
      ) { _ in inbox.post(event) }
      return (center, token)
    }
  }
}
