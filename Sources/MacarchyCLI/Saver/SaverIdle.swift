import Darwin
import Foundation
import ThemeCore

/// `<state root>/run/saver-idle.json`, which exists while idle activation is on.
struct SaverIdleRecord: Codable, Equatable, Sendable {
  static let defaultTimeout = 5 * 60
  static let timeouts = 60...(4 * 60 * 60)
  /// Held by every change to the record and by each observer poll, from its read of the record
  /// until its start returns.
  static let lock = ProcessScopedFileLock<SaverError>(
    filename: "saver-idle.lock",
    cannotCreateRunDirectory: { url, error in SaverError("cannot create \(url.path): \(error)") },
    operationError: { operation, code in
      SaverError("cannot \(operation) the idle screensaver lock (errno \(code))")
    })

  /// Idle seconds before the saver starts.
  let timeout: Int
  let paused: Bool

  static func runState(stateRoot: URL) -> RunStateRecord<Self> {
    RunStateRecord("saver-idle.json", stateRoot: stateRoot) { Self.timeouts.contains($0.timeout) }
  }
}

/// "5 minutes", "1 hour 30 minutes" or "90 seconds".
func idleDuration(_ seconds: Int) -> String {
  func count(_ value: Int, _ unit: String) -> String {
    value == 1 ? "1 \(unit)" : "\(value) \(unit)s"
  }
  guard seconds % 60 == 0 else { return count(seconds, "second") }
  let (hours, minutes) = (seconds / 60).quotientAndRemainder(dividingBy: 60)
  if hours == 0 { return count(minutes, "minute") }
  return minutes == 0 ? count(hours, "hour") : "\(count(hours, "hour")) \(count(minutes, "minute"))"
}

enum SaverIdleChange: Equatable, Sendable {
  case turnedOn(SaverIdleRecord)
  case alreadyOn(SaverIdleRecord)
  case turnedOff
  case alreadyOff
}

enum SaverPauseRequest: Equatable, Sendable {
  case pause
  case resume
  case toggle
}

enum SaverPauseChange: Equatable, Sendable {
  case paused
  case alreadyPaused
  case resumed
  case alreadyResumed
}

/// Derived from the launch agent, launchd and the record on every read; never stored.
struct SaverIdleActivation: Equatable {
  let agent: OwnedLaunchAgentFile
  let loaded: Bool
  let record: SaverIdleRecord?

  /// The record while idle activation runs: its record, its own plist and a loaded job.
  var enabled: SaverIdleRecord? { agent == .owned && loaded ? record : nil }

  /// Whether the bar shows the pause indicator. A paused record without its running observer
  /// does not count, since nothing would be paused.
  var isPaused: Bool { enabled?.paused == true }
}

/// Turns idle activation on and off and pauses it. The record's lock serializes every change, so
/// on, off and pause never interleave, and none lands between an observer's check and its start.
struct SaverIdle {
  static let barEvent = SketchyBarConfigurationComposer.saverIdleEvent
  static let timeout = DurationOption(flag: "--after", maximumMinutes: 4 * 60)

  let stateRoot: URL
  let agent: OwnedLaunchAgent
  let nativeTimers: () -> SaverNativeTimers
  let notifyBar: () -> Void

  private var record: RunStateRecord<SaverIdleRecord> {
    SaverIdleRecord.runState(stateRoot: stateRoot)
  }

  func activation() throws -> SaverIdleActivation {
    try SaverIdleRecord.lock.withLock(root: stateRoot) { try current() }
  }

  func status() throws -> SaverIdleStatus {
    SaverIdleStatus(activation: try activation(), timers: nativeTimers())
  }

  /// Installs and loads the launch agent and writes the record. `after` replaces the timeout;
  /// without it, an existing timeout stays. A pause stays either way.
  func turnOn(after duration: Duration?) throws -> SaverIdleChange {
    try locked { try on(after: duration) }
  }

  /// Boots the job out, then removes the plist and the record.
  func turnOff() throws -> SaverIdleChange {
    try locked { try off() }
  }

  /// Turns idle activation off while it runs, otherwise on with its stored timeout or the
  /// default. An incomplete activation counts as off, so toggling finishes turning it on.
  func toggle() throws -> SaverIdleChange {
    try locked {
      let activation = try current()
      if case .conflict = activation.agent { throw agent.conflict }
      return try activation.enabled == nil ? on(after: nil) : off()
    }
  }

