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
        outcome: "blocked",
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

    var mutated = false
    let environment: UnifiedSetupTeardownStage
    do {
      environment = try stage(
        await environmentTeardown(context, consumerPaths, false),
        dryRun: false
      )
    } catch {
      return try result(
        outcome: "failed",
        mutated: true,
        dryRun: false,
        plan: plan,
        message: "Environment teardown failed before a result was available: \(error)",
        json: json
      )
    }
    mutated = environment.mutated
    guard environment.succeeded else {
      return try result(
        outcome: "failed",
        mutated: mutated,
        dryRun: false,
        plan: plan,
        environment: environment,
        message: "Environment teardown did not converge; later stages were not run.",
        json: json
      )
    }

    let desktop: UnifiedSetupTeardownStage
    do {
      desktop = try stage(
        await desktopTeardown(context, consumerPaths, false),
        dryRun: false
      )
    } catch {
      return try result(
        outcome: "failed",
        mutated: true,
        dryRun: false,
        plan: plan,
        environment: environment,
        message: "Desktop teardown failed before a result was available: \(error)",
        json: json
      )
    }
    mutated = mutated || desktop.mutated
    guard desktop.succeeded else {
      return try result(
        outcome: "failed",
        mutated: mutated,
        dryRun: false,
        plan: plan,
        environment: environment,
        desktop: desktop,
        message: "Desktop teardown did not converge; theme teardown was not run.",
        json: json
      )
    }

    let theme: UnifiedSetupTeardownStage
    do {
      theme = try await themeTeardown(
        context.stateRoot,
        ownership,
        model.themePackage.appearance,
        false
      )
    } catch {
      return try result(
        outcome: "failed",
        mutated: true,
        dryRun: false,
        plan: plan,
        environment: environment,
        desktop: desktop,
        message: "Theme teardown failed: \(error)",
        json: json
      )
    }
    mutated = mutated || theme.mutated
    guard theme.succeeded else {
      return try result(
        outcome: "failed",
        mutated: mutated,
        dryRun: false,
        plan: plan,
        environment: environment,
        desktop: desktop,
        theme: theme,
        message: "Theme teardown requires recovery.",
        json: json
      )
    }

    return try result(
      outcome: mutated ? "restored" : "no_change",
      mutated: mutated,
      dryRun: false,
      plan: plan,
      environment: environment,
      desktop: desktop,
      theme: theme,
      message: mutated
        ? "Restored the setup-owned core in reverse order; Homebrew packages were retained."
        : "No Macarchy-owned core lifecycle state exists.",
      json: json
    )
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
      outcome: execution.outcome,
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
