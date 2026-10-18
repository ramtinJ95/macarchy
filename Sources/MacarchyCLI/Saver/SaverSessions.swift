import Darwin
import Foundation
import ThemeCore

enum SaverStart: Equatable, Sendable {
  case started(SaverCoverage, SaverText)
  case alreadyRunning
  /// Another start is still waiting for its panels.
  case alreadyStarting

  func message(textFile: URL) -> String {
    switch self {
    case .alreadyRunning:
      return "The screensaver is already running."
    case .alreadyStarting:
      return "The screensaver is already starting."
    case .started(let coverage, let text):
      let covered =
        switch coverage {
        case .outputs(let names): "Screensaver started on \(names.joined(separator: ", "))."
        case .mainOnly(let reason):
          "Screensaver started; it covers the main display only because \(reason)."
        }
      let notice = text.notice(textFile: textFile).map { " \($0)" } ?? ""
      return covered + " Press any key or move the mouse to dismiss it." + notice
    }
  }
}

enum SaverStop: Equatable, Sendable {
  case stopped
  case notRunning

  var message: String {
    switch self {
    case .stopped: "Screensaver stopped."
    case .notRunning: "The screensaver was not running."
    }
  }
}

/// Starts, stops and reports Macarchy's saver sessions. A session is Macarchy's only while its
/// processes still match their record; nothing unverified is ever signalled, and Kitty or ttfx
/// processes Macarchy did not record are never touched.
struct Saver {
  /// What a start finds under the lock.
  private enum Opening {
    case running
    case starting
    case opened(Launched)
  }

  /// The panels one start opened, while it waits for their runners to register.
  private struct Launched {
    let token: String
    let coverage: SaverCoverage
    let text: SaverText
    /// Why `open` failed, for each display it failed on.
    let failures: [SaverDisplay: String]

    var opened: [SaverDisplay] { coverage.displays.filter { failures[$0] == nil } }
  }

  /// With the live pause, about five seconds for every panel's runner to register.
  static let registrationPolls = 100
  /// About two seconds for a signalled process to exit.
  static let exitPolls = 40
  static let pauseInterval: TimeInterval = 0.05
  /// A launch record this close to now belongs to a start still waiting for its runners. Any
  /// other belongs to a start that crashed and is replaced, so neither a crash nor a clock change
  /// holds off starts for longer than the registration wait and a margin.
  static let launchWindow = Double(registrationPolls) * pauseInterval + 5

  let stateRoot: URL
  let engine: SaverEngine
  let kitty: SaverKitty
  /// The persistent macarchy path each panel runs.
  let command: URL
  let palette: () throws -> SaverPalette
  let text: () -> SaverText
  let coverage: () -> SaverCoverage
  /// Runs `/usr/bin/open` with these arguments to completion.
  let launch: ([String]) throws -> Void
  let observe: (Int32) -> SaverProcess?
  let terminate: (Int32) throws -> Void
  let pause: () -> Void
  let now: () -> Date

  var records: SaverRecords { SaverRecords(stateRoot: stateRoot) }

  func status() throws -> SaverStatus {
    let sessions = try records.entries().compactMap(\.record).filter { owns($0.runner) }
    return SaverStatus(
      engine: engine, kitty: kitty, textFile: SaverText.fileURL(stateRoot: stateRoot),
      text: text(), sessions: sessions.sorted { $0.display.label < $1.display.label })
  }

  /// Whether a session's runner still matches its record, read without the lock.
  func isRunning() throws -> Bool {
    try records.entries().contains { $0.record.map { owns($0.runner) } ?? false }
  }

  func start() throws -> SaverStart {
    guard kitty != .missing else {
      throw SaverError("Kitty is missing at \(SaverKitty.application.path). \(SaverKitty.remedy)")
    }
    if let defect = engine.defect {
      throw SaverError(
        "The ttfx engine at \(engine.url.path) is \(defect.summary). \(SaverEngine.remedy)")
    }
    // Runners register under the lock, so start releases it while it waits for them.
    switch try records.withLock({ try openPanels() }) {
    case .running: return .alreadyRunning
    case .starting: return .alreadyStarting
    case .opened(let launched):
      try awaitRegistration(launched)
      return try records.withLock { try settle(launched) }
    }
  }

  func stop() throws -> SaverStop {
    try records.withLock { () throws -> SaverStop in
      try records.launch.remove()
      return try stop(try records.entries()) ? .stopped : .notRunning
    }
  }

  /// Opens one panel per display under a new launch, unless a session runs or another start
  /// still waits for its panels.
  private func openPanels() throws -> Opening {
    if let pending = try records.launch.read(),
      abs(now().timeIntervalSince(pending.created)) < Self.launchWindow
    {
      return .starting
    }
    let entries = try records.entries()
    guard !entries.contains(where: { $0.record.map { owns($0.runner) } ?? false }) else {
      return .running
    }
    try stop(entries)
    let colors = try palette()
    let covered = coverage()
    let shown = text()
    let token = SaverLaunch.randomToken()
    try records.create()
    var failures: [SaverDisplay: String] = [:]
    for display in covered.displays {
      do {
        try launch(
          SaverHost.panelArguments(
            for: display, token: token, palette: colors, stateRoot: stateRoot, command: command))
      } catch {
        failures[display] = String(describing: error)
      }
    }
    // No runner can register before start releases the lock, so the record's age measures only
    // the wait for them, however long `open` took.
    try records.launch.write(SaverLaunch(token: token, created: now()))
    return .opened(Launched(token: token, coverage: covered, text: shown, failures: failures))
  }

