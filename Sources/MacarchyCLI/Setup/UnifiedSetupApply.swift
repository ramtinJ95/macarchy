import Foundation
import ThemeCore

struct UnifiedSetupApplyCommandRunner: Sendable {
  typealias ComponentApply =
    @Sendable (
      UnifiedSetupPlanContext,
      PortableProfile,
      ThemeConsumerPaths,
      UnifiedSetupAdoptionApprovals
    ) async throws
    -> SetupComponentExecution
  typealias ThemeApply =
    @Sendable (ThemePackage, URL) async throws -> SetupComponentExecution

  let planner: UnifiedSetupPlanCommandRunner
  let themeInspection: UnifiedSetupThemeInspection
  let processRunner: ProcessRunner
  let capabilityIsAvailable: @Sendable (DependencyCapability) -> Bool
  let writePreMutationPlan: @Sendable (String) throws -> Void
  let themeApply: ThemeApply
  let desktopApply: ComponentApply
  let environmentApply: ComponentApply
  let transactionTeardown: UnifiedSetupTeardownCommandRunner
  let faultInjector: @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void

  init(
    planner: UnifiedSetupPlanCommandRunner,
    themeInspection: @escaping UnifiedSetupThemeInspection,
    processRunner: ProcessRunner,
    capabilityIsAvailable: @escaping @Sendable (DependencyCapability) -> Bool,
    writePreMutationPlan: @escaping @Sendable (String) throws -> Void,
    themeApply: @escaping ThemeApply,
    desktopApply: @escaping ComponentApply,
    environmentApply: @escaping ComponentApply,
    transactionTeardown: UnifiedSetupTeardownCommandRunner = .live,
    faultInjector: @escaping @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void = {
      _ in
    }
  ) {
    self.planner = planner
    self.themeInspection = themeInspection
    self.processRunner = processRunner
    self.capabilityIsAvailable = capabilityIsAvailable
    self.writePreMutationPlan = writePreMutationPlan
    self.themeApply = themeApply
    self.desktopApply = desktopApply
    self.environmentApply = environmentApply
    self.transactionTeardown = transactionTeardown
    self.faultInjector = faultInjector
  }

  static let live = Self(
    planner: .live,
    themeInspection: UnifiedSetupThemeLifecycleStatus.inspect,
    processRunner: .live,
    capabilityIsAvailable: { $0.isAvailable() },
    writePreMutationPlan: { output in
      try FileHandle.standardError.write(contentsOf: Data("\(output)\n".utf8))
    },
    themeApply: { package, stateRoot in
      let store = SetupCoreOwnershipStore(stateRoot: stateRoot)
      guard try store.read() == nil else { throw SetupCoreOwnershipError.alreadyExists }
      let appearance = MacOSAppearanceAdapter.live(root: stateRoot)
      let originalAppearance = try appearance.preflight()
      let manifest: GenerationManifest
      do {
        manifest = try ThemeActivator(root: stateRoot).activate(
          package: package,
          onCommittedLocked: { manifest in
            try store.write(
              SetupCoreOwnership(
                themeGenerationID: manifest.generationID,
                originalAppearance: originalAppearance
              )
            )
          }
        )
      } catch let error as ThemeCommittedActivationError {
        let report = ThemeSetReport.committedActivationError(
          manifest: error.manifest,
          cause: error.cause,
          slackTheme: nil
        )
        return try SetupComponentExecution(
          (output: report.render(json: true), succeeded: false)
        )
      } catch {
        let report = ThemeSetReport.precommitFailure(themeID: package.id, error: error)
        return try SetupComponentExecution(
          (output: report.render(json: true), succeeded: false)
        )
      }
      let report: ThemeSetReport
      do {
        let appearanceResult = try await appearance.apply(package.appearance)
        let reconciliation = try ReconciliationStatusStore(root: stateRoot).persist(
          manifest: manifest,
          results: [appearanceResult]
        )
        report = .committed(
          result: ThemeActivationResult(
            manifest: manifest,
            reconciliation: reconciliation
          ),
          requiredFailure: appearanceResult.status == .failed
            || appearanceResult.status == .drifted,
          slackTheme: nil
        )
      } catch {
        report = .committedError(
          manifest: manifest,
          cause: String(describing: error),
          slackTheme: nil
        )
      }
      return try SetupComponentExecution(
        (output: report.render(json: true), succeeded: report.succeeded)
      )
    },
    desktopApply: { context, profile, consumerPaths, adoptions in
      try await SetupComponentExecution(
        DesktopApplyCommandRunner.live.executeAggregate(
          resourcesRoot: context.desktopResourcesRoot,
          keybindingsResourcesRoot: context.keybindingsResourcesRoot,
          profileURL: context.profileURL,
          profileRequired: context.profileRequired,
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          consumerPaths: consumerPaths,
          adopt: adoptions.yabai,
          keybindingsAdopt: adoptions.keybindings,
          sketchyBarAdopt: adoptions.sketchybar,
          json: true,
          deferFinalization: true,
          profile: profile
        )
      )
    },
    environmentApply: { context, profile, consumerPaths, adoptions in
      try await SetupComponentExecution(
        EnvironmentApplyCommandRunner.live.execute(
          resourcesRoot: context.environmentResourcesRoot,
          profileURL: context.profileURL,
          profileRequired: context.profileRequired,
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          consumerPaths: consumerPaths,
          adopt: adoptions.environment,
          json: true,
          deferFinalization: true,
          profile: profile
        )
      )
    }
  )

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    installDependencies: Bool,
    adoptions: UnifiedSetupAdoptionApprovals = .none,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let transactionStore = UnifiedSetupTransactionStore(stateRoot: context.stateRoot)
    do {
      if try transactionStore.read() != nil {
        return try await recoverInterrupted(
          context: context,
          consumerPaths: consumerPaths,
          json: json
        )
      }
    } catch {
      return try result(
        outcome: "recovery_required",
        mutated: false,
        plan: nil,
        message: String(describing: error),
        json: json
      )
    }

