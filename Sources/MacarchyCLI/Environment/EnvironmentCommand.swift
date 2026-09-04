import ArgumentParser
import Foundation

struct EnvironmentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "environment",
    abstract: "Plan and manage the curated daily tool environment.",
    subcommands: [Plan.self, Apply.self, Status.self, Doctor.self, Teardown.self]
  )

  struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Compose the curated terminal, editor, and TUI environment without changes."
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
      let execution = try EnvironmentPlanCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
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

  struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Publish, activate, and verify the managed daily tool environment."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @OptionGroup var state: Macarchy.StateOptions

    @Option(help: "Exact aggregate adoption evidence digest from the reviewed environment plan.")
    var adopt: String?

    @Flag(help: "Inspect the environment without mutation.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL = resolvedProfile(profile, home: home)
      let execution =
        if dryRun {
          try EnvironmentPlanCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
            profileURL: profileURL,
            profileRequired: profile != nil,
            stateRoot: state.stateRootURL,
            homeDirectory: home,
            json: json
          )
        } else {
          try await EnvironmentApplyCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
            profileURL: profileURL,
            profileRequired: profile != nil,
            stateRoot: state.stateRootURL,
            homeDirectory: home,
            consumerPaths: state.consumerPaths,
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
      abstract: "Report environment generation, ownership, prerequisites, and theme seams."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution = try EnvironmentStatusCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
        profileURL: resolvedProfile(profile, home: home),
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

  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose managed providers and verify the daily tool environment."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution = try EnvironmentDoctorCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
        profileURL: resolvedProfile(profile, home: home),
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

  struct Teardown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Restore the exact provider entries adopted by the environment lifecycle."
    )

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Preview exact restoration without mutation.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let execution = try await EnvironmentTeardownCommandRunner.live.execute(
        stateRoot: state.stateRootURL,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        consumerPaths: state.consumerPaths,
        dryRun: dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  private static func resolvedProfile(_ profile: String?, home: URL) -> URL {
    profile.map { URL(filePath: $0).standardizedFileURL }
      ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
  }
}
