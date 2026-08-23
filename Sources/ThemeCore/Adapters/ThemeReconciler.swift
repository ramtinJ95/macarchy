import Foundation

package enum AdapterInspectionStatus: String, Sendable {
  case ready
  case drifted
  case failed
}

package struct AdapterInspection: Sendable {
  package let adapterID: String
  package let requirement: AdapterRequirement
  package let status: AdapterInspectionStatus
  package let message: String?

  package init(
    adapterID: String,
    requirement: AdapterRequirement,
    status: AdapterInspectionStatus = .ready,
    message: String? = nil
  ) {
    self.adapterID = adapterID
    self.requirement = requirement
    self.status = status
    self.message = message
  }
}

package struct ReconciliationPersistenceError: Error, CustomStringConvertible, Sendable {
  package let manifest: GenerationManifest
  package let results: [AdapterResult]
  package let cause: String

  package var description: String {
    "Adapters ran for generation '\(manifest.generationID)', but reconciliation status could not be persisted: \(cause)"
  }
}

struct AdapterOutcome: Sendable {
  let status: AdapterStatus
  let message: String?

  init(status: AdapterStatus, message: String? = nil) {
    self.status = status
    self.message = message
  }
}

struct AdapterReconciliation: Sendable {
  let id: String
  let requirement: AdapterRequirement
  let run: @Sendable () async throws -> AdapterOutcome
}

struct ThemeReconciler: Sendable {
  let statusStore: ReconciliationStatusStore

  func reconcile(
    manifest: GenerationManifest,
    adapters: [AdapterReconciliation],
    preserving preservedResults: [AdapterResult] = []
  ) async throws -> ReconciliationRecord {
    guard Set(adapters.map(\.id)).count == adapters.count else {
      throw ReconciliationStatusError.duplicateAdapterID
    }
    let results = try await withThrowingTaskGroup(of: AdapterResult.self) { group in
      for adapter in adapters {
        group.addTask {
          do {
            try Task.checkCancellation()
            let outcome = try await adapter.run()
            try Task.checkCancellation()
            return AdapterResult(
              adapterID: adapter.id,
              requirement: adapter.requirement,
              status: outcome.status,
              message: outcome.message
            )
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            return AdapterResult(
              adapterID: adapter.id,
              requirement: adapter.requirement,
              status: .failed,
              message: String(describing: error)
            )
          }
        }
      }

      var results = [AdapterResult]()
      for try await result in group {
        results.append(result)
      }
      return results
    }
    let selectedIDs = Set(adapters.map(\.id))
    let combinedResults = preservedResults.filter { !selectedIDs.contains($0.adapterID) } + results
    do {
      try Task.checkCancellation()
      return try statusStore.persist(manifest: manifest, results: combinedResults)
    } catch {
      throw ReconciliationPersistenceError(
        manifest: manifest,
        results: combinedResults.sorted { $0.adapterID < $1.adapterID },
        cause: String(describing: error)
      )
    }
  }
}