    let preparation: UnifiedSetupPreparation
    do {
      preparation = try planner.prepare(context: context)
    } catch {
      return try result(
        outcome: "blocked",
        mutated: false,
        plan: nil,
        message: "Setup preflight failed: \(error)",
        json: json
      )
    }
    guard case .ready(let model, let plan) = preparation else {
      return try result(
        outcome: preparation.report.outcome,
        mutated: false,
        plan: preparation.report,
        message: "The unified setup plan is blocked.",
        json: json
      )
    }
    do {
      try adoptions.validate(required: plan.adoption)
    } catch {
      return try result(
        outcome: "blocked",
        mutated: false,
        plan: plan,
        message: String(describing: error),
        json: json
      )
    }
    guard model.packages.external.isEmpty else {
      return try result(
        outcome: "blocked",
        mutated: false,
        plan: plan,
        message: "Complete every external prerequisite from the reviewed setup plan first.",
        json: json
      )
    }
    let ownership: SetupCoreOwnership?
    do {
      ownership = try SetupCoreOwnershipStore(stateRoot: context.stateRoot).read()
    } catch {
      return try result(
        outcome: "blocked",
        mutated: false,
        plan: plan,
        message: String(describing: error),
        json: json
      )
    }
    let themeLifecycle = themeInspection(model, ownership, context.stateRoot)
    guard themeLifecycle.succeeded else {
      return try result(
        outcome: "blocked",
        mutated: false,
        plan: plan,
        message: themeLifecycle.message,
        json: json
      )
    }
    guard installDependencies || model.packages.requests.isEmpty else {
      return try result(
        outcome: "blocked",
        mutated: false,
        plan: plan,
        message: "Missing Homebrew dependencies require --install-dependencies.",
        json: json
      )
    }

    try writePreMutationPlan(try plan.render(json: json))

