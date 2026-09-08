import ArgumentParser
import Foundation
import ThemeCore

struct PreferencesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "preferences",
    abstract: "Manage explicitly selected, observable macOS preferences.",
    subcommands: [Plan.self, Apply.self, Status.self, Doctor.self, Teardown.self, Recover.self])

  enum Operation { case plan, apply, status, teardown, recover }

  struct Options: ParsableArguments {
    @OptionGroup var profile: Macarchy.Setup.ProfileOptions

    @Option(
      help:
        "Receipt directory, NOT a sandbox for native preferences. Targets the current user on this Mac."
    )
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser.appending(
      path: ".config/macarchy"
    ).path

    @Flag(help: "Emit machine-readable output.")
    var json = false

    func run(
      _ operation: Operation, approval: String? = nil, dryRun: Bool = false,
      acknowledgeUncertainWrite: Bool = false
    ) async throws {
      let setup = profile.context(stateRoot: URL(filePath: stateRoot).standardizedFileURL)
      let context = try PreferencesContext.live(
        stateRoot: setup.stateRoot, homeDirectory: setup.homeDirectory)
      let report: PreferencesReport
      do {
        let desired: MacOSPreferencesProfile
        switch operation {
        case .plan, .apply, .status:
          desired = try PortableProfileLoader().load(
            portableAt: setup.profileURL, portableRequired: setup.profileRequired,
            machineAt: setup.machineProfileURL, machineRequired: setup.machineProfileRequired
          ).profile.macOSPreferences
        case .teardown, .recover: desired = .init()
        }
        switch operation {
        case .plan, .status:
          report = PreferencesLifecycle.live.inspect(
            context: context, desired: desired, status: operation == .status)
        case .teardown where dryRun:
          report = try PreferencesLifecycle.live.teardown(context: context, dryRun: true)
        case .apply, .teardown, .recover:
          report = try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
            if let transaction = try UnifiedSetupTransactionStore(stateRoot: context.stateRoot)
              .read()
            {
              // Explicit uncertain-write acknowledgment may unblock a recorded
              // component rollback, but never cross unified setup's commit point.
              guard operation == .recover, transaction.phase == .mutating,
                transaction.stages.contains(.preferences)
              else {
                throw PreferencesError.recoveryRequired(
                  "Recover the pending unified operation with setup apply or setup teardown first.")
              }
            }
            switch operation {
            case .apply:
              return try PreferencesLifecycle.live.apply(
                context: context, desired: desired, approval: approval)
            case .teardown:
              return try PreferencesLifecycle.live.teardown(context: context, dryRun: false)
            case .recover:
              let store = PreferencesStore(context: context)
              let pending = try store.read().pending != nil
              try PreferencesLifecycle.live.rollback(
                context: context, acknowledgeUncertainWrite: acknowledgeUncertainWrite)
              return PreferencesReport(
                outcome: "recovered", mutated: pending, receiptPath: store.url.path)
            default: preconditionFailure("Inspection must not acquire a mutation lock.")
            }
          }
        }
      } catch { report = .failure(error, context: context) }
      print(try report.render(json: json))
      if !report.succeeded { throw ExitCode.failure }
    }
  }

  struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Preview current values, exact changes, and one-shot approval without writing preferences.")
    @OptionGroup var options: Options
    mutating func run() async throws { try await options.run(.plan) }
  }

  struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Apply the exact reviewed changes and retain original values for restoration.")
    @OptionGroup var options: Options
    @Option(help: "Exact approval digest from preferences plan. Not required for a no-op.")
    var approve: String?
    mutating func run() async throws { try await options.run(.apply, approval: approve) }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Compare profile intent, owned values, and live macOS preferences.")
    @OptionGroup var options: Options
    mutating func run() async throws { try await options.run(.status) }
  }

  struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose live native capability, drift, and interrupted preference changes.")
    @OptionGroup var options: Options
    mutating func run() async throws { try await options.run(.status) }
  }

  struct Teardown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Restore only unchanged managed preferences to their captured originals.")
    @OptionGroup var options: Options
    @Flag(help: "Preview restoration without writing preferences or receipts.")
    var dryRun = false
    mutating func run() async throws { try await options.run(.teardown, dryRun: dryRun) }
  }

  struct Recover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Roll back an interrupted preference apply; never consume an old approval forward.")
    @OptionGroup var options: Options
    @Flag(
      help:
        "Confirm that a previously unacknowledged OS setter has settled before rollback. Inspect native state first."
    )
    var acknowledgeUncertainWrite = false
    mutating func run() async throws {
      try await options.run(.recover, acknowledgeUncertainWrite: acknowledgeUncertainWrite)
    }
  }
}
