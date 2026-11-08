import Foundation
import ThemeCore

/// How far one canonical activation attempt got. Once the pointer swaps the commit stands, so
/// every committed case reports the new generation and is never rolled back (ADR-0052).
enum ThemeActivationOutcome {
  /// The pointer swapped and every adapter reported a result.
  case committed(ThemeActivationResult, requiredFailure: Bool)
  /// The pointer swapped, but postcommit activation work failed.
  case committedActivationError(manifest: GenerationManifest, cause: String)
  /// The pointer swapped, but reconciliation could not complete.
  case committedReconciliationError(manifest: GenerationManifest, cause: String)
  /// Canonical state is unchanged.
  case precommitFailure(any Error)

  /// Runs `attempt` and classifies its result. `ThemeActivationError.activeGenerationChanged`
  /// propagates so callers can retry against the generation that is now active.
  /// `requiredFailure` decides whether committed adapter results fail the operation.
  static func classify(
    requiredFailure: ([AdapterResult]) -> Bool = hasRequiredReconciliationFailure,
    _ attempt: () async throws -> ThemeActivationResult
  ) async throws -> Self {
    do {
      let result = try await attempt()
      return .committed(
        result,
        requiredFailure: requiredFailure(result.reconciliation.results)
      )
    } catch let error as ThemeCommittedActivationError {
      return .committedActivationError(manifest: error.manifest, cause: error.cause)
    } catch let error as ThemeCommittedWithReconciliationError {
      return .committedReconciliationError(manifest: error.manifest, cause: error.cause)
    } catch {
      if let error = error as? ThemeActivationError, case .activeGenerationChanged = error {
        throw error
      }
      return .precommitFailure(error)
    }
  }
}

extension ThemeActivationOutcome {
  /// The generation the pointer swapped to, or nil when canonical state is unchanged.
  var committedManifest: GenerationManifest? {
    switch self {
    case .committed(let result, _): result.manifest
    case .committedActivationError(let manifest, _),
      .committedReconciliationError(let manifest, _):
      manifest
    case .precommitFailure: nil
    }
  }

  /// The same outcome with `notice` reported after any notice it already has.
  func addingNotice(_ notice: String) -> Self {
    switch self {
    case .committed(let result, let requiredFailure):
      .committed(
        ThemeActivationResult(
          manifest: result.manifest,
          reconciliation: result.reconciliation,
          notice: [result.notice, notice].compactMap { $0 }.joined(separator: " ")
        ),
        requiredFailure: requiredFailure
      )
    case .committedActivationError(let manifest, let cause):
      .committedActivationError(manifest: manifest, cause: "\(cause) \(notice)")
    case .committedReconciliationError(let manifest, let cause):
      .committedReconciliationError(manifest: manifest, cause: "\(cause) \(notice)")
    case .precommitFailure:
      self
    }
  }
}
