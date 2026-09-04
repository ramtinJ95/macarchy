import Foundation
import ThemeCore

struct UnifiedSetupTeardownCommandRunner: Sendable {
  typealias ComponentTeardown =
    @Sendable (UnifiedSetupPlanContext, ThemeConsumerPaths, Bool) async throws
    -> SetupComponentExecution
  typealias ThemeTeardown =
    @Sendable (URL, SetupCoreOwnership?, ThemeAppearance, Bool) async throws
    -> UnifiedSetupTeardownStage

  let planner: UnifiedSetupPlanCommandRunner
  let environmentTeardown: ComponentTeardown
  let desktopTeardown: ComponentTeardown
  let themeTeardown: ThemeTeardown
  let faultInjector: @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void

  init(
    planner: UnifiedSetupPlanCommandRunner,
    environmentTeardown: @escaping ComponentTeardown,
    desktopTeardown: @escaping ComponentTeardown,
    themeTeardown: @escaping ThemeTeardown,
    faultInjector: @escaping @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void = {
      _ in
    }
  ) {
    self.planner = planner
    self.environmentTeardown = environmentTeardown
    self.desktopTeardown = desktopTeardown
    self.themeTeardown = themeTeardown
    self.faultInjector = faultInjector
  }

  static let live = Self(
    planner: .live,
    environmentTeardown: { context, consumerPaths, dryRun in
      try await SetupComponentExecution(
        EnvironmentTeardownCommandRunner.live.execute(
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          consumerPaths: consumerPaths,
          dryRun: dryRun,
          json: true
        )
      )
    },
    desktopTeardown: { context, _, dryRun in
      try SetupComponentExecution(
        DesktopTeardownCommandRunner.live.executeAggregate(
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          dryRun: dryRun,
          json: true
        )
      )
    },
    themeTeardown: { stateRoot, ownership, desiredAppearance, dryRun in
      guard let ownership else {
        return .noChange("No setup-owned canonical theme exists.")
      }
      let activator = ThemeActivator(root: stateRoot)
      _ = try activator.deactivate(
        expectedGenerationID: ownership.themeGenerationID,
        dryRun: true
      )
      let appearance = MacOSAppearanceAdapter.live(root: stateRoot)
      let currentAppearance = try appearance.preflight()
      guard currentAppearance == desiredAppearance else {
        return UnifiedSetupTeardownStage(
          succeeded: false,
          mutated: false,
          outcome: "blocked",
          message:
            "macOS appearance changed after setup; refusing to overwrite the external change.",
          details: nil
        )
      }
      if dryRun {
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: false,
          outcome: "planned",
          message: "Would restore macOS appearance and remove the setup-owned canonical theme.",
          details: nil
        )
      }

      let appearanceChanged = currentAppearance != ownership.originalAppearance
      let appearanceResult: AdapterResult
      do {
        appearanceResult = try await appearance.apply(ownership.originalAppearance)
      } catch {
        return UnifiedSetupTeardownStage(
          succeeded: false,
          mutated: appearanceChanged,
          outcome: "failed",
          message: "macOS appearance restoration failed: \(error)",
          details: nil
        )
      }
      guard appearanceResult.status == .applied else {
        return UnifiedSetupTeardownStage(
          succeeded: false,
          mutated: appearanceChanged,
          outcome: "failed",
          message: appearanceResult.message ?? "macOS appearance restoration failed.",
          details: nil
        )
      }
      let cleanupError: String?
      do {
        cleanupError = try activator.deactivate(
          expectedGenerationID: ownership.themeGenerationID,
          dryRun: false
        )
      } catch {
        return UnifiedSetupTeardownStage(
          succeeded: false,
          mutated: appearanceChanged,
          outcome: "failed",
          message: "Canonical theme removal failed: \(error)",
          details: nil
        )
      }
      if let cleanupError {
        return UnifiedSetupTeardownStage(
          succeeded: false,
          mutated: true,
          outcome: "recovery_required",
          message: "Canonical theme was removed, but cleanup remains: \(cleanupError).",
          details: nil
        )
      }
      do {
        try SetupCoreOwnershipStore(stateRoot: stateRoot).remove()
      } catch {
        return UnifiedSetupTeardownStage(
          succeeded: false,
          mutated: true,
          outcome: "recovery_required",
          message: "Canonical theme was removed, but setup ownership cleanup failed: \(error)",
          details: nil
        )
      }
      return UnifiedSetupTeardownStage(
        succeeded: true,
        mutated: true,
        outcome: "restored",
        message: "Restored macOS appearance and removed the setup-owned canonical theme.",
        details: nil
      )
    }
  )

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let transactionStore = UnifiedSetupTransactionStore(stateRoot: context.stateRoot)
    let pendingTransaction: UnifiedSetupTransaction?
    do {
      pendingTransaction = try transactionStore.read()
    } catch {
      return try result(
        outcome: "recovery_required",
        mutated: false,
        dryRun: dryRun,
        plan: nil,
        message: String(describing: error),
        json: json
      )
    }
    if let transaction = pendingTransaction {
      if dryRun {
        return try result(
          outcome: "recovery_required",
          mutated: false,
          dryRun: true,
          plan: nil,
          message:
            "An interrupted unified \(transaction.operation.rawValue) must recover before teardown preview.",
          json: json
        )
      }
      do {
        let recovered = try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
          guard
            let current = try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read()
          else {
            throw UnifiedSetupTransactionError.recoveryRequired(
              "the interrupted transaction disappeared before recovery"
            )
          }
          return (
            transaction: current,
            result: try await recover(
              transaction: current,
              context: context,
              consumerPaths: consumerPaths
            )
          )
        }
        if recovered.transaction.operation == .teardown {
          return try result(
            outcome: "restored",
            mutated: recovered.result.mutated,
            dryRun: dryRun,
            plan: nil,
            environment: recovered.result.environment,
            desktop: recovered.result.desktop,
            theme: recovered.result.theme,
            message: "Interrupted unified teardown completed in reverse apply order.",
            json: json
          )
        }
      } catch let error as UnifiedSetupInterruptionError {
        throw error
      } catch {
        return try result(
          outcome: "recovery_required",
          mutated: true,
          dryRun: false,
          plan: nil,
          message: String(describing: error),
          json: json
        )
      }
    }

    let preparation: UnifiedSetupPreparation
    do {
      preparation = try planner.prepare(context: context)
    } catch {
      return try result(
        outcome: "blocked",
        mutated: false,
        dryRun: dryRun,
        plan: nil,
        message: "Setup teardown preflight failed: \(error)",
        json: json
      )
    }
    guard case .ready(let model, let plan) = preparation else {
      return try result(
        outcome: preparation.report.outcome,
        mutated: false,
        dryRun: dryRun,
        plan: preparation.report,
        message: "The unified setup plan is blocked.",
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
        dryRun: dryRun,
        plan: plan,
        message: String(describing: error),
        json: json
      )
    }

    let environmentPreview: UnifiedSetupTeardownStage
    let desktopPreview: UnifiedSetupTeardownStage
    let themePreview: UnifiedSetupTeardownStage
    do {
      environmentPreview = try stage(
        await environmentTeardown(context, consumerPaths, true),
        dryRun: true
      )
      guard environmentPreview.succeeded else {
        return try result(
          outcome: "blocked",
          mutated: false,
          dryRun: dryRun,
          plan: plan,
          environment: environmentPreview,
          message: "Environment teardown preflight is blocked.",
          json: json
        )
      }
      desktopPreview = try stage(
        await desktopTeardown(context, consumerPaths, true),
        dryRun: true
      )
      guard desktopPreview.succeeded else {
        return try result(
          outcome: "blocked",
          mutated: false,
          dryRun: dryRun,
          plan: plan,
          environment: environmentPreview,
          desktop: desktopPreview,
          message: "Desktop teardown preflight is blocked.",
          json: json
        )
      }
      themePreview = try await themeTeardown(
        context.stateRoot,
        ownership,
        model.themePackage.appearance,
        true
      )
      guard themePreview.succeeded else {
        return try result(
          outcome: "blocked",
          mutated: false,
          dryRun: dryRun,
          plan: plan,
          environment: environmentPreview,
          desktop: desktopPreview,
          theme: themePreview,
          message: "Theme teardown preflight is blocked.",
          json: json
        )
      }
    } catch {
      return try result(
        outcome: "blocked",
        mutated: false,
        dryRun: dryRun,
        plan: plan,
        message: "Setup teardown preflight failed: \(error)",
        json: json
      )
    }

    if dryRun {
      let planned = [environmentPreview, desktopPreview, themePreview].contains {
        $0.outcome == "planned"
      }
      return try result(
        outcome: planned ? "planned" : "no_change",
        mutated: false,
        dryRun: true,
        plan: plan,
        environment: environmentPreview,
        desktop: desktopPreview,
        theme: themePreview,
        message: planned
          ? "Reverse-order teardown is ready; Homebrew packages remain externally owned."
          : "No Macarchy-owned core lifecycle state exists.",
        json: json
      )
    }

    let stages: [UnifiedSetupTransactionStage] = [
      environmentPreview.outcome == "planned" ? .environment : nil,
      desktopPreview.outcome == "planned" ? .desktop : nil,
      themePreview.outcome == "planned" ? .theme : nil,
    ].compactMap { $0 }
    guard !stages.isEmpty else {
      return try result(
        outcome: "no_change",
        mutated: false,
        dryRun: false,
        plan: plan,
        environment: environmentPreview,
        desktop: desktopPreview,
        theme: themePreview,
        message: "No Macarchy-owned core lifecycle state exists.",
        json: json
      )
    }
    let transaction = UnifiedSetupTransaction(
      operation: .teardown,
      stages: stages,
      desiredAppearance: model.themePackage.appearance,
      contextDigest: unifiedSetupContextDigest(context: context, consumerPaths: consumerPaths)
    )
    do {
      let recovery = try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        let store = UnifiedSetupTransactionStore(stateRoot: context.stateRoot)
        guard try store.read() == nil else {
          throw UnifiedSetupTransactionError.recoveryRequired(
            "another unified setup operation started after preflight"
          )
        }
        try store.write(transaction)
        return try await recover(
          transaction: transaction,
          context: context,
          consumerPaths: consumerPaths
        )
      }
      return try result(
        outcome: "restored",
        mutated: recovery.mutated,
        dryRun: false,
        plan: plan,
        environment: recovery.environment ?? environmentPreview,
        desktop: recovery.desktop ?? desktopPreview,
        theme: recovery.theme ?? themePreview,
        message:
          "Restored the setup-owned core in reverse order; Homebrew packages were retained.",
        json: json
      )
    } catch let error as UnifiedSetupInterruptionError {
      throw error
    } catch {
      return try result(
        outcome: "recovery_required",
        mutated: true,
        dryRun: false,
        plan: plan,
        message: String(describing: error),
        json: json
      )
    }
  }

  func recover(
    transaction: UnifiedSetupTransaction,
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths
  ) async throws -> UnifiedSetupRecoveryResult {
    guard
      transaction.contextDigest
        == unifiedSetupContextDigest(context: context, consumerPaths: consumerPaths)
    else {
      throw UnifiedSetupTransactionError.recoveryRequired(
        "the home or consumer paths differ from the interrupted operation"
      )
    }
    let store = UnifiedSetupTransactionStore(stateRoot: context.stateRoot)
    if transaction.phase == .committing {
      try store.remove()
      return UnifiedSetupRecoveryResult()
    }

    let stages: [UnifiedSetupTransactionStage] =
      transaction.operation == .apply
      ? Array(transaction.stages.reversed())
      : transaction.stages
    for stageID in stages {
      let preview = try await run(
        stageID,
        context: context,
        consumerPaths: consumerPaths,
        desiredAppearance: transaction.desiredAppearance,
        dryRun: true
      )
      guard preview.succeeded else {
        throw UnifiedSetupTransactionError.recoveryRequired(
          "\(stageID.rawValue) preflight failed: \(preview.message)"
        )
      }
    }

    var result = UnifiedSetupRecoveryResult()
    var remaining = transaction.stages
    for stageID in stages {
      let execution = try await run(
        stageID,
        context: context,
        consumerPaths: consumerPaths,
        desiredAppearance: transaction.desiredAppearance,
        dryRun: false
      )
      guard execution.succeeded else {
        throw UnifiedSetupTransactionError.recoveryRequired(
          "\(stageID.rawValue) recovery failed: \(execution.message)"
        )
      }
      result.record(execution, for: stageID)
      if transaction.operation == .teardown {
        switch stageID {
        case .environment: try faultInjector(.environmentTornDown)
        case .desktop: try faultInjector(.desktopTornDown)
        case .theme: try faultInjector(.themeTornDown)
        }
      }
      remaining.removeAll { $0 == stageID }
      try store.write(transaction.replacing(stages: remaining))
    }
    try store.write(transaction.replacing(phase: .committing, stages: []))
    try store.remove()
    return result
  }

  private func run(
    _ stageID: UnifiedSetupTransactionStage,
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    desiredAppearance: ThemeAppearance,
    dryRun: Bool
  ) async throws -> UnifiedSetupTeardownStage {
    switch stageID {
    case .environment:
      return try stage(
        await environmentTeardown(context, consumerPaths, dryRun),
        dryRun: dryRun
      )
    case .desktop:
      return try stage(
        await desktopTeardown(context, consumerPaths, dryRun),
        dryRun: dryRun
      )
    case .theme:
      return try await themeTeardown(
        context.stateRoot,
        SetupCoreOwnershipStore(stateRoot: context.stateRoot).read(),
        desiredAppearance,
        dryRun
      )
    }
  }

  private func stage(
    _ execution: SetupComponentExecution,
    dryRun: Bool
  ) throws -> UnifiedSetupTeardownStage {
    let mutated: Bool
    if let value = execution.report["mutated"] {
      guard case .bool(let decoded) = value else {
        throw SetupComponentReportError(description: "Delegated teardown mutation is invalid.")
      }
      mutated = decoded
    } else if dryRun {
      mutated = false
    } else {
      throw SetupComponentReportError(description: "Delegated teardown has no mutation field.")
    }
    return UnifiedSetupTeardownStage(
      succeeded: execution.succeeded,
      mutated: mutated,
      outcome: dryRun && execution.outcome == "ready" ? "planned" : execution.outcome,
      message: execution.report["message"]?.string ?? "Delegated teardown completed.",
      details: execution.report
    )
  }

  private func result(
    outcome: String,
    mutated: Bool,
    dryRun: Bool,
    plan: UnifiedSetupPlanReport?,
    environment: UnifiedSetupTeardownStage? = nil,
    desktop: UnifiedSetupTeardownStage? = nil,
    theme: UnifiedSetupTeardownStage? = nil,
    message: String,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report = UnifiedSetupTeardownReport(
      outcome: outcome,
      mutated: mutated,
      dryRun: dryRun,
      plan: plan,
      environment: environment,
      desktop: desktop,
      theme: theme,
      packages: "retained_external",
      message: message
    )
    return (try report.render(json: json), report.succeeded)
  }
}

