import Foundation
import ThemeCore

enum UnifiedSetupInspectionOperation: String, Sendable {
  case status = "setup_status"
  case doctor = "setup_doctor"
}

struct UnifiedSetupInspectionCommandRunner: Sendable {
  typealias ComponentInspection =
    @Sendable (
      UnifiedSetupInspectionOperation,
      UnifiedSetupPlanContext,
      PortableProfile,
      ThemeConsumerPaths
    ) throws
    -> SetupComponentExecution

  let planner: UnifiedSetupPlanCommandRunner
  let themeInspection: UnifiedSetupThemeInspection
  let desktopInspection: ComponentInspection
  let environmentInspection: ComponentInspection

  static let live = Self(
    planner: .live,
    themeInspection: UnifiedSetupThemeLifecycleStatus.inspect,
    desktopInspection: { operation, context, profile, consumerPaths in
      switch operation {
      case .status:
        return try SetupComponentExecution(
          DesktopStatusCommandRunner.live.execute(
            resourcesRoot: context.desktopResourcesRoot,
            keybindingsResourcesRoot: context.keybindingsResourcesRoot,
            profileURL: context.profileURL,
            profileRequired: context.profileRequired,
            stateRoot: context.stateRoot,
            homeDirectory: context.homeDirectory,
            json: true,
            consumerPaths: consumerPaths,
            profile: profile
          )
        )
      case .doctor:
        return try SetupComponentExecution(
          DesktopDoctorCommandRunner.live.execute(
            resourcesRoot: context.desktopResourcesRoot,
            keybindingsResourcesRoot: context.keybindingsResourcesRoot,
            profileURL: context.profileURL,
            profileRequired: context.profileRequired,
            stateRoot: context.stateRoot,
            homeDirectory: context.homeDirectory,
            consumerPaths: consumerPaths,
            json: true,
            profile: profile
          )
        )
      }
    },
    environmentInspection: { operation, context, profile, consumerPaths in
      switch operation {
      case .status:
        return try SetupComponentExecution(
          EnvironmentStatusCommandRunner.live.execute(
            resourcesRoot: context.environmentResourcesRoot,
            profileURL: context.profileURL,
            profileRequired: context.profileRequired,
            stateRoot: context.stateRoot,
            homeDirectory: context.homeDirectory,
            consumerPaths: consumerPaths,
            json: true,
            profile: profile
          )
        )
      case .doctor:
        return try SetupComponentExecution(
          EnvironmentDoctorCommandRunner.live.execute(
            resourcesRoot: context.environmentResourcesRoot,
            profileURL: context.profileURL,
            profileRequired: context.profileRequired,
            stateRoot: context.stateRoot,
            homeDirectory: context.homeDirectory,
            consumerPaths: consumerPaths,
            json: true,
            profile: profile
          )
        )
      }
    }
  )

