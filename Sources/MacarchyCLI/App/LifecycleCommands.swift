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
      subcommands: [Plan.self, Apply.self, Status.self, Doctor.self, Teardown.self]
    )

    struct ProfileOptions: ParsableArguments {
      @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
      var profile: String?

      @Option(
        name: .customLong("machine-profile"),
        help: "Machine-local profile overlay. Defaults to ~/.config/macarchy/machine.toml."
      )
      var machineProfile: String?

      func context(stateRoot: URL) -> UnifiedSetupPlanContext {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return UnifiedSetupPlanContext(
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
          stateRoot: stateRoot,
          homeDirectory: home
        )
      }
    }

    struct Plan: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Compile and inspect the complete core setup without making changes."
      )

      @OptionGroup var profile: ProfileOptions

      @Option(help: "Canonical Macarchy state directory.")
      var stateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() throws {
        let execution = try UnifiedSetupPlanCommandRunner.live.execute(
          context: profile.context(
            stateRoot: URL(
              filePath: stateRoot,
              directoryHint: .isDirectory
            ).standardizedFileURL
          ),
          json: json
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }

    struct Apply: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Converge the selected curated core from the unified setup model."
      )

      @OptionGroup var profile: ProfileOptions
      @OptionGroup var state: StateOptions

      @Flag(help: "Install only selected missing Homebrew formulae and casks.")
      var installDependencies = false

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() async throws {
        let execution = try await UnifiedSetupApplyCommandRunner.live.execute(
          context: profile.context(stateRoot: state.stateRootURL),
          consumerPaths: state.consumerPaths,
          installDependencies: installDependencies,
          json: json
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }

    struct Status: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Inspect convergence of the selected curated core."
      )

      @OptionGroup var profile: ProfileOptions
      @OptionGroup var state: StateOptions

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() throws {
        let execution = try UnifiedSetupInspectionCommandRunner.live.execute(
          operation: .status,
          context: profile.context(stateRoot: state.stateRootURL),
          consumerPaths: state.consumerPaths,
          json: json
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }

    struct Doctor: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Diagnose the selected curated core lifecycle."
      )

      @OptionGroup var profile: ProfileOptions
      @OptionGroup var state: StateOptions

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() throws {
        let execution = try UnifiedSetupInspectionCommandRunner.live.execute(
          operation: .doctor,
          context: profile.context(stateRoot: state.stateRootURL),
          consumerPaths: state.consumerPaths,
          json: json
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }

    struct Teardown: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Reverse only state owned by the unified setup lifecycle."
      )

      @OptionGroup var profile: ProfileOptions
      @OptionGroup var state: StateOptions

      @Flag(help: "Describe reverse-order teardown without making changes.")
      var dryRun = false

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() async throws {
        let execution = try await UnifiedSetupTeardownCommandRunner.live.execute(
          context: profile.context(stateRoot: state.stateRootURL),
          consumerPaths: state.consumerPaths,
          dryRun: dryRun,
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