    do {
      return try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        let store = UnifiedSetupTransactionStore(stateRoot: context.stateRoot)
        guard try store.read() == nil else {
          throw UnifiedSetupTransactionError.recoveryRequired(
            "another unified setup operation started after preflight"
          )
        }
        let currentPreparation: UnifiedSetupPreparation
        do {
          currentPreparation = try planner.prepare(context: context)
        } catch {
          return try result(
            outcome: "blocked",
            mutated: false,
            plan: nil,
            message: "Setup revalidation failed: \(error)",
            json: json
          )
        }
        guard case .ready(let currentModel, let currentPlan) = currentPreparation else {
          return try result(
            outcome: currentPreparation.report.outcome,
            mutated: false,
            plan: currentPreparation.report,
            message: "The unified setup plan changed before mutation.",
            json: json
          )
        }
        guard try currentPlan.render(json: true) == plan.render(json: true) else {
          return try result(
            outcome: "blocked",
            mutated: false,
            plan: currentPlan,
            message: "The unified setup plan changed before mutation; review it and retry.",
            json: json
          )
        }
        let currentOwnership: SetupCoreOwnership?
        do {
          currentOwnership = try SetupCoreOwnershipStore(stateRoot: context.stateRoot).read()
        } catch {
          return try result(
            outcome: "blocked",
            mutated: false,
            plan: currentPlan,
            message: String(describing: error),
            json: json
          )
        }
        let currentTheme = themeInspection(currentModel, currentOwnership, context.stateRoot)
        guard currentTheme.succeeded else {
          return try result(
            outcome: "blocked",
            mutated: false,
            plan: currentPlan,
            message: currentTheme.message,
            json: json
          )
        }

        let packages = install(currentModel.packages)
        guard packages.succeeded else {
          return try result(
            outcome: "failed",
            mutated: packages.mutated,
            plan: currentPlan,
            packages: packages,
            message: packages.message,
            json: json
          )
        }
        let unresolved = DependencyProfile.personal(homeDirectory: context.homeDirectory)
          .selectedForSetup(currentModel.profile)
          .filter { !capabilityIsAvailable($0) }
          .map(\.id)
        guard unresolved.isEmpty else {
          return try result(
            outcome: "failed",
            mutated: packages.mutated,
            plan: currentPlan,
            packages: packages,
            message: "Selected capabilities remain missing: \(unresolved.joined(separator: ", ")).",
            json: json
          )
        }
        let plannedStages = Set(
          currentPlan.actions.compactMap { UnifiedSetupTransactionStage(rawValue: $0.stage) }
        )
        var transaction: UnifiedSetupTransaction?
        func start(_ stage: UnifiedSetupTransactionStage) throws {
          let next = UnifiedSetupTransaction(
            operation: .apply,
            stages: (transaction?.stages ?? []) + [stage],
            desiredAppearance: currentModel.themePackage.appearance,
            contextDigest: unifiedSetupContextDigest(
              context: context,
              consumerPaths: consumerPaths
            )
          )
          try store.write(next)
          transaction = next
        }

        var mutated = packages.mutated
        let theme: UnifiedSetupApplyStage
        if currentModel.theme.status == "activation_required" {
          try start(.theme)
          do {
            theme = try stage(
              await themeApply(currentModel.themePackage, context.stateRoot),
              mutationField: "committed",
              successMessage: "The curated default theme is active."
            )
          } catch {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: true,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              message: "Theme activation failed before a result was available: \(error)",
              json: json
            )
          }
          mutated = mutated || theme.mutated
          guard theme.succeeded else {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: mutated,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              message: "Theme activation did not converge.",
              json: json
            )
          }
          try faultInjector(.themeApplied)
        } else {
          theme = .noChange("Preserved active theme '\(currentModel.theme.id)'.")
        }

        let desktop: UnifiedSetupApplyStage
        if plannedStages.contains(.desktop) {
          try start(.desktop)
          do {
            desktop = try stage(
              await desktopApply(context, currentModel.profile, consumerPaths, adoptions),
              mutationField: "mutated",
              successMessage: "Desktop providers converged."
            )
          } catch {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: true,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              message: "Desktop apply failed before a result was available: \(error)",
              json: json
            )
          }
          mutated = mutated || desktop.mutated
          guard desktop.succeeded else {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: mutated,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              desktop: desktop,
              message: "Desktop apply did not converge; later stages were not run.",
              json: json
            )
          }
          try faultInjector(.desktopApplied)
        } else {
          desktop = .noChange("Preserved converged desktop providers.")
        }

        let environment: UnifiedSetupApplyStage
        if plannedStages.contains(.environment) {
          try start(.environment)
          do {
            environment = try stage(
              await environmentApply(context, currentModel.profile, consumerPaths, adoptions),
              mutationField: "mutated",
              successMessage: "The daily tool environment converged."
            )
          } catch {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: true,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              desktop: desktop,
              message: "Environment apply failed before a result was available: \(error)",
              json: json
            )
          }
          mutated = mutated || environment.mutated
          guard environment.succeeded else {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: mutated,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              desktop: desktop,
              environment: environment,
              message: "Environment apply did not converge.",
              json: json
            )
          }
          try faultInjector(.environmentApplied)
        } else {
          environment = .noChange("Preserved the converged daily tool environment.")
        }

        if let transaction {
          let committing = transaction.replacing(phase: .committing)
          try store.write(committing)
          _ = try await transactionTeardown.recover(
            transaction: committing,
            context: context,
            consumerPaths: consumerPaths
          )
        }

        return try result(
          outcome: mutated ? "applied" : "no_change",
          mutated: mutated,
          plan: currentPlan,
          packages: packages,
          theme: theme,
          desktop: desktop,
          environment: environment,
          message: mutated
            ? "The selected Macarchy core converged."
            : "The selected Macarchy core is already converged.",
          json: json
        )
      }
    } catch let error as UnifiedSetupInterruptionError {
      throw error
    } catch {
      let recoveryPending = (try? transactionStore.read()) != nil
      return try result(
        outcome: recoveryPending ? "recovery_required" : "failed",
        mutated: recoveryPending || (installDependencies && !model.packages.requests.isEmpty),
        plan: plan,
        message: String(describing: error),
        json: json
      )
    }
  }

  private func install(_ plan: HomebrewInstallPlan) -> UnifiedSetupPackageApply {
    guard !plan.requests.isEmpty else { return .noChange }
    var commands = [UnifiedSetupHomebrewCommand]()
    for request in plan.requests {
      do {
        let result = try processRunner.run(request)
        let command = UnifiedSetupHomebrewCommand(request: request, result: result)
        commands.append(command)
        guard command.succeeded else {
          return UnifiedSetupPackageApply(
            outcome: "failed",
            mutated: true,
            commands: commands,
            message: command.message
          )
        }
      } catch {
        commands.append(UnifiedSetupHomebrewCommand(request: request, error: error))
        return UnifiedSetupPackageApply(
          outcome: "failed",
          mutated: true,
          commands: commands,
          message: "Homebrew execution failed; package state may have changed: \(error)"
        )
      }
    }
    return UnifiedSetupPackageApply(
      outcome: "installed",
      mutated: true,
      commands: commands,
      message: "Selected Homebrew dependencies were installed."
    )
  }

  private func failureAfterRollback(
    transaction: UnifiedSetupTransaction?,
    mutated: Bool,
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    plan: UnifiedSetupPlanReport,
    packages: UnifiedSetupPackageApply,
    theme: UnifiedSetupApplyStage? = nil,
    desktop: UnifiedSetupApplyStage? = nil,
    environment: UnifiedSetupApplyStage? = nil,
    message: String,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    guard let transaction else {
      return try result(
        outcome: "failed",
        mutated: mutated,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        environment: environment,
        message: message,
        json: json
      )
    }
    do {
      _ = try await transactionTeardown.recover(
        transaction: transaction,
        context: context,
        consumerPaths: consumerPaths
      )
      return try result(
        outcome: "rolled_back",
        mutated: true,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        environment: environment,
        message: "\(message) Completed setup stages were rolled back.",
        json: json
      )
    } catch {
      return try result(
        outcome: "recovery_required",
        mutated: true,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        environment: environment,
        message: "\(message) Rollback requires recovery: \(error)",
        json: json
      )
    }
  }

  private func recoverInterrupted(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    do {
      let recovered = try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        guard
          let transaction = try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read()
        else {
          throw UnifiedSetupTransactionError.recoveryRequired(
            "the interrupted transaction disappeared before recovery"
          )
        }
        return (
          transaction: transaction,
          result: try await transactionTeardown.recover(
            transaction: transaction,
            context: context,
            consumerPaths: consumerPaths
          )
        )
      }
      if recovered.transaction.operation == .apply,
        recovered.transaction.phase == .committing
      {
        return try result(
          outcome: "applied",
          mutated: recovered.result.mutated,
          plan: nil,
          message: "Interrupted unified apply had committed; transaction cleanup completed.",
          json: json
        )
      }
      return try result(
        outcome: recovered.transaction.operation == .apply ? "rolled_back" : "blocked",
        mutated: recovered.result.mutated,
        plan: nil,
        message: recovered.transaction.operation == .apply
          ? "Interrupted unified apply was rolled back; review the current plan before retrying."
          : "Interrupted teardown was completed; review the current plan before applying.",
        json: json
      )
    } catch {
      return try result(
        outcome: "recovery_required",
        mutated: true,
        plan: nil,
        message: String(describing: error),
        json: json
      )
    }
  }

  private func stage(
    _ execution: SetupComponentExecution,
    mutationField: String,
    successMessage: String
  ) throws -> UnifiedSetupApplyStage {
    guard case .bool(let mutated) = execution.report[mutationField] else {
      throw SetupComponentReportError(
        description: "Delegated result is missing boolean field '\(mutationField)'."
      )
    }
    return UnifiedSetupApplyStage(
      succeeded: execution.succeeded,
      mutated: mutated,
      message: execution.succeeded
        ? successMessage
        : execution.report["message"]?.string
          ?? execution.report["error"]?.string
          ?? "The delegated operation failed.",
      details: execution.report
    )
  }

  private func result(
    outcome: String,
    mutated: Bool,
    plan: UnifiedSetupPlanReport?,
    packages: UnifiedSetupPackageApply? = nil,
    theme: UnifiedSetupApplyStage? = nil,
    desktop: UnifiedSetupApplyStage? = nil,
    environment: UnifiedSetupApplyStage? = nil,
    message: String,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report = UnifiedSetupApplyReport(
      outcome: outcome,
      mutated: mutated,
      plan: plan,
      packages: packages,
      theme: theme,
      desktop: desktop,
      environment: environment,
      message: message
    )
    return (try report.render(json: json), report.succeeded)
  }
}

