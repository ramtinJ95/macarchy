import Foundation
import ThemeCore

struct ReconcileCommandRunner: Sendable {
  let preview:
    @Sendable ([String], URL, ThemeConsumerPaths) throws -> (
      manifest: GenerationManifest, inspections: [AdapterInspection]
    )
  let reconcile:
    @Sendable ([String], URL, ThemeConsumerPaths) async throws -> (
      manifest: GenerationManifest, record: ReconciliationRecord
    )

  static let live = ReconcileCommandRunner(
    preview: { adapterIDs, stateRoot, consumerPaths in
      try ThemeActivationCoordinator(
        root: stateRoot,
        consumerPaths: consumerPaths,
        enabledAdapterIDs: try ThemeRuntimeSelection.enabledAdapterIDs(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths
        ),
        piSelectionIsApplied: {
          try ThemeRuntimeSelection.piIsEnabled(
            stateRoot: stateRoot,
            consumerPaths: consumerPaths
          )
        },
        piThemeLinkRefreshIsAllowed: {
          try ThemeRuntimeSelection.piThemeLinkRefreshIsAllowed(
            stateRoot: stateRoot,
            consumerPaths: consumerPaths
          )
        }
      ).previewReconciliation(adapterIDs)
    },
    reconcile: { adapterIDs, stateRoot, consumerPaths in
      try await ThemeActivationCoordinator(
        root: stateRoot,
        consumerPaths: consumerPaths,
        enabledAdapterIDs: try ThemeRuntimeSelection.enabledAdapterIDs(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths
        ),
        piSelectionIsApplied: {
          try ThemeRuntimeSelection.piIsEnabled(
            stateRoot: stateRoot,
            consumerPaths: consumerPaths
          )
        },
        piThemeLinkRefreshIsAllowed: {
          try ThemeRuntimeSelection.piThemeLinkRefreshIsAllowed(
            stateRoot: stateRoot,
            consumerPaths: consumerPaths
          )
        }
      ).reconcile(adapterIDs: adapterIDs)
    }
  )

  func execute(
    adapterIDs: [String],
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let report: ReconcileReport
    do {
      if dryRun {
        let preview = try preview(adapterIDs, stateRoot, consumerPaths)
        report = .preview(
          manifest: preview.manifest,
          inspections: preview.inspections
        )
      } else {
        let result = try await reconcile(adapterIDs, stateRoot, consumerPaths)
        report = .completed(manifest: result.manifest, record: result.record)
      }
    } catch let error as ReconciliationPersistenceError {
      report = .persistenceFailure(error)
    } catch {
      report = .failure(dryRun: dryRun, error: String(describing: error))
    }
    return (try report.render(json: json), report.succeeded)
  }
}
