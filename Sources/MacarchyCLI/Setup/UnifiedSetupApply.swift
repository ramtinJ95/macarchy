import Foundation
import ThemeCore

struct UnifiedSetupApplyCommandRunner: Sendable {
  typealias ComponentApply =
    @Sendable (UnifiedSetupPlanContext, PortableProfile, ThemeConsumerPaths) async throws
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
    desktopApply: { context, profile, consumerPaths in
      try await SetupComponentExecution(
        DesktopApplyCommandRunner.live.executeAggregate(
          resourcesRoot: context.desktopResourcesRoot,
          keybindingsResourcesRoot: context.keybindingsResourcesRoot,
          profileURL: context.profileURL,
          profileRequired: context.profileRequired,
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          consumerPaths: consumerPaths,
          adopt: nil,
          keybindingsAdopt: nil,
          json: true,
          profile: profile
        )
      )
    },
    environmentApply: { context, profile, consumerPaths in
      try await SetupComponentExecution(
        EnvironmentApplyCommandRunner.live.execute(
          resourcesRoot: context.environmentResourcesRoot,
          profileURL: context.profileURL,
          profileRequired: context.profileRequired,
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          consumerPaths: consumerPaths,
          adopt: nil,
          json: true,
          profile: profile
        )
      )
    }
  )

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    installDependencies: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
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
        outcome: "blocked",
        mutated: false,
        plan: preparation.report,
        message: "The unified setup plan is blocked.",
        json: json
      )
    }
    guard plan.adoption.isEmpty else {
      return try result(
        outcome: "blocked",
        mutated: false,
        plan: plan,
        message: "Existing state requires adoption; unified adoption is added in M4 Slice 3.",
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

    let packages = install(model.packages)
    guard packages.succeeded else {
      return try result(
        outcome: "failed",
        mutated: packages.mutated,
        plan: plan,
        packages: packages,
        message: packages.message,
        json: json
      )
    }
    let unresolved = DependencyProfile.personal(homeDirectory: context.homeDirectory)
      .selectedForSetup(model.profile)
      .filter { !capabilityIsAvailable($0) }
      .map(\.id)
    guard unresolved.isEmpty else {
      return try result(
        outcome: "failed",
        mutated: packages.mutated,
        plan: plan,
        packages: packages,
        message: "Selected capabilities remain missing: \(unresolved.joined(separator: ", ")).",
        json: json
      )
    }

    var mutated = packages.mutated
    let theme: UnifiedSetupApplyStage
    if model.theme.status == "activation_required" {
      do {
        theme = try stage(
          await themeApply(model.themePackage, context.stateRoot),
          mutationField: "committed",
          successMessage: "The curated default theme is active."
        )
      } catch {
        return try result(
          outcome: "failed",
          mutated: true,
          plan: plan,
          packages: packages,
          message: "Theme activation failed before a result was available: \(error)",
          json: json
        )
      }
      mutated = mutated || theme.mutated
      guard theme.succeeded else {
        return try result(
          outcome: "failed",
          mutated: mutated,
          plan: plan,
          packages: packages,
          theme: theme,
          message: "Theme activation did not converge.",
          json: json
        )
      }
    } else {
      theme = .noChange("Preserved active theme '\(model.theme.id)'.")
    }

    let desktop: UnifiedSetupApplyStage
    do {
      desktop = try stage(
        await desktopApply(context, model.profile, consumerPaths),
        mutationField: "mutated",
        successMessage: "Desktop providers converged."
      )
    } catch {
      return try result(
        outcome: "failed",
        mutated: true,
        plan: plan,
        packages: packages,
        theme: theme,
        message: "Desktop apply failed before a result was available: \(error)",
        json: json
      )
    }
    mutated = mutated || desktop.mutated
    guard desktop.succeeded else {
      return try result(
        outcome: "failed",
        mutated: mutated,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        message: "Desktop apply did not converge; later stages were not run.",
        json: json
      )
    }

    let environment: UnifiedSetupApplyStage
    do {
      environment = try stage(
        await environmentApply(context, model.profile, consumerPaths),
        mutationField: "mutated",
        successMessage: "The daily tool environment converged."
      )
    } catch {
      return try result(
        outcome: "failed",
        mutated: true,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        message: "Environment apply failed before a result was available: \(error)",
        json: json
      )
    }
    mutated = mutated || environment.mutated
    guard environment.succeeded else {
      return try result(
        outcome: "failed",
        mutated: mutated,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        environment: environment,
        message: "Environment apply did not converge.",
        json: json
      )
    }

    return try result(
      outcome: mutated ? "applied" : "no_change",
      mutated: mutated,
      plan: plan,
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