  func execute(
    operation: UnifiedSetupInspectionOperation,
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let preparation: UnifiedSetupPreparation
    do {
      preparation = try planner.prepare(context: context)
    } catch {
      return try result(
        operation: operation,
        outcome: "blocked",
        plan: nil,
        theme: nil,
        message: "Setup inspection failed: \(error)",
        json: json
      )
    }
    let plan = planner.inspectedReport(preparation.report, context: context)
    guard case .ready(let model, _) = preparation else {
      return try result(
        operation: operation,
        outcome: preparation.report.outcome,
        plan: plan,
        theme: nil,
        message: "The unified setup plan is blocked.",
        json: json
      )
    }

    let ownership: SetupCoreOwnership?
    do {
      ownership = try SetupCoreOwnershipStore(stateRoot: context.stateRoot).read()
    } catch {
      return try result(
        operation: operation,
        outcome: "blocked",
        plan: plan,
        theme: nil,
        message: String(describing: error),
        json: json
      )
    }
    let theme = themeInspection(model, ownership, context.stateRoot)
    guard theme.succeeded else {
      return try result(
        operation: operation,
        outcome: "blocked",
        plan: plan,
        theme: theme,
        message: theme.message,
        json: json
      )
    }

    let missing = model.capabilities.filter { $0.status == .missing }.map(\.id)
    if model.theme.status == "activation_required", ownership == nil, plan.adoption.isEmpty,
      missing.isEmpty
    {
      return try result(
        operation: operation,
        outcome: "absent",
        plan: plan,
        theme: theme,
        message: "No Macarchy-owned core lifecycle state exists.",
        json: json
      )
    }

    let desktop: UnifiedSetupInspectionStage
    let environment: UnifiedSetupInspectionStage
    do {
      desktop = try stage(desktopInspection(operation, context, model.profile, consumerPaths))
      environment = try stage(
        environmentInspection(operation, context, model.profile, consumerPaths)
      )
    } catch {
      return try result(
        operation: operation,
        outcome: "blocked",
        plan: plan,
        theme: theme,
        message: "A delegated inspection returned an invalid result: \(error)",
        json: json
      )
    }

    let succeeded = desktop.succeeded && environment.succeeded && missing.isEmpty
    let outcome: String
    switch operation {
    case .status: outcome = succeeded ? "converged" : "drifted"
    case .doctor: outcome = succeeded ? "healthy" : "unhealthy"
    }
    let message =
      succeeded
      ? "The selected Macarchy core is converged."
      : [
        missing.isEmpty ? nil : "Missing capabilities: \(missing.joined(separator: ", ")).",
        desktop.succeeded ? nil : "Desktop inspection failed.",
        environment.succeeded ? nil : "Environment inspection failed.",
      ].compactMap { $0 }.joined(separator: " ")
    return try result(
      operation: operation,
      outcome: outcome,
      plan: plan,
      theme: theme,
      desktop: desktop,
      environment: environment,
      message: message,
      json: json
    )
  }

  private func stage(_ execution: SetupComponentExecution) -> UnifiedSetupInspectionStage {
    return UnifiedSetupInspectionStage(
      succeeded: execution.succeeded,
      outcome: execution.outcome,
      details: execution.report
    )
  }

  private func result(
    operation: UnifiedSetupInspectionOperation,
    outcome: String,
    plan: UnifiedSetupPlanReport?,
    theme: UnifiedSetupThemeLifecycleStatus?,
    desktop: UnifiedSetupInspectionStage? = nil,
    environment: UnifiedSetupInspectionStage? = nil,
    message: String,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report = UnifiedSetupInspectionReport(
      operation: operation.rawValue,
      outcome: outcome,
      plan: plan,
      theme: theme,
      desktop: desktop,
      environment: environment,
      message: message
    )
    return (try report.render(json: json), report.succeeded)
  }
}

struct UnifiedSetupInspectionStage: Encodable, Sendable {
  let succeeded: Bool
  let outcome: String
  let details: JSONValue
}

private struct UnifiedSetupInspectionReport: Encodable {
  let schemaVersion = 1
  let operation: String
  let outcome: String
  let plan: UnifiedSetupPlanReport?
  let theme: UnifiedSetupThemeLifecycleStatus?
  let desktop: UnifiedSetupInspectionStage?
  let environment: UnifiedSetupInspectionStage?
  let message: String

  var succeeded: Bool {
    ["converged", "healthy", "absent"].contains(outcome)
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = ["Macarchy \(operation.replacingOccurrences(of: "_", with: " ")) [\(outcome)]:"]
    lines.append("- \(message)")
    if let theme { lines.append("- theme [\(theme.status)]: \(theme.message)") }
    if let desktop { lines.append("- desktop [\(desktop.outcome)]") }
    if let environment { lines.append("- environment [\(environment.outcome)]") }
    if let inventory = plan?.packageInventory { lines.append(inventory.humanOutput) }
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, plan, theme, desktop, environment, message
  }
}
