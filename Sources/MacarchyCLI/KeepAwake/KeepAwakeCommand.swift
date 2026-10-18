import ArgumentParser
import Foundation

struct KeepAwakeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "keep-awake",
    abstract: "Keep the display awake until turned off, or for a bounded time.",
    discussion: """
      Macarchy runs and owns one Apple caffeinate -d -i process. While it runs, the idle
      screensaver and idle lock do not start; manual lock, sleep and closing the lid still work.
      The session ends at logout and is not restarted at login. Other apps' keep-awake sessions
      are never stopped.
      """,
    subcommands: [On.self, Off.self, Toggle.self, Status.self])

  static let defaultStateRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

  struct Options: ParsableArguments {
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = KeepAwakeCommand.defaultStateRoot

    @Flag(help: .hidden)
    var alertOnError = false

    @MainActor
    func apply(_ request: KeepAwakeRequest) throws {
      do {
        let engine = KeepAwake.live(stateRoot: stateRootURL(stateRoot))
        print(try engine.apply(request).message)
      } catch {
        if alertOnError {
          showNativeAlert(title: "Keep-awake not changed", message: String(describing: error))
        }
        throw error
      }
    }
  }

  struct On: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Turn keep-awake on. A bounded session is replaced by the new request.")

    @Option(
      name: .customLong("for"),
      help: "Turn off automatically after 1m to 24h, such as 30m, 2h or 1h30m.",
      transform: { try KeepAwake.parseDuration($0) })
    var duration: Duration?

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.apply(.on(duration))
    }
  }

  struct Off: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Turn Macarchy's keep-awake off.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.apply(.off)
    }
  }

  struct Toggle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Turn keep-awake off when on, otherwise on until turned off.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.apply(.toggle)
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether keep-awake is on.")

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = KeepAwakeCommand.defaultStateRoot

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let status = try KeepAwake.live(stateRoot: stateRootURL(stateRoot)).status()
      print(try json ? status.renderJSON() : status.message)
    }
  }
}

private func stateRootURL(_ path: String) -> URL {
  URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
}
