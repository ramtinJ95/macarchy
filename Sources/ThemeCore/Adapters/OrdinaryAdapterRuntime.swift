struct OrdinaryAdapterRuntime: Sendable {
  let adapterID: String
  let requirement: AdapterRequirement
  let preflight: @Sendable () throws -> Void
  let isIntegrationDrift: @Sendable (any Error) -> Bool

  func inspection(readyMessage: String? = nil) -> AdapterInspection {
    do {
      try preflight()
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

  func reconciliation(
    _ reconcile: @escaping @Sendable () async throws -> AdapterOutcome
  ) -> AdapterReconciliation {
    AdapterReconciliation(id: adapterID, requirement: requirement) {
      do {
        try preflight()
      } catch {
        return AdapterOutcome(
          status: isIntegrationDrift(error) ? .drifted : .failed,
          message: String(describing: error)
        )
      }
      return try await reconcile()
    }
  }

}