struct UnifiedSetupTeardownStage: Encodable, Sendable {
  let succeeded: Bool
  let mutated: Bool
  let outcome: String
  let message: String
  let details: JSONValue?

  static func noChange(_ message: String) -> Self {
    Self(succeeded: true, mutated: false, outcome: "no_change", message: message, details: nil)
  }
}

private struct UnifiedSetupTeardownReport: Encodable {
  let schemaVersion = 1
  let operation = "setup_teardown"
  let outcome: String
  let mutated: Bool
  let dryRun: Bool
  let plan: UnifiedSetupPlanReport?
  let environment: UnifiedSetupTeardownStage?
  let desktop: UnifiedSetupTeardownStage?
  let theme: UnifiedSetupTeardownStage?
  let packages: String
  let message: String

  var succeeded: Bool { ["planned", "restored", "no_change"].contains(outcome) }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy setup teardown [\(outcome)]:",
      "- mutated: \(mutated ? "yes" : "no")",
      "- packages: \(packages)",
      "- \(message)",
    ]
    if let environment {
      lines.append("- environment [\(environment.outcome)]: \(environment.message)")
    }
    if let desktop { lines.append("- desktop [\(desktop.outcome)]: \(desktop.message)") }
    if let theme { lines.append("- theme [\(theme.outcome)]: \(theme.message)") }
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, mutated
    case dryRun = "dry_run"
    case plan, environment, desktop, theme, packages, message
  }
}
