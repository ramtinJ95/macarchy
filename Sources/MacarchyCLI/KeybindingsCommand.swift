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

  struct EffectiveOptions: ParsableArguments {
    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    var profileRequired: Bool { profile != nil }

    func profileURL(homeDirectory: URL) -> URL {
      profile.map { URL(filePath: $0).standardizedFileURL }
        ?? homeDirectory.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
    }

    var stateRootURL: URL {
      URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
    }

    func inspect(homeDirectory: URL) -> KeybindingEffectiveState {
      KeybindingEffectiveStateInspector().inspect(
        resourcesRoot: RuntimeEnvironment.live.builtInKeybindingsURL,
        profileURL: profileURL(homeDirectory: homeDirectory),
        profileRequired: profileRequired,
        stateRoot: stateRootURL
      )
    }
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List effective managed skhd bindings and their sources."
    )

    @OptionGroup var effective: EffectiveOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution = try KeybindingsListCommandRunner.live.execute(
        effectiveState: effective.inspect(homeDirectory: home),
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose effective managed skhd inputs and generated state."
    )

    @OptionGroup var effective: EffectiveOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution = try KeybindingsDoctorCommandRunner.live.execute(
        effectiveState: effective.inspect(homeDirectory: home),
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show effective managed bindings in a searchable native popup."
    )

    @OptionGroup var effective: EffectiveOptions

    mutating func run() async throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let content = try KeybindingsShowCommandLoader.live.load(
        effectiveState: effective.inspect(homeDirectory: home),
        stateRoot: effective.stateRootURL
      )
      try await MainActor.run {
        let controller = try KeybindingsPopupWindowController(content: content)
        try controller.run()
      }
    }
  }
}
