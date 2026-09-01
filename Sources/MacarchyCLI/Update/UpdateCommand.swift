import ArgumentParser
import Foundation
import ThemeCore

struct Update: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect or install stable Macarchy updates.",
    usage: "macarchy update [<subcommand>]",
    subcommands: [Status.self, Check.self]
  )

  mutating func run() throws {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory)
    let execution = try StateFileLock(root: root, identity: .homebrewUpdate).withLock {
      try HomebrewUpdateRunner.live.execute(stateRoot: root)
    }
    print(execution.output)
    if !execution.succeeded {
      throw ExitCode.failure
    }
  }

  struct Options: ParsableArguments {
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Emit machine-readable output.")
    var json = false

    var stateRootURL: URL {
      URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show installed, upstream, and locally known tap versions."
    )

    @OptionGroup var options: Options

    mutating func run() throws {
      let execution = try UpdateCommandRunner.live.execute(
        stateRoot: options.stateRootURL,
        refresh: false,
        json: options.json
      )
      print(execution.output)
    }
  }

  struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Refresh the stable GitHub release check."
    )

    @OptionGroup var options: Options

    mutating func run() throws {
      let execution = try UpdateCommandRunner.live.execute(
        stateRoot: options.stateRootURL,
        refresh: true,
        json: options.json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }
}
