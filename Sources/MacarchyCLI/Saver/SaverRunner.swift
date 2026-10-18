import Darwin
import Dispatch
import Foundation
import Synchronization
import ThemeCore

/// The active theme colors the panels and the animation use.
struct SaverPalette: Equatable, Sendable {
  let background: String
  let foreground: String
  /// ttfx's final gradient, which every curated effect accepts.
  let accents: [String]

  init(background: String, foreground: String, accents: [String]) {
    self.background = background
    self.foreground = foreground
    self.accents = accents
  }

  init(theme: NormalizedTheme) {
    background = theme.terminal.background.rawValue
    foreground = theme.terminal.foreground.rawValue
    accents = [theme.semantic.accent, theme.semantic.info, theme.semantic.text].map(\.rawValue)
  }
}

/// What the runner waits for while ttfx plays.
enum SaverRunnerEvent: Equatable, Sendable {
  /// A key press or mouse report on the panel's terminal.
  case input
  /// SIGTERM or SIGHUP arrived, or the panel's terminal closed.
  case terminate
  /// ttfx exited with this status; 128 + n when signal n ended it.
  case engineExited(Int32)
  /// The wait's bound passed.
  case timeout
}

/// The panel terminal the runner owns while it plays.
struct SaverTerminal {
  /// Raw input, a hidden cursor and mouse reporting.
  let prepare: () throws -> Void
  let restore: () -> Void
  let show: (String) -> Void
}

/// The ttfx processes the runner starts and stops.
struct SaverEngineProcesses {
  /// Starts ttfx with `arguments` and `input` on its standard input, returning its PID.
  let start: (_ arguments: [String], _ input: String) throws -> Int32
  /// Ends and reaps a ttfx that `start` returned.
  let stop: (Int32) -> Void
}

/// `macarchy saver _run`, inside one display's panel: plays random ttfx effects until any input,
/// then ends the whole session on every display.
struct SaverRunner {
  /// Every ttfx effect except matrix and thunderstorm, whose fixed-length rain phases fill the
  /// whole fullscreen canvas, and synthgrid, which draws a grid across it and is the only effect
  /// without the final gradient that carries the theme's accents.
  static let effects = [
    "beams", "binarypath", "blackhole", "bouncyballs", "bubbles", "burn", "colorshift", "crumble",
    "decrypt", "errorcorrect", "expand", "fireworks", "highlight", "laseretch", "middleout",
    "orbittingvolley", "overflow", "pour", "print", "rain", "randomsequence", "rings", "scattered",
    "slice", "slide", "smoke", "spotlights", "spray", "swarm", "sweep", "unstable", "vhstape",
    "waves", "wipe",
  ]
  static let frameRate = 30
  /// Input this soon after the panel appears comes from its arrival, not from the user.
  static let settle: TimeInterval = 1
  static let failureDisplay: Duration = .seconds(5)

  let identity: SaverRunnerRecord
  let records: SaverRecords
  let palette: SaverPalette
  let text: String
  let terminal: SaverTerminal
  let processes: SaverEngineProcesses
  let next: (_ engine: Int32?, _ timeout: Duration?) -> SaverRunnerEvent
  let observe: (Int32) -> SaverProcess?
  let terminate: (Int32) throws -> Void
  /// A random index below its argument.
  let random: (Int) -> Int
  let now: () -> Date

  /// ttfx's terminal options come before the effect, and the theme's accents after it.
  static func arguments(effect: String, palette: SaverPalette) -> [String] {
    [
      "--frame-rate", String(frameRate), "--canvas-width", "0", "--canvas-height", "0",
      "--anchor-canvas", "c", "--anchor-text", "c", "--reuse-canvas", "--no-eol",
      "--no-restore-cursor", "--terminal-background-color", palette.background, effect,
      "--final-gradient-stops",
    ] + palette.accents
  }

  /// The process exit status: 0 when input or a signal ended the session.
  func run() -> Int32 {
    do {
      guard try records.register(identity) else {
        terminal.show(
          "Macarchy screensaver did not start: this panel is not part of a start in progress.")
        return 1
      }
    } catch {
      terminal.show("Macarchy screensaver cannot start: \(error)")
      _ = next(nil, Self.failureDisplay)
      return 1
    }
    var failure: String?
    do {
      try terminal.prepare()
      failure = play()
    } catch {
      failure = "cannot prepare the terminal: \(error)"
    }
    if let failure {
      terminal.show("Macarchy screensaver stopped: \(failure)")
      _ = next(nil, Self.failureDisplay)
    }
    terminal.restore()
    stopSiblings()
    // A record left behind names a process that has exited, which start, stop and status
    // already treat as stale.
    try? records.unregister(identity)
    return failure == nil ? 0 : 1
  }

