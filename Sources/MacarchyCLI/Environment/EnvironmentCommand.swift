import ArgumentParser
import Foundation
import ThemeCore

struct EnvironmentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "environment",
    abstract: "Plan and manage the curated daily tool environment.",
    subcommands: [
      Plan.self, Apply.self, Status.self, Doctor.self, Teardown.self, MigrateNeovim.self,
      SeedConfiguration.self, MigrateAtuin.self, MigrateStarship.self, ConfigurationSource.self,
    ]
  )

  struct ConfigurationSource: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "configuration-source",
      abstract: "Resolve a user-owned editor target without opening it or applying changes.")

    @Argument(help: "Provider: zsh, kitty, atuin, starship or neovim.")
    var provider: String
    @OptionGroup var profile: Macarchy.Setup.ProfileOptions
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy").path
    @Flag(help: "Emit the source resolution as JSON.") var json = false

    mutating func run() throws {
      guard let provider = EnvironmentNativeSeed.Provider(rawValue: provider) else {
        throw ValidationError("provider must be zsh, kitty, atuin, starship or neovim")
      }
      let context = profile.context(stateRoot: URL(filePath: stateRoot).standardizedFileURL)
      let layered = try PortableProfileLoader().load(
        portableAt: context.profileURL, portableRequired: context.profileRequired,
        machineAt: context.machineProfileURL, machineRequired: context.machineProfileRequired)
      let result = EnvironmentConfigurationSourceResolver(
        homeDirectory: context.homeDirectory, stateRoot: context.stateRoot
      ).resolve(provider, profile: layered.profile)
      print(try result.render(json: json))
      if result.status != .editable { throw ExitCode.failure }
    }
  }

  struct SeedConfiguration: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "seed-configuration",
      abstract: "Preview or approve a new writable native starter; never overwrite a file.")

    @Argument(help: "Provider: zsh, kitty, neovim, atuin or starship (requires an active theme).")
    var provider: String
    @Option(help: "Absent starter file or Neovim directory in an existing user-owned directory.")
    var destination: String
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy").path
    @Option(help: "Exact approval digest from the starter preview.") var approve: String?
    @Flag(help: "Emit the preview as JSON.") var json = false

    mutating func run() throws {
      guard let provider = EnvironmentNativeSeed.Provider(rawValue: provider) else {
        throw ValidationError("provider must be zsh, kitty, neovim, atuin or starship")
      }
      guard approve == nil || !json else {
        throw ValidationError("--json is a preview option; omit it when approving")
      }
      let seed = EnvironmentNativeSeed(
        provider: provider, destination: URL(filePath: destination).standardizedFileURL,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        stateRoot: URL(filePath: stateRoot).standardizedFileURL)
      let plan = try approve.map { try seed.seed(approval: $0) } ?? seed.plan()
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(plan), as: UTF8.self))
      } else {
        print("Destination: \(plan.destination)\n\(plan.contents)\n\(plan.message)")
        if approve == nil {
          print("Review this starter, then repeat with --approve '\(plan.approval)'.")
        } else {
          print("Created writable starter; active configuration is unchanged.")
        }
      }
    }
  }

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

    @Option(help: "Connect a prepared native Neovim directory instead of seeding a copy.")
    var source: String?

    @Flag(help: "Emit the migration preview as JSON.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let root = URL(filePath: stateRoot).standardizedFileURL
      let sourceURL = source.map { URL(filePath: $0).standardizedFileURL }
      let migration = EnvironmentNeovimMigration(
        homeDirectory: home, stateRoot: root, sourceURL: sourceURL)
      if let approve {
        guard !json else {
          throw ValidationError("--json is a preview option; omit it when approving")
        }
        let lock = EnvironmentLifecycleLock(stateRoot: root)
        let descriptor = try lock.acquire()
        defer { lock.release(descriptor) }
        let message = try ActivationLock(root: root).withLock {
          try EnvironmentTransactionCoordinator(homeDirectory: home, stateRoot: root)
            .migrateNeovimLocked(approval: approve, sourceURL: sourceURL)
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

  struct MigrateAtuin: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "migrate-atuin",
      abstract:
        "Preview or approve a writable copy of the active Atuin settings. History is untouched.")

    @OptionGroup var options: NativeFileMigrationOptions
    mutating func run() throws { try options.run(provider: .atuin) }
  }

  struct MigrateStarship: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "migrate-starship",
      abstract: "Preview or approve writable Starship settings with a narrowly managed palette.")
    @OptionGroup var options: NativeFileMigrationOptions
    mutating func run() throws { try options.run(provider: .starship) }
  }

  struct NativeFileMigrationOptions: ParsableArguments {
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy").path
    @Option(help: "Exact approval digest from the migration preview.") var approve: String?
    @Option(help: "Connect an existing prepared native settings file instead of seeding a copy.")
    var source: String?
    @Flag(help: "Emit the migration preview as JSON.") var json = false

    func run(provider: EnvironmentNativeFileMigration.Provider) throws {
      let sourceURL = source.map { URL(filePath: $0).standardizedFileURL }
      let home = FileManager.default.homeDirectoryForCurrentUser
      let root = URL(filePath: stateRoot).standardizedFileURL
      let migration = EnvironmentNativeFileMigration(
        provider: provider, homeDirectory: home, stateRoot: root, sourceURL: sourceURL)
      if let approve {
        guard !json else {
          throw ValidationError("--json is a preview option; omit it when approving")
        }
        let lock = EnvironmentLifecycleLock(stateRoot: root)
        let descriptor = try lock.acquire()
        defer { lock.release(descriptor) }
        let message = try ActivationLock(root: root).withLock {
          try EnvironmentTransactionCoordinator(homeDirectory: home, stateRoot: root)
            .migrateNativeFileLocked(provider: provider, approval: approve, sourceURL: sourceURL)
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
