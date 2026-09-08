import Foundation
import ThemeCore

/// Recovery only: never starts a new apply or consumes adoption/package approval.
struct UnifiedSetupRecoveryCommandRunner: Sendable {
  let teardown: UnifiedSetupTeardownCommandRunner

  static let live = Self(teardown: .live)

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    acknowledgeUnverifiedSpicetify: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let report: UnifiedSetupRecoveryReport
    do {
      report = try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        try SetupPackageInstallationStore(context: context).requireResolved()
        guard
          let transaction = try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read()
        else {
          throw UnifiedSetupTransactionError.recoveryRequired("no unified transaction is pending")
        }
        guard
          transaction.contextDigest
            == unifiedSetupContextDigest(context: context, consumerPaths: consumerPaths)
        else {
          throw UnifiedSetupTransactionError.recoveryRequired(
            "the home or consumer paths differ from the interrupted operation")
        }
        if acknowledgeUnverifiedSpicetify {
          guard transaction.operation == .apply, transaction.phase == .mutating else {
            throw UnifiedSetupTransactionError.recoveryRequired(
              "Spicetify acknowledgment is only valid for an interrupted, uncommitted apply")
          }
          try acknowledgeSpicetify(
            context: context, environmentStageRecorded: transaction.stages.contains(.environment))
        }
        let recovery = try await teardown.recover(
          transaction: transaction, context: context, consumerPaths: consumerPaths)
        let unverified = try EnvironmentStateStore(stateRoot: context.stateRoot)
          .hasUnverifiedSpicetifyRecovery()
        return UnifiedSetupRecoveryReport(
          outcome: unverified ? "recovered_with_unverified_runtime" : "recovered",
          spicetifyRuntimeRestoration: unverified ? "unverified" : "not_deferred",
          message: "Interrupted setup recovery completed; review a fresh plan before applying."
            + (unverified ? " \(EnvironmentStateStore.spicetifyRecoveryMessage)" : ""),
          environment: recovery.environment, desktop: recovery.desktop, theme: recovery.theme,
          preferences: recovery.preferences)
      }
    } catch {
      let unverified = try? EnvironmentStateStore(stateRoot: context.stateRoot)
        .hasUnverifiedSpicetifyRecovery()
      report = UnifiedSetupRecoveryReport(
        outcome: "recovery_required",
        spicetifyRuntimeRestoration: unverified == true ? "unverified" : "unknown",
        message: String(describing: error)
          + (unverified == true ? " \(EnvironmentStateStore.spicetifyRecoveryMessage)" : ""),
        environment: nil, desktop: nil, theme: nil, preferences: nil)
    }
    return (try report.render(json: json), report.outcome != "recovery_required")
  }

  private func acknowledgeSpicetify(
    context: UnifiedSetupPlanContext, environmentStageRecorded: Bool
  ) throws {
    let lock = EnvironmentLifecycleLock(stateRoot: context.stateRoot)
    let descriptor = try lock.acquire()
    defer { lock.release(descriptor) }
    try ActivationLock(root: context.stateRoot).withLock {
      let store = EnvironmentStateStore(stateRoot: context.stateRoot)
      let pending = try store.readTransaction()
      // After interruption between domain stages, the durable warning survives its journal.
      if pending == nil, try store.hasUnverifiedSpicetifyRecovery() { return }
      guard environmentStageRecorded else {
        throw UnifiedSetupTransactionError.recoveryRequired(
          "the interrupted setup did not record an environment stage; refusing unrelated recovery")
      }
      try EnvironmentTransactionCoordinator(
        homeDirectory: context.homeDirectory, stateRoot: context.stateRoot
      ).deferOriginalSpicetifyRuntimeLocked()
    }
  }
}

private struct UnifiedSetupRecoveryReport: Encodable {
  let schemaVersion = 1
  let operation = "setup_recover"
  let outcome: String
  let spicetifyRuntimeRestoration: String
  let message: String
  let environment: UnifiedSetupTeardownStage?
  let desktop: UnifiedSetupTeardownStage?
  let theme: UnifiedSetupTeardownStage?
  let preferences: UnifiedSetupTeardownStage?

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    return "Macarchy setup recovery [\(outcome)]:\n- \(message)"
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case spicetifyRuntimeRestoration = "spicetify_runtime_restoration"
    case operation, outcome, message, environment, desktop, theme, preferences
  }
}
