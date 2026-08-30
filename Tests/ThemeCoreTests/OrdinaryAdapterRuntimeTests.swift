import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func ordinaryAdapterRuntimeMapsTypedPreflightFailuresAndSkipsConcreteWork() async throws {
    for isIntegrationDrift in [true, false] {
      let preflightCalls = Mutex(0)
      let concreteCalls = Mutex(0)
      let runtime = OrdinaryAdapterRuntime(
        adapterID: "ordinary",
        requirement: .required,
        preflight: {
          preflightCalls.withLock { $0 += 1 }
          throw ReconciliationTestError.expectedFailure
        },
        isIntegrationDrift: { _ in isIntegrationDrift }
      )

      let inspection = runtime.inspection(readyMessage: "must not escape")
      let outcome = try await runtime.reconciliation {
        concreteCalls.withLock { $0 += 1 }
        return AdapterOutcome(status: .applied)
      }.run()

      if isIntegrationDrift {
        #expect(inspection.status == .drifted)
        #expect(outcome.status == .drifted)
      } else {
        #expect(inspection.status == .failed)
        #expect(outcome.status == .failed)
      }
      #expect(inspection.message == "expectedFailure")
      #expect(outcome.message == "expectedFailure")
      #expect(preflightCalls.withLock { $0 } == 2)
      #expect(concreteCalls.withLock { $0 } == 0)
    }
  }

  @Test
  func ordinaryAdapterRuntimePassesThroughConcreteLifecycleOutcomesAndErrors() async throws {
    let runtime = OrdinaryAdapterRuntime(
      adapterID: "ordinary",
      requirement: .optional,
      preflight: {},
      isIntegrationDrift: { _ in true }
    )

    let inspection = runtime.inspection(readyMessage: "ready exactly")
    #expect(inspection.adapterID == "ordinary")
    #expect(inspection.requirement == .optional)
    #expect(inspection.status == .ready)
    #expect(inspection.message == "ready exactly")

    let reconciliation = runtime.reconciliation {
      AdapterOutcome(status: .restartRequired, message: "restart exactly")
    }
    #expect(reconciliation.id == "ordinary")
    #expect(reconciliation.requirement == .optional)
    let outcome = try await reconciliation.run()
    #expect(outcome.status == .restartRequired)
    #expect(outcome.message == "restart exactly")

    await #expect(throws: ReconciliationTestError.expectedInterruption) {
      try await runtime.reconciliation {
        throw ReconciliationTestError.expectedInterruption
      }.run()
    }
  }
}
