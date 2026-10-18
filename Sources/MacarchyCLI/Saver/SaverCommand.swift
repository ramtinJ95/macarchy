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
    subcommands: [Status.self])

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
}
