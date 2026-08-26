import Dispatch
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

package struct ReconciliationInterruptedError: Error, CustomStringConvertible, Sendable {
  package let manifest: GenerationManifest
  package let results: [AdapterResult]
  package let statusPersisted: Bool
  package let cause: String

  package var description: String {
    let status = statusPersisted ? "was persisted" : "was not persisted"
    return
      "Adapters ran for generation '\(manifest.generationID)' and status \(status), but reconciliation was interrupted: \(cause)"
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

final class BlockingTaskExecutor: TaskExecutor {
  private let queue: DispatchQueue

  init(label: String) {
    queue = DispatchQueue(
      label: label,
      qos: .utility,
      attributes: .concurrent
    )
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let executor = asUnownedTaskExecutor()
    queue.async {
      job.runSynchronously(on: executor)
    }
  }
}

enum ReconciliationCheckpoint: Sendable {
  case adaptersCompleted
  case statusPersisted
}

struct ThemeReconciler: Sendable {
  // Adapters call synchronous process and framework APIs; do not block Swift's cooperative pool.
  private static let adapterExecutor = BlockingTaskExecutor(
    label: "io.github.ramtinj95.macarchy.reconciliation"
  )

  let statusStore: ReconciliationStatusStore
  var faultInjector: @Sendable (ReconciliationCheckpoint) throws -> Void = { _ in }

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
        group.addTask(executorPreference: Self.adapterExecutor) {
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
    let sortedResults = combinedResults.sorted { $0.adapterID < $1.adapterID }
    do {
      try Task.checkCancellation()
      try faultInjector(.adaptersCompleted)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ReconciliationInterruptedError(
        manifest: manifest,
        results: sortedResults,
        statusPersisted: false,
        cause: String(describing: error)
      )
    }

    let record: ReconciliationRecord
    do {
      record = try statusStore.persist(manifest: manifest, results: combinedResults)
    } catch {
      throw ReconciliationPersistenceError(
        manifest: manifest,
        results: sortedResults,
        cause: String(describing: error)
      )
    }
    do {
      try faultInjector(.statusPersisted)
      return record
    } catch {
      throw ReconciliationInterruptedError(
        manifest: manifest,
        results: sortedResults,
        statusPersisted: true,
        cause: String(describing: error)
      )
    }
  }
}
