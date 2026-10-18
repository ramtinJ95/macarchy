import ArgumentParser
import Foundation

struct SaverCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "saver",
    abstract: "Show animated text fullscreen in Kitty as a decorative screensaver.",
    discussion: """
      The saver plays random ttfx effects in a Kitty panel on every display until any key press
      or mouse movement. It runs the ttfx engine that Macarchy's release installs in libexec/.
      It is decorative, not a lock: native screensaver, lock, password and sleep settings stay
      untouched. Put your own text in screensaver.txt in the state directory. `saver idle on`
      also starts it after a period without input.
      """,
    subcommands: [
      Start.self, Stop.self, Status.self, Idle.self, Pause.self, Resume.self, TogglePause.self,
      Run.self, Observe.self,
    ])

  static let defaultStateRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

  struct Options: ParsableArguments {
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = SaverCommand.defaultStateRoot

    @Flag(help: .hidden)
    var alertOnError = false

    var stateRootURL: URL {
      URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
    }

    /// Prints the outcome of `body`, which gets the state root. Menu and bar launches have no
    /// terminal, so they also show failures in an alert.
    @MainActor
    func run(_ failureTitle: String, _ body: (URL) throws -> String) throws {
      do {
        print(try body(stateRootURL))
      } catch {
        if alertOnError {
          showNativeAlert(title: failureTitle, message: String(describing: error))
        }
        throw error
      }
    }
  }

  struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Start the screensaver on every display; it ends on any key or mouse movement.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      let textFile = SaverText.fileURL(stateRoot: options.stateRootURL)
      try options.run("Screensaver not started") {
        try Saver.live(stateRoot: $0).start().message(textFile: textFile)
      }
    }
  }

  struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Stop Macarchy's screensaver on every display.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Screensaver not stopped") { try Saver.live(stateRoot: $0).stop().message }
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the engine, Kitty, the text, where the screensaver runs and idle activation.")

    @OptionGroup var options: Options

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let root = options.stateRootURL
      let report = SaverReport(
        saver: try Saver.live(stateRoot: root).status(),
        idle: try SaverIdle.live(stateRoot: root).status())
      print(try json ? report.renderJSON() : report.message)
    }
  }

  struct Idle: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Start the screensaver after a period without input.",
      discussion: """
        A Macarchy launch agent in your login session starts the screensaver once you have been
        idle for the timeout, 5 minutes unless --after says otherwise. Pause, keep-awake, a locked
        screen, the macOS screensaver and display sleep hold it off. Macarchy never changes macOS
        screensaver, lock, password or sleep settings; on and status warn when one of their
        timers comes first. Off removes the launch agent and its record.
        """,
      subcommands: [On.self, Off.self])

    struct On: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Turn idle activation on, or change its timeout while it is on.")

      @Option(
        name: .customLong("after"),
        help: "Start after 1m to 4h without input, such as 5m, 30m or 1h30m.",
        transform: { try SaverIdle.timeout.parse($0) })
      var timeout: Duration?

      @OptionGroup var options: Options

      @MainActor
      mutating func run() async throws {
        let timeout = timeout
        try options.run("Idle screensaver not turned on") { root in
          let idle = SaverIdle.live(stateRoot: root)
          let change = try idle.turnOn(after: timeout)
          let warnings = change.record.map { idle.nativeTimers().warnings(timeout: $0.timeout) }
          return ([change.message] + (warnings ?? [])).joined(separator: "\n")
        }
      }
    }

    struct Off: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Turn idle activation off and remove its launch agent and record.")

      @OptionGroup var options: Options

      @MainActor
      mutating func run() async throws {
        try options.run("Idle screensaver not turned off") {
          try SaverIdle.live(stateRoot: $0).turnOff().message
        }
      }
    }
  }

  struct Pause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Hold off idle starts until you resume them.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Idle screensaver not paused") {
        try SaverIdle.live(stateRoot: $0).apply(.pause).message
      }
    }
  }

  struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume paused idle starts.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Idle screensaver not resumed") {
        try SaverIdle.live(stateRoot: $0).apply(.resume).message
      }
    }
  }

  struct TogglePause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Resume idle starts when paused, otherwise pause them.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Idle screensaver pause not changed") {
        try SaverIdle.live(stateRoot: $0).apply(.toggle).message
      }
    }
  }

  /// The program inside each panel. Its failures can only be read on the panel itself.
  struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_run", shouldDisplay: false)

    @Option var stateRoot: String
    @Option var launch: String
    @Option var display: String?

    mutating func run() throws {
      let runner: SaverRunner
      do {
        runner = try SaverRunner.live(
          stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
          display: SaverDisplay(outputName: display), launch: launch)
      } catch {
        print("Macarchy screensaver cannot start: \(error)")
        Thread.sleep(forTimeInterval: 5)
        throw ExitCode.failure
      }
      let status = runner.run()
      guard status == 0 else { throw ExitCode(status) }
    }
  }

  /// The idle launch agent's observer. It exits once idle activation is turned off.
  struct Observe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_idle", shouldDisplay: false)

    @Option var stateRoot: String

    /// Shows the alert for this start failure instead of observing. The observer starts itself
    /// this way, so its polls never wait on an alert.
    @Option(help: .hidden) var alert: String?

    @MainActor
    mutating func run() async throws {
      if let alert {
        showNativeAlert(
          title: "Idle screensaver did not start",
          message: (alert.hasSuffix(".") ? alert : alert + ".")
            + " Run `macarchy saver status` for details.")
        return
      }
      let root = stateRoot
      SaverIdleObserver.run(
        .live(
          stateRoot: URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL,
          alert: { failure in
            let process = Process()
            process.executableURL = RuntimeEnvironment.live.executableURL
            process.arguments = ["saver", "_idle", "--state-root", root, "--alert=\(failure)"]
            do {
              try process.run()
            } catch {
              let line = "Could not show the alert for this failure: \(error)\n"
              try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
            }
          }))
    }
  }
}
