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
      let failure = preflightFailure(for: error)
      return AdapterInspection(
        adapterID: adapterID,
        requirement: requirement,
        status: failure.inspectionStatus,
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
        let failure = preflightFailure(for: error)
        return AdapterOutcome(
          status: failure.adapterStatus,
          message: String(describing: error)
        )
      }
      return try await reconcile()
    }
  }

  private func preflightFailure(for error: any Error) -> OrdinaryAdapterPreflightFailure {
    isIntegrationDrift(error) ? .drifted : .failed
  }
}

private enum OrdinaryAdapterPreflightFailure {
  // A preflight failure cannot be represented as ready, unsupported, or an update-policy result.
  case drifted
  case failed

  var inspectionStatus: AdapterInspectionStatus {
    switch self {
    case .drifted:
      .drifted
    case .failed:
      .failed
    }
  }

  var adapterStatus: AdapterStatus {
    switch self {
    case .drifted:
      .drifted
    case .failed:
      .failed
    }
  }
}