struct UnifiedSetupPackageApply: Encodable, Sendable {
  let outcome: String
  let mutated: Bool
  let commands: [UnifiedSetupHomebrewCommand]
  let message: String

  var succeeded: Bool { outcome != "failed" }

  static let noChange = Self(
    outcome: "no_change",
    mutated: false,
    commands: [],
    message: "Selected Homebrew dependencies are already present."
  )
}

struct UnifiedSetupHomebrewCommand: Encodable, Sendable {
  let executable: String
  let arguments: [String]
  let terminationStatus: Int32?
  let output: String?
  let error: String?

  init(request: ProcessRequest, result: ProcessResult) {
    executable = request.executableURL.path
    arguments = request.arguments
    terminationStatus = result.terminationStatus
    output = result.output.isEmpty ? nil : result.output
    error = nil
  }

  init(request: ProcessRequest, error: Error) {
    executable = request.executableURL.path
    arguments = request.arguments
    terminationStatus = nil
    output = nil
    self.error = String(describing: error)
  }

  var succeeded: Bool { terminationStatus == 0 }

  var message: String {
    output ?? error
      ?? "Homebrew exited with status \(terminationStatus.map(String.init) ?? "unknown")."
  }

  enum CodingKeys: String, CodingKey {
    case executable, arguments, output, error
    case terminationStatus = "termination_status"
  }
}

