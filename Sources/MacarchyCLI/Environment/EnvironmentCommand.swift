import ArgumentParser
import Foundation
import ThemeCore

struct EnvironmentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "environment",
    abstract: "Plan and manage the curated daily tool environment.",
    subcommands: [
      Plan.self, Apply.self, Status.self, Doctor.self, Teardown.self, MigrateNeovim.self,
    ]
  )

  struct MigrateNeovim: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "migrate-neovim",
      abstract:
        "Preview or approve a writable copy of the active Neovim configuration. No plugin downloads."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy").path

    @Option(help: "Exact approval digest from the migration preview.")
    var approve: String?

    @Flag(help: "Emit the migration preview as JSON.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let root = URL(filePath: stateRoot).standardizedFileURL
      let migration = EnvironmentNeovimMigration(homeDirectory: home, stateRoot: root)
      if let approve {
        guard !json else {
          throw ValidationError("--json is a preview option; omit it when approving")
        }
        let lock = EnvironmentLifecycleLock(stateRoot: root)
        let descriptor = try lock.acquire()
        defer { lock.release(descriptor) }
        let message = try ActivationLock(root: root).withLock {
          try EnvironmentTransactionCoordinator(homeDirectory: home, stateRoot: root)
            .migrateNeovimLocked(approval: approve)
        }
        print(message)
      } else {
        let (plan, _) = try migration.plan()
        if json {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          print(String(decoding: try encoder.encode(plan), as: UTF8.self))
        } else {
          print("Source: \(plan.source)\nDestination: \(plan.destination)\n\(plan.message)")
          print("Review this migration, then repeat with --approve '\(plan.approval)'.")
        }
      }
    }
  }

  struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Compose the curated terminal, editor, and TUI environment without changes."
    )

    @OptionGroup var profileOptions: PortableProfileOptions

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL = profileOptions.url(homeDirectory: home)
      let execution = try EnvironmentPlanCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
        profileURL: profileURL,
        profileRequired: profileOptions.isRequired,
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

    @OptionGroup var profileOptions: PortableProfileOptions

    @OptionGroup var state: Macarchy.StateOptions

    @Option(help: "Exact aggregate adoption evidence digest from the reviewed environment plan.")
    var adopt: String?

    @Flag(help: "Inspect the environment without mutation.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL = profileOptions.url(homeDirectory: home)
      let execution =
        if dryRun {
          try EnvironmentPlanCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
            profileURL: profileURL,
            profileRequired: profileOptions.isRequired,
            stateRoot: state.stateRootURL,
            homeDirectory: home,
            json: json
          )
        } else {
          try await EnvironmentApplyCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
            profileURL: profileURL,
            profileRequired: profileOptions.isRequired,
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

    @OptionGroup var profileOptions: PortableProfileOptions

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution = try EnvironmentStatusCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
        profileURL: profileOptions.url(homeDirectory: home),
        profileRequired: profileOptions.isRequired,
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

    @OptionGroup var profileOptions: PortableProfileOptions

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution = try EnvironmentDoctorCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
        profileURL: profileOptions.url(homeDirectory: home),
        profileRequired: profileOptions.isRequired,
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
}
