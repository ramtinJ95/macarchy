import ArgumentParser
import Foundation

struct MicrophoneCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mic",
    abstract: "Choose the default microphone and mute it.",
    discussion: """
      Mute uses the microphone's own hardware mute when it has one. Otherwise Macarchy sets its
      input level to zero and restores it on unmute: silenced by input level, not a hardware
      mute. Both act on the system default input only. Apps that choose their own input are not
      affected, so neither is a privacy guarantee.
      """,
    subcommands: [
      List.self, Select.self, Mute.self, Unmute.self, Toggle.self, Status.self, Choose.self,
    ])

  static let defaultStateRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

  struct Options: ParsableArguments {
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = MicrophoneCommand.defaultStateRoot

    @Flag(help: .hidden)
    var alertOnError = false

    var engine: Microphone {
      Microphone.live(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL)
    }

    /// Prints the outcome. Menu launches have no terminal, so they also show failures in an alert.
    @MainActor
    func run(_ failureTitle: String, _ body: (Microphone) throws -> String?) throws {
      do {
        if let message = try body(engine) { print(message) }
      } catch {
        if alertOnError {
          showNativeAlert(title: failureTitle, message: String(describing: error))
        }
        throw error
      }
    }
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List microphones, marking the default with *, and how each can be muted.")

    @Flag(help: "Emit machine-readable output.")
    var json = false

    @OptionGroup var options: Options

    mutating func run() throws {
      let inputs = try options.engine.inputs()
      print(try json ? MicrophoneInput.renderJSON(inputs) : MicrophoneInput.render(inputs))
    }
  }

  struct Select: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Make a microphone the system default input.")

    @Argument(help: "The exact microphone name, or its identity from `mic list --json`.")
    var input: String

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      let input = input
      try options.run("Microphone not selected") { engine in
        let device = try engine.select(input)
        return "Default microphone: \"\(device.name)\"."
      }
    }
  }

  struct Mute: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mute the default microphone.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Microphone not muted") { try $0.apply(.mute).message }
    }
  }

  struct Unmute: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Unmute the default microphone, restoring a level Macarchy silenced.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Microphone not unmuted") { try $0.apply(.unmute).message }
    }
  }

  struct Toggle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Unmute the default microphone when muted, otherwise mute it.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Microphone mute not changed") { try $0.apply(.toggle).message }
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the default microphone and whether it is muted.")

    @Flag(help: "Emit machine-readable output.")
    var json = false

    @OptionGroup var options: Options

    mutating func run() throws {
      let status = try options.engine.status()
      print(try json ? status.renderJSON() : status.message)
    }
  }

  struct Choose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Choose the default microphone in a native dialog.", shouldDisplay: false)

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Microphone not selected") { engine in
        let device = try engine.choose { names, selected in
          showNativeChoice(
            title: "Choose microphone", message: Microphone.appsNote, choices: names,
            selected: selected)?.choice
        }
        return device.map { "Default microphone: \"\($0.name)\"." }
      }
    }
  }
}
