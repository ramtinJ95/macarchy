import ArgumentParser
import Darwin
import Foundation
import ThemeCore

/// Macarchy's record of the caffeinate process it launched.
struct KeepAwakeSession: Codable, Equatable, Sendable {
  let pid: Int32
  /// Process start identity in microseconds (`processStartTime`).
  let started: UInt64
  /// nil keeps the session until it is turned off.
  let expires: Date?
}

/// Derived from the record and the live process on every read; never stored.
enum KeepAwakeStatus: Equatable, Sendable {
  case off
  case on(KeepAwakeSession)
}

enum KeepAwakeRequest: Equatable, Sendable {
  case on(Duration?)
  case off
  case toggle
}

enum KeepAwakeChange: Equatable, Sendable {
  case started(KeepAwakeSession)
  case alreadyOn(KeepAwakeSession)
  case stopped
  case alreadyOff
}

struct KeepAwakeProcess: Equatable, Sendable {
  let started: UInt64
  let executablePath: String
}

struct KeepAwakeError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Owns at most one `caffeinate -d -i` process per state root. A record is Macarchy's only while
/// its PID still has the recorded start time and the caffeinate executable. Any other record is
/// stale: it is removed and that PID is never signalled.
struct KeepAwake {
  static let caffeinatePath = "/usr/bin/caffeinate"
  static let barEvent = SketchyBarConfigurationComposer.keepAwakeEvent
  /// With the live 50 ms pause, about two seconds for caffeinate to exit after SIGTERM.
  static let exitPolls = 40
  static let effect = "The display stays on; the idle screensaver and idle lock will not start."
  static let duration = DurationOption(flag: "--for", maximumMinutes: 24 * 60)
  private static let lock = ProcessScopedFileLock<KeepAwakeError>(
    filename: "keep-awake.lock",
    cannotCreateRunDirectory: { url, error in
      KeepAwakeError("cannot create \(url.path): \(error)")
    },
    operationError: { operation, code in
      KeepAwakeError("cannot \(operation) the keep-awake lock (errno \(code))")
    })

  let stateRoot: URL
  let spawn: ([String]) throws -> Int32
  let process: (Int32) -> KeepAwakeProcess?
  let terminate: (Int32) throws -> Void
  let pause: () -> Void
  let now: () -> Date
  let notifyBar: () -> Void

  /// `<state root>/run/keep-awake.json`.
  static func sessionRecord(stateRoot: URL) -> RunStateRecord<KeepAwakeSession> {
    RunStateRecord("keep-awake.json", stateRoot: stateRoot) { $0.pid > 1 && $0.started > 0 }
  }

  private var record: RunStateRecord<KeepAwakeSession> { Self.sessionRecord(stateRoot: stateRoot) }

  func status() throws -> KeepAwakeStatus {
    try Self.lock.withLock(root: stateRoot) { try current() }
  }

  func apply(_ request: KeepAwakeRequest) throws -> KeepAwakeChange {
    let change = try Self.lock.withLock(root: stateRoot) { () throws -> KeepAwakeChange in
      let status = try current()
      switch (request, status) {
      case (.off, .off):
        return .alreadyOff
      case (.off, .on(let session)), (.toggle, .on(let session)):
        try stop(session)
        return .stopped
      case (.toggle, .off):
        return .started(try start(nil))
      case (.on(.none), .on(let session)) where session.expires == nil:
        return .alreadyOn(session)
      case (.on(let duration), .on(let session)):
        try stop(session)
        return .started(try start(duration))
      case (.on(let duration), .off):
        return .started(try start(duration))
      }
    }
    switch change {
    case .started, .stopped: notifyBar()
    case .alreadyOn, .alreadyOff: break
    }
    return change
  }

  private func current() throws -> KeepAwakeStatus {
    if let session = try record.read(), owns(session) { return .on(session) }
    try record.remove()
    return .off
  }

  private func owns(_ session: KeepAwakeSession) -> Bool {
    process(session.pid)
      == KeepAwakeProcess(started: session.started, executablePath: Self.caffeinatePath)
  }

  private func start(_ duration: Duration?) throws -> KeepAwakeSession {
    let seconds = duration?.components.seconds
    let pid = try spawn(["-d", "-i"] + (seconds.map { ["-t", String($0)] } ?? []))
    let expires = seconds.map { now().addingTimeInterval(TimeInterval($0)) }
    guard let identity = process(pid), identity.executablePath == Self.caffeinatePath else {
      throw abandon(pid, KeepAwakeError("cannot establish the identity of caffeinate \(pid)"))
    }
    let session = KeepAwakeSession(pid: pid, started: identity.started, expires: expires)
    do {
      try record.write(session)
    } catch {
      throw abandon(pid, error)
    }
    return session
  }

