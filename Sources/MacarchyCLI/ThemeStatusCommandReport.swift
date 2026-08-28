import Foundation
import ThemeCore

enum ThemeStatusReport {
  enum Outcome: String, Encodable {
    case current
    case inactive
    case reconciliationMissing = "reconciliation_missing"
    case reconciliationStale = "reconciliation_stale"
    case failure
  }

  case inactive
  case active(manifest: GenerationManifest, reconciliation: ReconciliationState)
  case activeFailure(manifest: GenerationManifest, error: String)
  case failure(String)

  var succeeded: Bool {
    switch self {
    case .inactive, .failure, .activeFailure:
      false
    case .active(_, .missing), .active(_, .stale):
      false
    case .active(_, .current(let record)):
      !hasRequiredReconciliationFailure(record.results)
    }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }

    switch self {
    case .inactive:
      return "No active theme.\nCanonical state: absent."
    case .failure(let error):
      return "Theme status could not be read.\nError: \(error)"
    case .activeFailure(let manifest, let error):
      return [
        activeThemeLine(manifest),
        "Reconciliation: unreadable.",
        "Error: \(error)",
      ].joined(separator: "\n")
    case .active(let manifest, .missing):
      return [
        activeThemeLine(manifest),
        "Reconciliation: missing for the active generation.",
      ].joined(separator: "\n")
    case .active(let manifest, .current(let record)):
      return
        ([activeThemeLine(manifest), "Reconciliation: current."]
        + record.results.map(renderAdapterResult))
        .joined(separator: "\n")
    case .active(let manifest, .stale(_, let record)):
      return
        ([
          activeThemeLine(manifest),
          "Reconciliation: stale record for theme '\(record.themeID)' "
            + "(generation '\(record.generationID)').",
        ] + record.results.map(renderAdapterResult))
        .joined(separator: "\n")
    }
  }

  private var jsonReport: ThemeStatusJSONReport {
    switch self {
    case .inactive:
      ThemeStatusJSONReport(outcome: .inactive, active: false)
    case .failure(let error):
      ThemeStatusJSONReport(outcome: .failure, active: false, error: error)
    case .activeFailure(let manifest, let error):
      ThemeStatusJSONReport(
        outcome: .failure,
        active: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        error: error
      )
    case .active(let manifest, .missing):
      ThemeStatusJSONReport(
        outcome: .reconciliationMissing,
        active: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID
      )
    case .active(let manifest, .current(let record)):
      ThemeStatusJSONReport(
        outcome: .current,
        active: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        reconciliation: record
      )
    case .active(let manifest, .stale(_, let record)):
      ThemeStatusJSONReport(
        outcome: .reconciliationStale,
        active: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        reconciliation: record
      )
    }
  }

  private func activeThemeLine(_ manifest: GenerationManifest) -> String {
    "Active theme: '\(manifest.themeID)' (generation '\(manifest.generationID)')."
  }
}

private struct ThemeStatusJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "theme_status"
  let outcome: ThemeStatusReport.Outcome
  let active: Bool
  var themeID: String? = nil
  var generationID: String? = nil
  var reconciliation: ReconciliationRecord? = nil
  var error: String? = nil
}
