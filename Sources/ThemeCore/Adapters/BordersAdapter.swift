import Foundation

/// Applied-environment authority is supplied by the CLI, never inferred from an
/// edited profile or from the presence of a native singleton.
package struct BordersManagedMode: Sendable {
  package let preflight: @Sendable () throws -> Void
  package let inspect: @Sendable () throws -> String
  package let reconcile: @Sendable () throws -> String

  package init(
    preflight: @escaping @Sendable () throws -> Void,
    inspect: @escaping @Sendable () throws -> String,
    reconcile: @escaping @Sendable () throws -> String
  ) {
    self.preflight = preflight
    self.inspect = inspect
    self.reconcile = reconcile
  }
}

package struct BordersAdapter: Sendable {
  package static let id = "borders"
  let managedMode: BordersManagedMode?

  private func mode() throws -> BordersManagedMode {
    guard let managedMode else {
      throw BordersServiceError.blocked(
        "no applied focus-ring ownership; review setup plan and apply first")
    }
    return managedMode
  }

  func preflight() throws { try mode().preflight() }

  func inspection() -> AdapterInspection {
    do {
      return AdapterInspection(
        adapterID: Self.id, requirement: .required, message: try mode().inspect())
    } catch {
      return AdapterInspection(
        adapterID: Self.id, requirement: .required, status: .failed,
        message: String(describing: error))
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .required) {
      do {
        return AdapterOutcome(status: .applied, message: try mode().reconcile())
      } catch {
        return AdapterOutcome(status: .failed, message: String(describing: error))
      }
    }
  }
}