  /// An unrecorded caffeinate could never be turned off again, so it must not outlive the failure.
  private func abandon(_ pid: Int32, _ error: any Error) -> any Error {
    do {
      try terminate(pid)
      return error
    } catch let cleanup {
      return KeepAwakeError("\(error); stopping caffeinate \(pid) also failed: \(cleanup)")
    }
  }

  private func stop(_ session: KeepAwakeSession) throws {
    try terminate(session.pid)
    var polls = 0
    while owns(session) {
      guard polls < Self.exitPolls else {
        throw KeepAwakeError(
          "caffeinate \(session.pid) did not exit after SIGTERM; keep-awake stays on")
      }
      pause()
      polls += 1
    }
    try record.remove()
  }
}

extension KeepAwake {
  static func live(stateRoot: URL) -> Self {
    Self(
      stateRoot: stateRoot,
      spawn: spawnCaffeinate,
      process: { pid in
        guard let started = processStartTime(pid), let path = processExecutablePath(pid) else {
          return nil
        }
        return KeepAwakeProcess(started: started, executablePath: path)
      },
      terminate: { pid in
        guard kill(pid, SIGTERM) != 0 else { return }
        let code = errno
        guard code == ESRCH else {
          throw KeepAwakeError("cannot signal caffeinate \(pid) (errno \(code))")
        }
      },
      pause: { Thread.sleep(forTimeInterval: 0.05) },
      now: Date.init,
      notifyBar: { ClockCompanion.hintRunningBar(event: barEvent) })
  }

  /// Starts caffeinate in its own session with null standard streams, so closing the launching
  /// terminal or bar script does not end it. It is never reaped here: the command exits right
  /// after, and launchd reaps the reparented process.
  private static func spawnCaffeinate(_ arguments: [String]) throws -> Int32 {
    func require(_ code: Int32, _ operation: String) throws {
      guard code == 0 else {
        throw KeepAwakeError("cannot \(operation) caffeinate (errno \(code))")
      }
    }
    var attributes: posix_spawnattr_t?
    try require(posix_spawnattr_init(&attributes), "prepare")
    defer { posix_spawnattr_destroy(&attributes) }
    try require(
      posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)),
      "prepare")
    var actions: posix_spawn_file_actions_t?
    try require(posix_spawn_file_actions_init(&actions), "prepare")
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (descriptor, flags) in [
      (STDIN_FILENO, O_RDONLY), (STDOUT_FILENO, O_WRONLY), (STDERR_FILENO, O_WRONLY),
    ] {
      try require(
        posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", flags, 0), "prepare")
    }
    let argv = [caffeinatePath] + arguments
    let storage = argv.compactMap { strdup($0) }
    defer {
      for pointer in storage { free(pointer) }
    }
    guard storage.count == argv.count else {
      throw KeepAwakeError("cannot allocate caffeinate arguments")
    }
    var pointers: [UnsafeMutablePointer<CChar>?] = storage.map { $0 } + [nil]
    var pid: pid_t = 0
    try require(
      posix_spawn(&pid, caffeinatePath, &actions, &attributes, &pointers, environ), "launch")
    return pid
  }
}

extension KeepAwakeSession {
  /// "until turned off", or the local 24-hour end time the bar clock also uses.
  var until: String {
    guard let expires else { return "until turned off" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return "until \(formatter.string(from: expires))"
  }
}

extension KeepAwakeChange {
  var message: String {
    switch self {
    case .started(let session): "Keep-awake on \(session.until). \(KeepAwake.effect)"
    case .alreadyOn(let session): "Keep-awake was already on \(session.until). \(KeepAwake.effect)"
    case .stopped: "Keep-awake off."
    case .alreadyOff: "Keep-awake was already off."
    }
  }
}

extension KeepAwakeStatus {
  var message: String {
    switch self {
    case .off: "Keep-awake is off."
    case .on(let session): "Keep-awake is on \(session.until). \(KeepAwake.effect)"
    }
  }

  func renderJSON() throws -> String {
    var document: [String: Any] = ["state": "off", "expires": NSNull()]
    if case .on(let session) = self {
      document["state"] = "on"
      if let expires = session.expires { document["expires"] = expires.formatted(.iso8601) }
    }
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