  /// The native-timer warnings that keep the screensaver from showing once `change` leaves idle
  /// activation on; none once it is off.
  func warnings(after change: SaverIdleChange) -> [String] {
    change.record.map { nativeTimers().warnings(timeout: $0.timeout) } ?? []
  }

  /// Runs `body` under the record lock and hints the bar when it changed idle activation.
  private func locked(_ body: () throws -> SaverIdleChange) throws -> SaverIdleChange {
    let change = try SaverIdleRecord.lock.withLock(root: stateRoot, body)
    switch change {
    case .turnedOn, .turnedOff: notifyBar()
    case .alreadyOn, .alreadyOff: break
    }
    return change
  }

  private func on(after duration: Duration?) throws -> SaverIdleChange {
    let installed = try agent.install()
    let previous = try record.read()
    let next = SaverIdleRecord(
      timeout: duration.map { Int($0.components.seconds) } ?? previous?.timeout
        ?? SaverIdleRecord.defaultTimeout,
      paused: previous?.paused ?? false)
    // The observer exits when it finds no record, so the record comes before the job.
    if next != previous { try record.write(next) }
    let loaded = try agent.load()
    // launchd keeps an observer that exited cleanly loaded but stopped. A kickstart runs it
    // again and leaves a running one alone.
    try agent.kickstart()
    return installed || loaded || next != previous ? .turnedOn(next) : .alreadyOn(next)
  }

  private func off() throws -> SaverIdleChange {
    // A job loaded from somebody else's plist under this label is not Macarchy's to stop.
    if case .conflict = try agent.file() { throw agent.conflict }
    let unloaded = try agent.unload()
    let removed = try agent.remove()
    let recorded: Bool
    do {
      recorded = try record.readStrictly() != nil
    } catch is InvalidRunStateRecord {
      recorded = true
    }
    try record.remove()
    return unloaded || removed || recorded ? .turnedOff : .alreadyOff
  }

  /// Pausing holds off idle starts until resumed; it never stops a showing saver.
  func apply(_ request: SaverPauseRequest) throws -> SaverPauseChange {
    let change = try SaverIdleRecord.lock.withLock(root: stateRoot) {
      () throws -> SaverPauseChange in
      let activation = try current()
      if case .conflict = activation.agent { throw agent.conflict }
      guard let enabled = activation.enabled else {
        throw SaverError(
          "Idle activation is not on, so there is nothing to pause or resume. Run "
            + "`macarchy saver idle on` first.")
      }
      let paused =
        switch request {
        case .pause: true
        case .resume: false
        case .toggle: !enabled.paused
        }
      guard paused != enabled.paused else { return paused ? .alreadyPaused : .alreadyResumed }
      try record.write(SaverIdleRecord(timeout: enabled.timeout, paused: paused))
      return paused ? .paused : .resumed
    }
    switch change {
    case .paused, .resumed: notifyBar()
    case .alreadyPaused, .alreadyResumed: break
    }
    return change
  }

  private func current() throws -> SaverIdleActivation {
    SaverIdleActivation(
      agent: try agent.file(), loaded: try agent.isLoaded(), record: try record.read())
  }
}

extension OwnedLaunchAgent {
  /// Keeps `macarchy saver _idle` running in the login session. launchd restarts it after a
  /// crash, not after it exits because idle activation was turned off.
  static func saverIdle(
    home: URL, stateRoot: URL, executable: URL, userID: uid_t, runner: ProcessRunner
  ) -> Self {
    Self(
      label: "io.github.ramtinj95.macarchy.saver-idle", purpose: "the idle screensaver",
      home: home, stateRoot: stateRoot, userID: userID, runner: runner,
      programArguments: [executable.path, "saver", "_idle", "--state-root", stateRoot.path],
      logName: "saver-idle",
      keys: [
        "KeepAlive": ["SuccessfulExit": false],
        // Background jobs get coarse timers, which would delay a start and a stop on lock.
        "ProcessType": "Interactive",
      ])
  }
}

