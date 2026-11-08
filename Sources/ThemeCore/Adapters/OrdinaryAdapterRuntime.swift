struct OrdinaryAdapterRuntime: Sendable {
  let adapterID: String
  let requirement: AdapterRequirement
  let preflight: @Sendable () throws -> Void
  let isIntegrationDrift: @Sendable (any Error) -> Bool

  /// `verify` runs only after preflight passes; its errors are classified like preflight errors.
  func inspection(
    readyMessage: String?,
    verify: () throws -> Void = {}
  ) -> AdapterInspection {
    do {
      try preflight()
      try verify()
      return AdapterInspection(
        adapterID: adapterID,
        requirement: requirement,
        message: readyMessage
      )
    } catch {
      return AdapterInspection(
        adapterID: adapterID,
        requirement: requirement,
        status: isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
    }
  }

  /// The outcome a failed preflight reports, or nil when preflight passes.
  /// Adapters that hold a lock across preflight and their concrete work call this inside it.
  func preflightFailure() -> AdapterOutcome? {
    do {
      try preflight()
      return nil
    } catch {
      return AdapterOutcome(
        status: isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
    }
  }

  func reconciliation(
    _ reconcile: @escaping @Sendable () async throws -> AdapterOutcome
  ) -> AdapterReconciliation {
    AdapterReconciliation(id: adapterID, requirement: requirement) {
      if let failure = preflightFailure() { return failure }
      return try await reconcile()
    }
  }
}

extension OrdinaryAdapterRuntime {
  /// Stamps the consumer's catalog ID and requirement.
  init(
    _ consumer: RuntimeAdapterKind,
    preflight: @escaping @Sendable () throws -> Void,
    isIntegrationDrift: @escaping @Sendable (any Error) -> Bool
  ) {
    self.init(
      adapterID: consumer.adapterID,
      requirement: consumer.requirement,
      preflight: preflight,
      isIntegrationDrift: isIntegrationDrift
    )
  }
}
