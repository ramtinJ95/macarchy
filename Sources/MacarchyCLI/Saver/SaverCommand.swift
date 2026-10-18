import ArgumentParser
import Foundation

struct SaverCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "saver",
    abstract: "Show animated text fullscreen in Kitty as a decorative screensaver.",
    discussion: """
      The saver runs the ttfx engine that Macarchy's release installs in libexec/. It is
      decorative, not a lock: native screensaver, lock, password and sleep settings stay
      untouched.
      """,
    subcommands: [Status.self, Run.self])

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show whether the engine and Kitty are present and the saver is running.")

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let status = SaverStatus.inspect(executable: RuntimeEnvironment.live.executableURL)
      print(try json ? status.renderJSON() : status.message)
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
}
