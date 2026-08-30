import ArgumentParser
import Foundation
import ThemeCore

struct Keybindings: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect configured skhd keybindings.",
    subcommands: [Plan.self, Apply.self, List.self, Doctor.self, Show.self]
  )

  struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Plan effective managed skhd keybindings without making changes."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL =
        profile.map { URL(filePath: $0).standardizedFileURL }
        ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
      let execution = try KeybindingsPlanCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInKeybindingsURL,
        profileURL: profileURL,
        profileRequired: profile != nil,
        stateRoot: URL(
          filePath: stateRoot,
          directoryHint: .isDirectory
        ).standardizedFileURL,
        homeDirectory: home,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Publish and activate managed skhd keybindings."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Inspect without publishing or activating keybindings.")
    var dryRun = false

    @Option(help: "Exact adoption evidence digest from the reviewed keybindings plan.")
    var adopt: String?

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL =
        profile.map { URL(filePath: $0).standardizedFileURL }
        ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
      let stateRootURL = URL(
        filePath: stateRoot,
        directoryHint: .isDirectory
      ).standardizedFileURL
      let execution =
        if dryRun {
          try KeybindingsApplyCommandRunner.live.preview(
            resourcesRoot: RuntimeEnvironment.live.builtInKeybindingsURL,
            profileURL: profileURL,
            profileRequired: profile != nil,
            stateRoot: stateRootURL,
            homeDirectory: home,
            adopt: adopt,
            json: json
          )
        } else {
          try KeybindingsApplyCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInKeybindingsURL,
            profileURL: profileURL,
            profileRequired: profile != nil,
            stateRoot: stateRootURL,
            homeDirectory: home,
            adopt: adopt,
            json: json
          )
        }
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

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