  /// nil once input or a signal ends the session, or why ttfx failed.
  private func play() -> String? {
    let began = now()
    var previous: String?
    while true {
      let choices = Self.effects.filter { $0 != previous }
      let effect = choices[random(choices.count)]
      let pid: Int32
      do {
        pid = try processes.start(Self.arguments(effect: effect, palette: palette), text)
      } catch {
        return "cannot start ttfx: \(error)"
      }
      waiting: while true {
        switch next(pid, nil) {
        case .input where now().timeIntervalSince(began) < Self.settle:
          continue waiting
        case .timeout:
          continue waiting
        case .input, .terminate:
          processes.stop(pid)
          return nil
        case .engineExited(0):
          break waiting
        case .engineExited(let status):
          return "ttfx \(effect) exited with status \(status)"
        }
      }
      previous = effect
    }
  }

  /// Ends the other displays' runners. Nobody can read an error from a closing panel, and a
  /// runner left running still ends on its own input or `macarchy saver stop`.
  private func stopSiblings() {
    guard let entries = try? records.entries() else { return }
    for sibling in entries.compactMap(\.record)
    where sibling.display != identity.display && observe(sibling.runner.pid) == sibling.runner {
      try? terminate(sibling.runner.pid)
    }
  }
}

extension SaverRunner {
  /// The runner for this process, which must be the child of a saver panel's Kitty that `launch`
  /// opened.
  static func live(stateRoot: URL, display: SaverDisplay, launch: String) throws -> Self {
    guard let runner = SaverProcess.observe(getpid()),
      let panel = SaverProcess.observe(getppid())
    else { throw SaverError("cannot establish the identity of this runner and its panel") }
    guard panel.executablePath == SaverKitty.executable else {
      throw SaverError(
        "it runs only inside a panel that `macarchy saver start` opens, not under "
          + panel.executablePath)
    }
    let runtime = RuntimeEnvironment.live
    let engine = SaverEngine.locate(executable: runtime.executableURL)
    if let defect = engine.defect {
      throw SaverError("the ttfx engine at \(engine.url.path) is \(defect.summary)")
    }
    let theme = try loadPopupTheme(
      stateRoot: stateRoot, bundledThemesRoot: runtime.builtInThemesURL)
    let terminal = SaverPanelTerminal()
    let events = SaverPanelEvents()
    return Self(
      identity: SaverRunnerRecord(
        output: display.outputName, launch: launch, runner: runner, panel: panel),
      records: SaverRecords(stateRoot: stateRoot),
      palette: SaverPalette(theme: theme),
      text: SaverText.choose(SaverText.read(SaverText.fileURL(stateRoot: stateRoot))).content,
      terminal: SaverTerminal(
        prepare: terminal.prepare, restore: terminal.restore, show: terminal.show),
      processes: SaverEngineProcesses(
        start: { try SaverEngineProcess.start(engine.url, arguments: $0, input: $1) },
        stop: SaverEngineProcess.stop),
      next: { events.next(engine: $0, timeout: $1) },
      observe: SaverProcess.observe,
      terminate: terminateSaverProcess,
      random: { Int.random(in: 0..<$0) },
      now: { Date() })
  }
}

/// The panel's terminal on standard input and output.
final class SaverPanelTerminal {
  private var saved: termios?

  func prepare() throws {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw SaverError("cannot read the terminal mode (errno \(errno))")
    }
    var raw = original
    cfmakeraw(&raw)
    // ttfx draws its frames through the terminal's normal output processing.
    raw.c_oflag = original.c_oflag
    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
      throw SaverError("cannot set the terminal mode (errno \(errno))")
    }
    saved = original
    Self.write("\u{1B}[?25l\u{1B}[2J\u{1B}[H\u{1B}[?1003h\u{1B}[?1006h")
  }

  func restore() {
    Self.write("\u{1B}[?1006l\u{1B}[?1003l\u{1B}[0m\u{1B}[?25h")
    guard var original = saved else { return }
    tcsetattr(STDIN_FILENO, TCSANOW, &original)
    saved = nil
  }

  func show(_ message: String) {
    Self.write("\u{1B}[0m\r\n\(message)\r\n")
  }

  /// A panel that is closing has no terminal left; its write errors are not reportable.
  private static func write(_ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes {
        Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count)
      }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        return
      }
    }
  }
}

