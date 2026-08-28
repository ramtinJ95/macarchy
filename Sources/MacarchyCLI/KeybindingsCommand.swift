import ArgumentParser
import Foundation
import ThemeCore

struct Keybindings: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect configured skhd keybindings.",
    subcommands: [List.self, Doctor.self, Show.self]
  )

  struct SourceOptions: ParsableArguments {
    @Option(help: "skhd configuration file.")
    var skhdConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/skhd/skhdrc").path

    @Option(help: "Keybinding metadata catalog.")
    var catalog = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy/keybindings.toml").path

    var skhdConfigurationURL: URL {
      URL(filePath: skhdConfig).standardizedFileURL
    }

    var catalogURL: URL {
      URL(filePath: catalog).standardizedFileURL
    }
  }

  struct Options: ParsableArguments {
    @OptionGroup var sources: SourceOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    var skhdConfigurationURL: URL { sources.skhdConfigurationURL }
    var catalogURL: URL { sources.catalogURL }
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List enabled bindings from the skhd configuration."
    )

    @OptionGroup var options: Options

    mutating func run() throws {
      let execution = try KeybindingsListCommandRunner.live.execute(
        configurationURL: options.skhdConfigurationURL,
        catalogURL: options.catalogURL,
        json: options.json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose skhd parsing and keybinding catalog coverage."
    )

    @OptionGroup var options: Options

    mutating func run() throws {
      let execution = try KeybindingsDoctorCommandRunner.live.execute(
        configurationURL: options.skhdConfigurationURL,
        catalogURL: options.catalogURL,
        json: options.json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show enabled bindings in a searchable native popup."
    )

    @OptionGroup var sources: SourceOptions

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    mutating func run() async throws {
      let content = try KeybindingsShowCommandLoader.live.load(
        configurationURL: sources.skhdConfigurationURL,
        catalogURL: sources.catalogURL,
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
      )
      try await MainActor.run {
        let controller = try KeybindingsPopupWindowController(content: content)
        try controller.run()
      }
    }
  }
}
