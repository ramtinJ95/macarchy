import Foundation
import ThemeCore

/// Canonical theme activation for `theme set`, `next`, `background`, `install` and `undo`, the
/// theme browser and setup's theme refresh. Methods ending in `Locked` never take
/// ThemePackageLock: the caller holds it through `withThemePackageLock` for anything but a dry
/// run (ADR-0052), which also serializes the history writes that follow each commit.
struct ThemeActivationService: Sendable {
  /// Plans an activation without writing: a dry run's report, and the check a reviewed apply
  /// repeats under the lock.
  let review:
    @Sendable (ThemePackage, String?, URL, ThemeConsumerPaths) throws -> ThemeActivationReview
  let activate:
    @Sendable (ThemePackage, String?, URL, ThemeConsumerPaths, String?) async throws
      -> ThemeActivationResult
  var slackIsEnabled: @Sendable (URL) throws -> Bool = { _ in true }
  /// Records committed activations for `theme undo`; nil keeps no history.
  var history: ThemeHistoryRecorder? = nil

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
      review: { package, backgroundID, stateRoot, consumerPaths in
        try ThemeRuntimeSelection.activationCoordinator(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          enabledAdapterIDs: enabledAdapterIDs
        ).review(package: package, requestedBackgroundID: backgroundID)
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
      slackIsEnabled: slackIsEnabled,
      history: .live
    )
  }

  /// `theme set`: takes ThemePackageLock unless `dryRun`, then activates `themeID`. With
  /// `reviewedDigest` it first plans again under the lock and activates only while that plan is
  /// the one reviewed and the reviewed generation is still active.
  func execute(
    repository: ThemeRepository,
    themeID: String,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    json: Bool,
    requestedBackgroundID: String? = nil,
    reviewedDigest: String? = nil
  ) async throws -> CommandExecution {
    let run: @Sendable () async throws -> CommandExecution = {
      let package = try repository.package(id: themeID)
      var expectedActiveGenerationID: String?
      if let reviewedDigest {
        let current = try review(package, requestedBackgroundID, stateRoot, consumerPaths)
        guard current.digest == reviewedDigest else { throw ThemeActivationReviewError.stale }
        guard current.canApply else {
          throw ThemeActivationReviewError.blocked(current.failedConsumerIDs)
        }
        expectedActiveGenerationID = current.activeGenerationID
      }
      return try await executeLocked(
        package: package,
        stateRoot: stateRoot,
        consumerPaths: consumerPaths,
        dryRun: dryRun,
        expectedActiveGenerationID: expectedActiveGenerationID,
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
    requestedBackgroundID: String? = nil,
    historyUpdate: ThemeHistoryUpdate = .record
  ) async throws -> CommandExecution {
    try await reportLocked(
      package: package,
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: dryRun,
      expectedActiveGenerationID: expectedActiveGenerationID,
      requestedBackgroundID: requestedBackgroundID,
      historyUpdate: historyUpdate
    ).execution(json: json)
  }

  /// Plans `package` for a dry run, otherwise activates it, reported as `theme set`.
  func reportLocked(
    package: ThemePackage,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    expectedActiveGenerationID: String?,
    requestedBackgroundID: String? = nil,
    historyUpdate: ThemeHistoryUpdate = .record
  ) async throws -> ThemeSetReport {
    if dryRun {
      do {
        return .dryRun(
          review: try review(package, requestedBackgroundID, stateRoot, consumerPaths),
          setReproduces: requestedBackgroundID == nil)
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
      expectedActiveGenerationID: expectedActiveGenerationID,
      historyUpdate: historyUpdate
    )
    return ThemeSetReport(outcome, themeID: package.id, slackTheme: slackTheme)
  }

  func activateLocked(
    package: ThemePackage,
    backgroundID: String?,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    expectedActiveGenerationID: String?,
    historyUpdate: ThemeHistoryUpdate = .record
  ) async throws -> ThemeActivationOutcome {
    let previous = history?.activeSelection(stateRoot: stateRoot)
    let outcome = try await ThemeActivationOutcome.classify {
      try await activate(
        package,
        backgroundID,
        stateRoot,
        consumerPaths,
        expectedActiveGenerationID
      )
    }
    guard let history, let previous else { return outcome }
    return history.record(outcome, previous: previous, update: historyUpdate, stateRoot: stateRoot)
  }
}

/// How a committed activation changes the theme history.
enum ThemeHistoryUpdate: Sendable {
  /// Add the committed selection after the one that was active before.
  case record
  /// `theme undo`: keep `remaining`, whose last entry, the selection being restored, is
  /// replaced by the committed one.
  case undo(remaining: [ThemeHistoryEntry])
}

/// Keeps `state/theme-history.json` in step with committed activations. History is evidence for
/// `theme undo`, never canonical state: a history failure becomes a notice on the committed
/// activation and never changes whether the activation succeeded.
struct ThemeHistoryRecorder: Sendable {
  let activeManifest: @Sendable (URL) throws -> GenerationManifest?
  let load: @Sendable (URL) throws -> [ThemeHistoryEntry]
  let persist: @Sendable ([ThemeHistoryEntry], URL) throws -> Void
  let now: @Sendable () -> String

  static let live = ThemeHistoryRecorder(
    activeManifest: { try ThemeGenerationReader(root: $0).activeManifestIfPresent() },
    load: { try ThemeHistoryStore(root: $0).load() },
    persist: { try ThemeHistoryStore(root: $1).persist($0) },
    now: { ISO8601DateFormatter().string(from: Date()) }
  )

  /// The selection active before an activation; read before it so the first recorded change
  /// can be undone too.
  func activeSelection(stateRoot: URL) -> Result<ThemeHistoryEntry?, any Error> {
    Result {
      try activeManifest(stateRoot).map { ThemeHistoryEntry(manifest: $0, recordedAt: now()) }
    }
  }

  func record(
    _ outcome: ThemeActivationOutcome,
    previous: Result<ThemeHistoryEntry?, any Error>,
    update: ThemeHistoryUpdate,
    stateRoot: URL
  ) -> ThemeActivationOutcome {
    guard let manifest = outcome.committedManifest else { return outcome }
    let committed = ThemeHistoryEntry(manifest: manifest, recordedAt: now())
    var notices: [String] = []
    let entries: [ThemeHistoryEntry]
    switch update {
    case .record:
      let existing: [ThemeHistoryEntry]
      do {
        existing = try load(stateRoot)
      } catch {
        existing = []
        notices.append("Theme history could not be read and was started again: \(error).")
      }
      let before: ThemeHistoryEntry?
      do {
        before = try previous.get()
      } catch {
        before = nil
        notices.append(
          "The previously active theme could not be read, so undo cannot return to it: \(error).")
      }
      entries = ThemeHistory.recording(existing, previous: before, committed: committed)
    case .undo(let remaining):
      // The restored entry becomes what actually committed, even when activation chose a
      // background for an entry that recorded none, so a later undo cannot return to it.
      entries = Array(remaining.dropLast()) + [committed]
    }
    do {
      try persist(entries, stateRoot)
    } catch {
      notices.append("Theme history was not updated, so undo may skip this change: \(error).")
    }
    return notices.isEmpty ? outcome : outcome.addingNotice(notices.joined(separator: " "))
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
