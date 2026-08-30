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

  struct InspectionOptions: ParsableArguments {
    @Flag(help: "Inspect desired managed keybindings and canonical generated state.")
    var effective = false

    @Option(help: "skhd configuration file for source-based inspection.")
    var skhdConfig: String?

    @Option(help: "Keybinding metadata catalog for source-based inspection.")
    var catalog: String?

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot: String?

    var profileRequired: Bool { profile != nil }

    func validate() throws {
      if effective, skhdConfig != nil || catalog != nil {
        throw ValidationError("--skhd-config and --catalog cannot be used with --effective")
      }
      if !effective, profile != nil {
        throw ValidationError("--profile requires --effective")
      }
    }

    func profileURL(homeDirectory: URL) -> URL {
      profile.map { URL(filePath: $0).standardizedFileURL }
        ?? homeDirectory.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
    }

    func stateRootURL(homeDirectory: URL) -> URL {
      stateRoot.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
        ?? homeDirectory.appending(path: ".config/macarchy", directoryHint: .isDirectory)
        .standardizedFileURL
    }

    func skhdConfigurationURL(homeDirectory: URL) -> URL {
      skhdConfig.map { URL(filePath: $0).standardizedFileURL }
        ?? homeDirectory.appending(path: ".config/skhd/skhdrc").standardizedFileURL
    }

    func catalogURL(homeDirectory: URL) -> URL {
      catalog.map { URL(filePath: $0).standardizedFileURL }
        ?? homeDirectory.appending(path: ".config/macarchy/keybindings.toml").standardizedFileURL
    }

    func inspect(homeDirectory: URL) -> KeybindingEffectiveState {
      KeybindingEffectiveStateInspector().inspect(
        resourcesRoot: RuntimeEnvironment.live.builtInKeybindingsURL,
        profileURL: profileURL(homeDirectory: homeDirectory),
        profileRequired: profileRequired,
        stateRoot: stateRootURL(homeDirectory: homeDirectory)
      )
    }
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List configured skhd bindings or explicitly inspect desired managed state."
    )

    @OptionGroup var inspection: InspectionOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func validate() throws {
      try inspection.validate()
    }

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution =
        if inspection.effective {
          try KeybindingsListCommandRunner.live.execute(
            effectiveState: inspection.inspect(homeDirectory: home),
            json: json
          )
        } else {
          try KeybindingsListCommandRunner.live.execute(
            configurationURL: inspection.skhdConfigurationURL(homeDirectory: home),
            catalogURL: inspection.catalogURL(homeDirectory: home),
            json: json
          )
        }
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose configured skhd sources or explicitly inspect desired managed state."
    )

    @OptionGroup var inspection: InspectionOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func validate() throws {
      try inspection.validate()
    }

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution =
        if inspection.effective {
          try KeybindingsDoctorCommandRunner.live.execute(
            effectiveState: inspection.inspect(homeDirectory: home),
            stateRoot: inspection.stateRootURL(homeDirectory: home),
            json: json
          )
        } else {
          try KeybindingsDoctorCommandRunner.live.execute(
            configurationURL: inspection.skhdConfigurationURL(homeDirectory: home),
            catalogURL: inspection.catalogURL(homeDirectory: home),
            json: json
          )
        }
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show configured skhd bindings or desired managed bindings in a native popup."
    )

    @OptionGroup var inspection: InspectionOptions

    mutating func validate() throws {
      try inspection.validate()
    }

    mutating func run() async throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let stateRoot = inspection.stateRootURL(homeDirectory: home)
      let content =
        if inspection.effective {
          try KeybindingsShowCommandLoader.live.load(
            effectiveState: inspection.inspect(homeDirectory: home),
            stateRoot: stateRoot
          )
        } else {
          try KeybindingsShowCommandLoader.live.load(
            configurationURL: inspection.skhdConfigurationURL(homeDirectory: home),
            catalogURL: inspection.catalogURL(homeDirectory: home),
            stateRoot: stateRoot
          )
        }
      try await MainActor.run {
        let controller = try KeybindingsPopupWindowController(content: content)
        try controller.run()
      }
    }
  }
}
