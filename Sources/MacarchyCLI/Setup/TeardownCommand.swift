import ArgumentParser
import Foundation
import ThemeCore

extension Macarchy {
  struct Teardown: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Reverse only integrations recorded as Macarchy-owned."
    )

    @Flag(help: "Describe teardown without making changes.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try TeardownCommandRunner.live.execute(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        dryRun: dryRun,
        json: json
      )
      try emitExecution(execution)
    }
  }
}
