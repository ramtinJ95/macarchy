import ArgumentParser
import Foundation

struct Desktop: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Plan and manage the default desktop providers.",
    subcommands: [Plan.self, Apply.self, Status.self, Teardown.self]
  )

  struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Plan managed yabai desktop configuration without making changes."
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

  struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Publish, activate, and verify managed yabai configuration."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Option(help: "Exact adoption evidence digest from the reviewed desktop plan.")
    var adopt: String?

    @Flag(help: "Inspect without publishing, activating, or adopting yabai.")
    var dryRun = false

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
          try DesktopPlanCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
            profileURL: profileURL,
            profileRequired: profile != nil,
            stateRoot: stateRootURL,
            homeDirectory: home,
            json: json
          )
        } else {
          try DesktopApplyCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
            profileURL: profileURL,
            profileRequired: profile != nil,
            stateRoot: stateRootURL,
            homeDirectory: home,
            adopt: adopt,
            json: json
          )
        }
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Report managed yabai generation, ownership, and runtime state."
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
      let execution = try DesktopStatusCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
        profileURL: profileURL,
        profileRequired: profile != nil,
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        homeDirectory: home,
        json: json
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct Teardown: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Restore the exact yabai provider entry adopted by Macarchy."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Preview restoration without mutation.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try DesktopTeardownCommandRunner.live.execute(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        dryRun: dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }
}
