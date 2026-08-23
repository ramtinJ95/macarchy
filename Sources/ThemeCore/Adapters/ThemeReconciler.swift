import Foundation

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
    adapters: [AdapterReconciliation]
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
    try Task.checkCancellation()
    return try statusStore.persist(manifest: manifest, results: results)
  }
}
