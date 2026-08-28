import Foundation
import ThemeCore

struct ThemeStatusCommandRunner: Sendable {
  let read: @Sendable (URL) throws -> ThemeStatusSnapshot

  static let live = ThemeStatusCommandRunner(
    read: readThemeStatusSnapshot
  )

  func execute(
    stateRoot: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report: ThemeStatusReport
    do {
      let snapshot = try read(stateRoot)
      switch snapshot {
      case .state(let manifest, let reconciliation):
        report = .active(manifest: manifest, reconciliation: reconciliation)
      case .reconciliationFailure(let manifest, let error):
        report = .activeFailure(manifest: manifest, error: error)
      }
    } catch ReconciliationStatusError.noActiveGeneration {
      report = .inactive
    } catch {
      report = .failure(String(describing: error))
    }
    return (try report.render(json: json), report.succeeded)
  }
}

enum ThemeStatusSnapshot: Sendable {
  case state(manifest: GenerationManifest, reconciliation: ReconciliationState)
  case reconciliationFailure(manifest: GenerationManifest, error: String)
}

func readThemeStatusSnapshot(_ root: URL) throws -> ThemeStatusSnapshot {
  let store = ReconciliationStatusStore(root: root)
  let manifest = try store.activeManifest()
  do {
    return .state(
      manifest: manifest,
      reconciliation: try store.reconciliationState(for: manifest)
    )
  } catch {
    return .reconciliationFailure(
      manifest: manifest,
      error: String(describing: error)
    )
  }
}
