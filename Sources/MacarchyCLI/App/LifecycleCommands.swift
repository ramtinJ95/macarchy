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
      subcommands: [
        Guided.self, Plan.self, AdoptPackages.self, InstallPackages.self, AddPackages.self,
        Apply.self, Recover.self, Status.self,
        Doctor.self,
        Teardown.self,
      ]
    )

    struct ProfileOptions: ParsableArguments {
      @OptionGroup var portable: PortableProfileOptions

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
          profileURL: portable.url(homeDirectory: home),
          profileRequired: portable.isRequired,
          machineProfileURL: machineProfile.map { URL(filePath: $0).standardizedFileURL }
            ?? home.appending(path: ".config/macarchy/machine.toml").standardizedFileURL,
          machineProfileRequired: machineProfile != nil,
          stateRoot: stateRoot,
          homeDirectory: home
        )
      }
    }

    struct AdoptionOptions: ParsableArguments {
      @Option(help: "Versioned JSON file containing machine-bound adoption approvals.")
      var adoptionFile: String?

      @Option(help: "Exact yabai adoption digest from the reviewed setup plan.")
      var yabaiAdopt: String?

      @Option(help: "Exact skhd adoption digest from the reviewed setup plan.")
      var keybindingsAdopt: String?

      @Option(help: "Exact SketchyBar adoption digest from the reviewed setup plan.")
      var sketchybarAdopt: String?

      @Option(help: "Exact environment adoption digest from the reviewed setup plan.")
      var environmentAdopt: String?

      func resolve() throws -> UnifiedSetupAdoptionApprovals {
        let commandLine = UnifiedSetupAdoptionApprovals(
          yabai: yabaiAdopt,
          keybindings: keybindingsAdopt,
          sketchybar: sketchybarAdopt,
          environment: environmentAdopt
        )
        guard let adoptionFile else { return commandLine }
        guard commandLine.values.isEmpty else {
          throw ValidationError(
            "--adoption-file cannot be combined with named adoption options."
          )
        }
        return try UnifiedSetupAdoptionFile.load(
          at: URL(filePath: adoptionFile).standardizedFileURL
        )
      }
    }

    struct Guided: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Create a sparse portable profile and optionally apply its reviewed plan."
      )

      @Option(
        name: .customLong("output-profile"),
        help: "New portable profile path. Defaults to ~/.config/macarchy/profile.toml."
      )
      var outputProfile: String?

      @Option(
        name: .customLong("machine-profile"),
        help: "Machine-local profile overlay. Defaults to ~/.config/macarchy/machine.toml."
      )
      var machineProfile: String?

      @OptionGroup var state: StateOptions

      mutating func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profileURL =
          outputProfile.map { URL(filePath: $0).standardizedFileURL }
          ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
        let machineProfileURL =
          machineProfile.map { URL(filePath: $0).standardizedFileURL }
          ?? home.appending(path: ".config/macarchy/machine.toml").standardizedFileURL
        let execution = try await GuidedSetupCommandRunner.live().execute(
          context: UnifiedSetupPlanContext(
            themesRoot: RuntimeEnvironment.live.builtInThemesURL,
            keybindingsResourcesRoot: RuntimeEnvironment.live.builtInKeybindingsURL,
            desktopResourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
            environmentResourcesRoot: RuntimeEnvironment.live.builtInEnvironmentURL,
            profileURL: profileURL,
            profileRequired: true,
            machineProfileURL: machineProfileURL,
            machineProfileRequired: machineProfile != nil,
            stateRoot: state.stateRootURL,
            homeDirectory: home
          ),
          consumerPaths: state.consumerPaths
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
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

    struct AdoptPackages: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract:
          "Preview or explicitly adopt named installed package declarations without changing Homebrew."
      )

      @Argument(help: "Exact declared identities, such as formula:jq or cask:slack.")
      var targets: [String]

      @Option(help: "Exact approval digest from the reviewed package adoption preview.")
      var approve: String?

      @OptionGroup var profile: ProfileOptions

      @Option(help: "Canonical Macarchy state directory.")
      var stateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() async throws {
        let execution = try await SetupPackageAdoptionCommandRunner.live.execute(
          context: profile.context(stateRoot: URL(filePath: stateRoot).standardizedFileURL),
          targets: targets, approval: approve, json: json
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }

    struct InstallPackages: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract:
          "Preview and install named missing formulae and casks, including required taps, through Homebrew Bundle."
      )

      @Argument(help: "Exact declared formula:<name> or cask:<name> targets; omit for --recover.")
      var targets: [String] = []

      @Option(help: "Exact digest from the reviewed Brewfile and native command scope.")
      var approve: String?

      @Flag(help: "Resolve an interrupted attempt by observation only; never rerun Homebrew.")
      var recover = false

      @OptionGroup var profile: ProfileOptions

      @Option(help: "Canonical Macarchy state directory.")
      var stateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() async throws {
        let context = profile.context(stateRoot: URL(filePath: stateRoot).standardizedFileURL)
        let execution = try await SetupPackageInstallationCommandRunner.live(
          homeDirectory: context.homeDirectory
        )
        .execute(
          context: context, targets: targets, approval: approve, recover: recover, json: json)
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }

    struct AddPackages: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract:
          "Save named formulae and casks to personal inputs, then install or adopt them."
      )

      @Argument(help: "Exact formula:<name> or cask:<name> identities; omit for --recover.")
      var targets: [String] = []

      @Option(help: "Exact digest from the reviewed file edit and package action preview.")
      var approve: String?

      @Flag(help: "Edit the machine fragment instead of the default portable fragment.")
      var machineOnly = false

      @Flag(help: "Finish recorded input publication only; never install or adopt packages.")
      var recover = false

      @OptionGroup var profile: ProfileOptions

      @Option(help: "Canonical Macarchy state directory.")
      var stateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() async throws {
        let context = profile.context(stateRoot: URL(filePath: stateRoot).standardizedFileURL)
        let execution = try await SetupPackageAdditionCommandRunner.live(
          homeDirectory: context.homeDirectory
        )
        .execute(
          context: context, targets: targets, machineOnly: machineOnly, approval: approve,
          recover: recover, json: json)
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
      @OptionGroup var adoption: AdoptionOptions

      @Flag(
        help: "Deprecated and ignored. Use --approve-packages with the reviewed setup plan digest.")
      var installDependencies = false

      @Option(help: "Exact package installation digest from setup plan.")
      var approvePackages: String?

      @Option(help: "Exact native preferences approval digest from setup plan.")
      var approvePreferences: String?

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() async throws {
        let execution = try await UnifiedSetupApplyCommandRunner.live.execute(
          context: profile.context(stateRoot: state.stateRootURL),
          consumerPaths: state.consumerPaths,
          packageApproval: approvePackages,
          preferencesApproval: approvePreferences,
          adoptions: try adoption.resolve(),
          json: json
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }

    struct Recover: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Recover interrupted setup without starting a new apply.")

      @OptionGroup var profile: ProfileOptions
      @OptionGroup var state: StateOptions

      @Flag(
        help:
          "Restore original Spicetify configuration but explicitly leave Spotify runtime UNVERIFIED. Only valid for an interrupted apply already rolling back to original Spicetify."
      )
      var acknowledgeUnverifiedSpicetify = false

      @Flag(help: "Emit machine-readable output.")
      var json = false

      mutating func run() async throws {
        let execution = try await UnifiedSetupRecoveryCommandRunner.live.execute(
          context: profile.context(stateRoot: state.stateRootURL),
          consumerPaths: state.consumerPaths,
          acknowledgeUnverifiedSpicetify: acknowledgeUnverifiedSpicetify,
          json: json)
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