/// The panel's input, its termination signals and ttfx's exit, polled together.
final class SaverPanelEvents {
  private final class Flag: Sendable {
    let raised = Mutex(false)
  }

  private let terminated = Flag()
  private var sources: [any DispatchSourceSignal] = []

  init() {
    // A ttfx that exits early must not end the runner with SIGPIPE while it receives the text.
    signal(SIGPIPE, SIG_IGN)
    let flag = self.terminated
    for number in [SIGTERM, SIGHUP] {
      // Ignored here, the signal still reaches the source, so cleanup runs instead of an exit.
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { flag.raised.withLock { $0 = true } }
      source.resume()
      sources.append(source)
    }
  }

  func next(engine: Int32?, timeout: Duration?) -> SaverRunnerEvent {
    let clock = ContinuousClock()
    let deadline = timeout.map { clock.now.advanced(by: $0) }
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      if terminated.raised.withLock({ $0 }) { return .terminate }
      if let engine, let status = SaverEngineProcess.reap(engine) {
        return .engineExited(status)
      }
      if let deadline, clock.now >= deadline { return .timeout }
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, 100)
      if ready == 0 || (ready < 0 && errno == EINTR) { continue }
      guard ready > 0 else { return .terminate }
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
      }
      if count > 0 { return .input }
      if count < 0, errno == EINTR || errno == EAGAIN { continue }
      // End of file or a read error: the panel's terminal is gone.
      return .terminate
    }
  }
}

/// ttfx children of the runner. A child stays unreaped until `reap` succeeds, so its PID cannot
/// be reused while the runner signals it.
enum SaverEngineProcess {
  static func start(_ engine: URL, arguments: [String], input: String) throws -> Int32 {
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
      throw SaverError("cannot create a pipe for ttfx (errno \(errno))")
    }
    let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
    defer { Darwin.close(writeEnd) }
    let pid: Int32
    do {
      // Closed before the write below: with this end open, writing to a ttfx that exited early
      // would block instead of failing.
      defer { Darwin.close(readEnd) }
      pid = try spawn(engine, arguments: arguments, input: readEnd)
    }
    // ttfx reads all of its input before its first frame. A write error means it already
    // exited, which the event loop reports with its status.
    let bytes = Array(input.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes {
        Darwin.write(writeEnd, $0.baseAddress, $0.count)
      }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        break
      }
    }
    return pid
  }

  private static func spawn(_ engine: URL, arguments: [String], input: Int32) throws -> Int32 {
    func require(_ code: Int32) throws {
      guard code == 0 else { throw SaverError("cannot prepare ttfx (errno \(code))") }
    }
    var attributes: posix_spawnattr_t?
    try require(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    // The runner ignores these signals; ttfx gets the default dispositions back.
    var defaults = sigset_t(0)
    for number in [SIGTERM, SIGHUP, SIGINT, SIGPIPE] {
      defaults |= sigset_t(1) << sigset_t(number - 1)
    }
    var unblocked = sigset_t(0)
    try require(posix_spawnattr_setsigdefault(&attributes, &defaults))
    try require(posix_spawnattr_setsigmask(&attributes, &unblocked))
    try require(
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)))
    var actions: posix_spawn_file_actions_t?
    try require(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try require(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
    try require(posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO))
    try require(posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO))
    let argv = [engine.path] + arguments
    let storage = argv.compactMap { strdup($0) }
    defer {
      for pointer in storage { free(pointer) }
    }
    guard storage.count == argv.count else { throw SaverError("cannot allocate ttfx arguments") }
    var pointers: [UnsafeMutablePointer<CChar>?] = storage.map { $0 } + [nil]
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, engine.path, &actions, &attributes, &pointers, environ)
    guard spawned == 0 else { throw SaverError("cannot start ttfx (errno \(spawned))") }
    return pid
  }

  /// SIGTERM, then SIGKILL after about a second, and reap.
  static func stop(_ pid: Int32) {
    _ = kill(pid, SIGTERM)
    for _ in 0..<20 {
      if reap(pid) != nil { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    _ = kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
  }

  /// The exit status once ttfx has exited and is reaped; 128 + n when signal n ended it.
  static func reap(_ pid: Int32) -> Int32? {
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    if result == -1, errno != EINTR {
      return 255
    }
    guard result == pid else { return nil }
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
  }
}