extension SaverIdle {
  static func live(stateRoot: URL) -> Self {
    Self(
      stateRoot: stateRoot,
      agent: .saverIdle(
        home: FileManager.default.homeDirectoryForCurrentUser, stateRoot: stateRoot,
        executable: RuntimeEnvironment.live.persistentCommandURL, userID: getuid(),
        runner: .live),
      nativeTimers: { .read(processRunner: .live) },
      notifyBar: { ClockCompanion.hintRunningBar(event: barEvent) })
  }
}

/// What `macarchy saver status` reports about idle activation.
struct SaverIdleStatus: Equatable {
  let activation: SaverIdleActivation
  let timers: SaverNativeTimers

  /// Shown only while there is a timeout to compare with.
  var warnings: [String] {
    activation.record.map { timers.warnings(timeout: $0.timeout) } ?? []
  }

  var message: String {
    let lines = [
      activationLine, "macOS screensaver: \(timers.screensaver.summary)",
      "Display sleep: \(timers.displaySleep.summary)",
    ]
    return (lines + warnings).joined(separator: "\n")
  }

  var json: [String: Any] {
    let state =
      switch activation.agent {
      case .absent: "off"
      case .owned: "on"
      case .conflict: "conflict"
      }
    var timeout: Any = NSNull()
    if let record = activation.record { timeout = record.timeout }
    return [
      "state": state, "loaded": activation.loaded, "timeout": timeout,
      "paused": activation.record?.paused ?? false, "nativeScreensaver": timers.screensaver.json,
      "displaySleep": timers.displaySleep.json, "warnings": warnings,
    ]
  }

  private var activationLine: String {
    if case .conflict(let url) = activation.agent {
      return "Idle activation: off, because \(url.path) is not the launch agent this Macarchy "
        + "writes. Macarchy does not change or remove it."
    }
    if let enabled = activation.enabled {
      let line =
        "Idle activation: on; the screensaver starts after \(idleDuration(enabled.timeout)) idle."
      return enabled.paused
        ? line + " Paused: run `macarchy saver resume` or click the pause icon left of the clock."
        : line
    }
    let missing: String
    switch (activation.agent, activation.record) {
    case (.absent, .none):
      return "Idle activation: off. Run `macarchy saver idle on` to start the screensaver after "
        + "\(idleDuration(SaverIdleRecord.defaultTimeout)) idle."
    case (.absent, .some): missing = "its launch agent is missing"
    case (_, .none): missing = "its record is missing"
    default: missing = "its launch agent is not loaded"
    }
    return "Idle activation: incomplete, because \(missing). Run `macarchy saver idle on` to "
      + "finish turning it on, or `macarchy saver idle off` to remove it."
  }
}

/// What `macarchy saver status` reports: the screensaver itself and idle activation.
struct SaverReport {
  let saver: SaverStatus
  let idle: SaverIdleStatus

  var message: String { saver.message + "\n" + idle.message }

  func renderJSON() throws -> String {
    var document = saver.json
    document["idle"] = idle.json
    let data = try JSONSerialization.data(
      withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }
}

extension SaverIdleChange {
  /// The record idle activation runs with after this change; nil once it is off.
  var record: SaverIdleRecord? {
    switch self {
    case .turnedOn(let record), .alreadyOn(let record): record
    case .turnedOff, .alreadyOff: nil
    }
  }

  var message: String {
    switch self {
    case .turnedOn(let record):
      "Idle screensaver on: it starts after \(idleDuration(record.timeout)) idle. It is decorative, "
        + "not a lock." + Self.pauseNote(record)
    case .alreadyOn(let record):
      "Idle screensaver was already on: it starts after \(idleDuration(record.timeout)) idle."
        + Self.pauseNote(record)
    case .turnedOff: "Idle screensaver off."
    case .alreadyOff: "Idle screensaver was already off."
    }
  }

  private static func pauseNote(_ record: SaverIdleRecord) -> String {
    record.paused ? " It is paused; run `macarchy saver resume` to resume it." : ""
  }
}

extension SaverPauseChange {
  var message: String {
    switch self {
    case .paused:
      "Idle screensaver paused. Run `macarchy saver resume` or click the pause icon left of the "
        + "clock to resume it."
    case .alreadyPaused: "Idle screensaver was already paused."
    case .resumed: "Idle screensaver resumed."
    case .alreadyResumed: "Idle screensaver was not paused."
    }
  }
}
