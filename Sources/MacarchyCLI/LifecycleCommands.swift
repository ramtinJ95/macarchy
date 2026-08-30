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
      abstract: "Prepare dependencies and supported integration seams."
    )

    @Option(name: .customLong("dependency-profile"), help: "Dependency profile to inspect.")
    var dependencyProfile = "personal"

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @Option(help: "Exact keybinding adoption evidence digest from the reviewed setup plan.")
    var adoptKeybindings: String?

    @Flag(help: "Install missing Homebrew dependencies for the selected profile.")
    var installDependencies = false

    @Flag(help: "Describe setup readiness without making changes.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let execution = try SetupCommandRunner.live.execute(
        profileName: dependencyProfile,
        homeDirectory: home,
        installDependencies: installDependencies,
        dryRun: dryRun,
        keybindingProfileURL:
          profile.map { URL(filePath: $0).standardizedFileURL }
          ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL,
        keybindingProfileRequired: profile != nil,
        adoptKeybindings: adoptKeybindings,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
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
