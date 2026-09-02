import ArgumentParser
import Foundation

struct Desktop: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Plan and manage the default desktop providers.",
    subcommands: [
      Plan.self, Apply.self, Status.self, Doctor.self, Teardown.self, RunSketchyBarHook.self,
    ]
  )

  struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Plan managed desktop provider configuration without making changes."
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
      let execution = try DesktopPlanCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
        profileURL: profileURL,
        profileRequired: profile != nil,
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        homeDirectory: home,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Publish, activate, and verify managed desktop providers."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @OptionGroup var state: Macarchy.StateOptions

    @Option(help: "Exact yabai adoption evidence digest from the reviewed desktop plan.")
    var adopt: String?

    @Option(help: "Exact skhd adoption evidence digest from the reviewed desktop plan.")
    var keybindingsAdopt: String?

    @Option(help: "Exact SketchyBar adoption evidence digest from the reviewed desktop plan.")
    var sketchybarAdopt: String?

    @Flag(help: "Inspect the aggregate desktop outcome without mutation.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL =
        profile.map { URL(filePath: $0).standardizedFileURL }
        ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
      let execution =
        if dryRun {
          try DesktopPlanCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
            profileURL: profileURL,
            profileRequired: profile != nil,
            stateRoot: state.stateRootURL,
            homeDirectory: home,
            json: json
          )
        } else {
          try await DesktopApplyCommandRunner.live.executeAggregate(
            resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
            profileURL: profileURL,
            profileRequired: profile != nil,
            stateRoot: state.stateRootURL,
            homeDirectory: home,
            consumerPaths: state.consumerPaths,
            adopt: adopt,
            keybindingsAdopt: keybindingsAdopt,
            sketchyBarAdopt: sketchybarAdopt,
            json: json
          )
        }
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Report managed desktop generation, ownership, and runtime state."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL =
        profile.map { URL(filePath: $0).standardizedFileURL }
        ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
      let execution = try DesktopStatusCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
        profileURL: profileURL,
        profileRequired: profile != nil,
        stateRoot: state.stateRootURL,
        homeDirectory: home,
        json: json,
        consumerPaths: state.consumerPaths
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct Teardown: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Restore the exact desktop provider entries adopted by Macarchy."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Preview restoration without mutation.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try DesktopTeardownCommandRunner.live.executeAggregate(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        dryRun: dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose aggregate desktop prerequisites, providers, runtime, and theme state."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL =
        profile.map { URL(filePath: $0).standardizedFileURL }
        ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
      let execution = try DesktopDoctorCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
        profileURL: profileURL,
        profileRequired: profile != nil,
        stateRoot: state.stateRootURL,
        homeDirectory: home,
        consumerPaths: state.consumerPaths,
        json: json
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct RunSketchyBarHook: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_run-sketchybar-hook",
      shouldDisplay: false
    )

    @Argument var hook: String

    mutating func run() throws {
      try SketchyBarHookRunner().execute(URL(filePath: hook).standardizedFileURL)
    }
  }
}
