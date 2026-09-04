import ArgumentParser
import Foundation
import ThemeCore

extension Macarchy {
  struct Reconcile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Reconcile the active theme with selected consumers."
    )

    @OptionGroup var state: StateOptions

    @Argument(help: "Adapter identifiers. Omit to reconcile all known adapters.")
    var adapters: [String] = []

    @Flag(help: "Inspect without running processes or writing status.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let execution = try await ReconcileCommandRunner.live.execute(
        adapterIDs: adapters,
        stateRoot: state.stateRootURL,
        consumerPaths: state.consumerPaths,
        dryRun: dryRun,
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
      abstract: "Diagnose canonical theme state and consumer integration."
    )

    @OptionGroup var state: StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try DoctorCommandRunner.live.execute(
        stateRoot: state.stateRootURL,
        consumerPaths: state.consumerPaths,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Plan and converge the complete curated Macarchy core.",
      subcommands: [Plan.self]
    )

    struct Plan: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Compile and inspect the complete core setup without making changes."
      )

      @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
      var profile: String?

      @Option(
        name: .customLong("machine-profile"),
        help: "Machine-local profile overlay. Defaults to ~/.config/macarchy/machine.toml."
      )
      var machineProfile: String?

      @Option(help: "Canonical Macarchy state directory.")
      var stateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let execution = try UnifiedSetupPlanCommandRunner.live.execute(
          context: UnifiedSetupPlanContext(
            themesRoot: RuntimeEnvironment.live.builtInThemesURL,
            keybindingsResourcesRoot: RuntimeEnvironment.live.builtInKeybindingsURL,
            desktopResourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
            environmentResourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
            profileURL: profile.map { URL(filePath: $0).standardizedFileURL }
              ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL,
            profileRequired: profile != nil,
            machineProfileURL: machineProfile.map { URL(filePath: $0).standardizedFileURL }
              ?? home.appending(path: ".config/macarchy/machine.toml").standardizedFileURL,
            machineProfileRequired: machineProfile != nil,
            stateRoot: URL(
              filePath: stateRoot,
              directoryHint: .isDirectory
            ).standardizedFileURL,
            homeDirectory: home
          ),
          json: json
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }
  }

  struct Teardown: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Reverse only integrations recorded as Macarchy-owned."
    )

    @Flag(help: "Describe teardown without making changes.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try TeardownCommandRunner.live.execute(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        dryRun: dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }
}
