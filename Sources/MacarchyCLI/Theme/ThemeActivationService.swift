import Foundation
import ThemeCore

/// Canonical theme activation for `theme set`, `next`, `background` and `install`, the theme
/// browser and setup's theme refresh. Methods ending in `Locked` never take ThemePackageLock: the
/// caller holds it through `withThemePackageLock` for anything but a dry run (ADR-0052).
struct ThemeActivationService: Sendable {
  let preflight: @Sendable (ThemePackage, String?, URL, ThemeConsumerPaths) throws -> Void
  let activate:
    @Sendable (ThemePackage, String?, URL, ThemeConsumerPaths, String?) async throws
      -> ThemeActivationResult
  var slackIsEnabled: @Sendable (URL) throws -> Bool = { _ in true }

  static let live = coordinator(
    enabledAdapterIDs: nil,
    onCommittedLocked: { _ in },
    slackIsEnabled: { stateRoot in
      try ThemeRuntimeSelection.slackIsEnabled(stateRoot: stateRoot)
    }
  )

  /// Setup's theme refresh: reconciles only `enabledAdapterIDs`, runs `onCommittedLocked` under
  /// the activation lock right after the pointer swap, and never renders the Slack payload.
  static func reconciling(
    _ enabledAdapterIDs: Set<String>,
    onCommittedLocked: @escaping @Sendable (GenerationManifest) throws -> Void
  ) -> Self {
    coordinator(
      enabledAdapterIDs: enabledAdapterIDs,
      onCommittedLocked: onCommittedLocked,
      slackIsEnabled: { _ in false }
    )
  }

  private static func coordinator(
    enabledAdapterIDs: Set<String>?,
    onCommittedLocked: @escaping @Sendable (GenerationManifest) throws -> Void,
    slackIsEnabled: @escaping @Sendable (URL) throws -> Bool
  ) -> Self {
    Self(
      preflight: { package, backgroundID, stateRoot, consumerPaths in
        try ThemeRuntimeSelection.activationCoordinator(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          enabledAdapterIDs: enabledAdapterIDs
        ).preflight(package: package, requestedBackgroundID: backgroundID)
      },
      activate: { package, backgroundID, stateRoot, consumerPaths, expectedActiveGenerationID in
        try await ThemeRuntimeSelection.activationCoordinator(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          enabledAdapterIDs: enabledAdapterIDs
        ).activate(
          package: package,
          expectedActiveGenerationID: expectedActiveGenerationID,
          requestedBackgroundID: backgroundID,
          onCommittedLocked: onCommittedLocked
        )
      },
      slackIsEnabled: slackIsEnabled
    )
  }

  /// `theme set`: takes ThemePackageLock unless `dryRun`, then activates `themeID`.
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
      return try await executeLocked(
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

  func executeLocked(
    package: ThemePackage,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    expectedActiveGenerationID: String?,
    json: Bool,
    requestedBackgroundID: String? = nil
  ) async throws -> (output: String, succeeded: Bool) {
    try await reportLocked(
      package: package,
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: dryRun,
      expectedActiveGenerationID: expectedActiveGenerationID,
      requestedBackgroundID: requestedBackgroundID
    ).execution(json: json)
  }

  /// Preflights `package` for a dry run, otherwise activates it, reported as `theme set`.
  func reportLocked(
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
    let outcome = try await activateLocked(
      package: package,
      backgroundID: requestedBackgroundID,
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      expectedActiveGenerationID: expectedActiveGenerationID
    )
    return ThemeSetReport(outcome, themeID: package.id, slackTheme: slackTheme)
  }

  func activateLocked(
    package: ThemePackage,
    backgroundID: String?,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    expectedActiveGenerationID: String?
  ) async throws -> ThemeActivationOutcome {
    try await ThemeActivationOutcome.classify {
      try await activate(
        package,
        backgroundID,
        stateRoot,
        consumerPaths,
        expectedActiveGenerationID
      )
    }
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
