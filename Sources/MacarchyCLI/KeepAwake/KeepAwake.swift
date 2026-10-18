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
  static let barEvent = "macarchy_keep_awake_changed"
  /// With the live 50 ms pause, about two seconds for caffeinate to exit after SIGTERM.
  static let exitPolls = 40
  static let effect = "The display stays on; the idle screensaver and idle lock will not start."
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

  private var record: KeepAwakeRecord {
    KeepAwakeRecord(directory: stateRoot.appending(path: "run", directoryHint: .isDirectory))
  }

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

  /// Accepts `<n>h`, `<n>m` or `<n>h<n>m` from one minute to 24 hours.
  static func parseDuration(_ text: String) throws -> Duration {
    let invalid = ValidationError(
      "--for takes a duration from 1m to 24h, such as 30m, 2h or 1h30m; got '\(text)'")
    let scale: [Character: Int] = ["h": 60, "m": 1]
    var minutes = 0
    var digits = ""
    var lastUnit: Character?
    for character in text {
      if character.isASCII, character.isNumber {
        digits.append(character)
        continue
      }
      guard let unit = scale[character], let value = Int(digits), digits.count <= 4,
        lastUnit == nil || (lastUnit == "h" && character == "m")
      else { throw invalid }
      minutes += value * unit
      digits = ""
      lastUnit = character
    }
    guard digits.isEmpty, lastUnit != nil, (1...24 * 60).contains(minutes) else { throw invalid }
    return .seconds(minutes * 60)
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
      notifyBar: {
        Self.hintBar(
          processRunner: .live,
          installed: FileManager.default.isExecutableFile(
            atPath: SketchyBarCoreRuntimeVerifier.controlURL.path),
          warn: { try? FileHandle.standardError.write(contentsOf: Data("\($0)\n".utf8)) })
      })
  }

  /// Asks a running bar to refresh the indicator now. Its 30-second timer is the backstop, so a
  /// failed hint only warns and the session stays authoritative.
  static func hintBar(processRunner: ProcessRunner, installed: Bool, warn: (String) -> Void) {
    guard installed else { return }
    let result = try? processRunner.run(
      .init(
        executableURL: SketchyBarCoreRuntimeVerifier.controlURL,
        arguments: ["--trigger", barEvent], timeout: 1))
    if result?.terminationStatus == 0 { return }
    warn("The SketchyBar keep-awake indicator was not notified; it refreshes within 30 seconds.")
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

/// `<state root>/run/keep-awake.json`, beside the lock that serializes every access to it.
struct KeepAwakeRecord {
  static let name = "keep-awake.json"
  let directory: URL

  var url: URL { directory.appending(path: Self.name) }

  /// nil when absent or when its content is not a session record.
  func read() throws -> KeepAwakeSession? {
    try withDirectory { parent in
      let data: Data
      do {
        data =
          try PinnedFilesystem.readRegularFile(
            parentDescriptor: parent, name: Self.name, url: url, maximumSize: 4096
          ).data
      } catch let error as PinnedFilesystemError where error.code == ENOENT {
        return nil
      } catch BoundedRegularFileError.tooLarge {
        return nil
      }
      guard let session = try? JSONDecoder().decode(KeepAwakeSession.self, from: data),
        session.pid > 1, session.started > 0
      else { return nil }
      return session
    }
  }

  func write(_ session: KeepAwakeSession) throws {
    try withDirectory {
      try PinnedStateFile.write(session, parentDescriptor: $0, name: Self.name, url: url)
    }
  }

  func remove() throws {
    try withDirectory { parent in
      guard
        let failure = PinnedStateFile.remove(
          Self.name, parentDescriptor: parent, syncWhenAbsent: false)
      else { return }
      let operation = failure.step == .unlink ? "remove" : "sync the removal of"
      throw KeepAwakeError("cannot \(operation) \(url.path) (errno \(failure.code))")
    }
  }

  private func withDirectory<Value>(_ body: (Int32) throws -> Value) throws -> Value {
    let parent = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(parent) }
    return try body(parent)
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