  /// Returns once every opened panel's runner has registered or the bound has passed.
  private func awaitRegistration(_ launched: Launched) throws {
    var polls = 0
    while polls < Self.registrationPolls {
      let displays = try Set(registered(launched).map(\.display))
      guard !displays.isSuperset(of: launched.opened) else { return }
      pause()
      polls += 1
    }
  }

  /// Closes the launch, so a runner that arrives later never plays, and keeps the start only if
  /// every display's panel opened and its runner registered.
  private func settle(_ launched: Launched) throws -> SaverStart {
    if try records.launch.read()?.token == launched.token {
      try records.launch.remove()
    }
    let registered = try registered(launched)
    let missing = launched.coverage.displays.filter { display in
      launched.failures[display] != nil || !registered.contains { $0.display == display }
    }
    guard missing.isEmpty else {
      let reasons = missing.map { display in
        let reason = launched.failures[display] ?? "its panel did not start within 5 seconds"
        return "\(display.label) (\(reason))"
      }
      throw abandon(registered, missing: reasons)
    }
    return .started(launched.coverage, launched.text)
  }

  /// The runners of this launch that registered and still match their records, on any display:
  /// an `open` that failed, by timing out for example, may still have opened its panel.
  private func registered(_ launched: Launched) throws -> [SaverRunnerRecord] {
    try launched.coverage.displays.compactMap { try records.record($0).read() }
      .filter { $0.launch == launched.token && owns($0.runner) }
  }

  /// A partial start is no start: the displays that did register are stopped again.
  private func abandon(_ registered: [SaverRunnerRecord], missing: [String]) -> SaverError {
    let failure = "The screensaver did not start on \(missing.joined(separator: ", "))"
    guard !registered.isEmpty else { return SaverError(failure + ".") }
    do {
      try stop(registered.map { SaverRecordEntry(name: $0.display.recordName, record: $0) })
      return SaverError(failure + ". Stopped the displays that did start.")
    } catch {
      return SaverError(failure + "; stopping the displays that did start also failed: \(error)")
    }
  }

  /// SIGTERMs every runner that still matches its record, then any panel Kitty that outlives its
  /// runner and still matches its record, and removes each record whose processes are gone.
  /// Returns whether anything was signalled.
  @discardableResult
  private func stop(_ entries: [SaverRecordEntry]) throws -> Bool {
    let sessions = entries.compactMap(\.record)
    var signalled = false
    // Each identity is checked right before its own signal: a process can exit and its PID be
    // reused while the earlier signals go out.
    for session in sessions where owns(session.runner) {
      try terminate(session.runner.pid)
      signalled = true
    }
    awaitExit(sessions.map(\.runner))
    // A panel quits by itself once its runner exits; only one that does not is signalled.
    awaitExit(sessions.map(\.panel))
    var orphans: [SaverProcess] = []
    for session in sessions where !owns(session.runner) && owns(session.panel) {
      try terminate(session.panel.pid)
      orphans.append(session.panel)
    }
    awaitExit(orphans)
    var stuck: [String] = []
    for entry in entries {
      if let session = entry.record, owns(session.runner) || owns(session.panel) {
        stuck.append(session.display.label)
      } else {
        try records.remove(entry.name)
      }
    }
    guard stuck.isEmpty else {
      throw SaverError(
        "The screensaver on \(stuck.joined(separator: ", ")) did not exit after SIGTERM;"
          + " its record is kept so `macarchy saver stop` can retry.")
    }
    return signalled || !orphans.isEmpty
  }

  private func awaitExit(_ processes: [SaverProcess]) {
    var polls = 0
    while polls < Self.exitPolls, processes.contains(where: owns) {
      pause()
      polls += 1
    }
  }

  private func owns(_ process: SaverProcess) -> Bool {
    observe(process.pid) == process
  }
}

extension Saver {
  static func live(stateRoot: URL) -> Self {
    let runtime = RuntimeEnvironment.live
    return Self(
      stateRoot: stateRoot,
      engine: .locate(executable: runtime.executableURL),
      kitty: .inspect(),
      command: runtime.persistentCommandURL,
      palette: {
        SaverPalette(
          theme: try loadPopupTheme(
            stateRoot: stateRoot, bundledThemesRoot: runtime.builtInThemesURL))
      },
      text: { SaverText.choose(SaverText.read(SaverText.fileURL(stateRoot: stateRoot))) },
      coverage: { SaverHost.coverage(processRunner: .live) },
      launch: { arguments in
        let result = try ProcessRunner.live.run(
          ProcessRequest(executableURL: SaverHost.opener, arguments: arguments, timeout: 15))
        guard result.terminationStatus == 0 else {
          throw SaverError("open exited with status \(result.terminationStatus): \(result.output)")
        }
      },
      observe: SaverProcess.observe,
      terminate: terminateSaverProcess,
      pause: { Thread.sleep(forTimeInterval: Self.pauseInterval) },
      now: Date.init)
  }
}
