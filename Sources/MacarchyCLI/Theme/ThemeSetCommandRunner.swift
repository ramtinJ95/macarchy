import Foundation
import ThemeCore

struct ThemeSetCommandRunner: Sendable {
  let preflight: @Sendable (ThemePackage, String?, URL, ThemeConsumerPaths) throws -> Void
  let activate:
    @Sendable (ThemePackage, String?, URL, ThemeConsumerPaths, String?) async throws
      -> ThemeActivationResult
  var slackIsEnabled: @Sendable (URL) throws -> Bool = { _ in true }

  static let live = ThemeSetCommandRunner(
    preflight: { package, backgroundID, stateRoot, consumerPaths in
      try ThemeRuntimeSelection.activationCoordinator(
        stateRoot: stateRoot,
        consumerPaths: consumerPaths
      ).preflight(package: package, requestedBackgroundID: backgroundID)
    },
    activate: { package, backgroundID, stateRoot, consumerPaths, expectedActiveGenerationID in
      try await ThemeRuntimeSelection.activationCoordinator(
        stateRoot: stateRoot,
        consumerPaths: consumerPaths
      ).activate(
        package: package,
        expectedActiveGenerationID: expectedActiveGenerationID,
        requestedBackgroundID: backgroundID
      )
    },
    slackIsEnabled: { stateRoot in
      try ThemeRuntimeSelection.slackIsEnabled(stateRoot: stateRoot)
    }
  )

  func execute(
    repository: ThemeRepository,
    themeID: String,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    json: Bool,
    requestedBackgroundID: String? = nil
  ) async throws -> (output: String, succeeded: Bool) {
    let run: @Sendable () async throws -> (output: String, succeeded: Bool) = {
      let package = try repository.package(id: themeID)
      return try await execute(
        package: package,
        stateRoot: stateRoot,
        consumerPaths: consumerPaths,
        dryRun: dryRun,
        expectedActiveGenerationID: nil,
        json: json,
        requestedBackgroundID: requestedBackgroundID
      )
    }
    do {
      return try await withThemePackageLock(stateRoot: stateRoot, unlessDryRun: dryRun, run)
    } catch {
      let report = ThemeSetReport.precommitFailure(themeID: themeID, error: error)
      return (try report.render(json: json), report.succeeded)
    }
  }

  func execute(
    package: ThemePackage,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    expectedActiveGenerationID: String?,
    json: Bool,
    requestedBackgroundID: String? = nil
  ) async throws -> (output: String, succeeded: Bool) {
    let report = try await report(
      package: package,
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: dryRun,
      expectedActiveGenerationID: expectedActiveGenerationID,
      requestedBackgroundID: requestedBackgroundID
    )
    return (try report.render(json: json), report.succeeded)
  }

  func report(
    package: ThemePackage,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    expectedActiveGenerationID: String?,
    requestedBackgroundID: String? = nil
  ) async throws -> ThemeSetReport {
    if dryRun {
      do {
        try preflight(package, requestedBackgroundID, stateRoot, consumerPaths)
        return .dryRun(themeID: package.id)
      } catch {
        return .precommitFailure(themeID: package.id, error: error)
      }
    }
    let slackTheme = try slackIsEnabled(stateRoot) ? SlackAdapter.render(package: package) : nil
    let outcome = try await ThemeActivationOutcome.classify {
      try await activate(
        package,
        requestedBackgroundID,
        stateRoot,
        consumerPaths,
        expectedActiveGenerationID
      )
    }
    return ThemeSetReport(outcome, themeID: package.id, slackTheme: slackTheme)
  }
}

/// Runs `operation` under the theme package lock; dry runs never mutate, so they skip it.
func withThemePackageLock<Output: Sendable>(
  stateRoot: URL,
  unlessDryRun dryRun: Bool,
  _ operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
  if dryRun { return try await operation() }
  return try await ThemePackageLock(root: stateRoot).withLock(operation)
}

/// Repeats `attempt` while activation reports that the active generation changed under it.
func retryingActiveGenerationChanges<Output>(
  _ attempt: () async throws -> Output
) async throws -> Output {
  while true {
    do {
      return try await attempt()
    } catch ThemeActivationError.activeGenerationChanged {
      continue
    }
  }
}