struct UnifiedSetupApplyStage: Encodable, Sendable {
  let succeeded: Bool
  let mutated: Bool
  let message: String
  let details: JSONValue?

  static func noChange(_ message: String) -> Self {
    Self(succeeded: true, mutated: false, message: message, details: nil)
  }
}

private struct UnifiedSetupApplyReport: Encodable {
  let schemaVersion = 1
  let operation = "setup_apply"
  let outcome: String
  let mutated: Bool
  let plan: UnifiedSetupPlanReport?
  let packages: UnifiedSetupPackageApply?
  let theme: UnifiedSetupApplyStage?
  let desktop: UnifiedSetupApplyStage?
  let environment: UnifiedSetupApplyStage?
  let message: String

  var succeeded: Bool { outcome == "applied" || outcome == "no_change" }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy setup apply [\(outcome)]:",
      "- mutated: \(mutated ? "yes" : "no")",
      "- \(message)",
    ]
    if let packages { lines.append("- packages [\(packages.outcome)]: \(packages.message)") }
    if let theme { lines.append("- theme: \(theme.message)") }
    if let desktop { lines.append("- desktop: \(desktop.message)") }
    if let environment { lines.append("- environment: \(environment.message)") }
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, mutated, plan, packages, theme, desktop, environment, message
  }
}
