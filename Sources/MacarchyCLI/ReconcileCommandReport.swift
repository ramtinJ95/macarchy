import Foundation
import ThemeCore

enum ReconcileReport {
  enum Outcome: String, Encodable {
    case dryRun = "dry_run"
    case inspectionFailure = "inspection_failure"
    case success
    case requiredReconciliationFailure = "required_reconciliation_failure"
    case persistenceFailure = "persistence_failure"
    case failure
  }

  case preview(manifest: GenerationManifest, inspections: [AdapterInspection])
  case completed(manifest: GenerationManifest, record: ReconciliationRecord)
  case persistenceFailure(ReconciliationPersistenceError)
  case failure(dryRun: Bool, error: String)

  var succeeded: Bool {
    switch self {
    case .preview(_, let inspections):
      !hasRequiredInspectionFailure(inspections)
    case .completed(_, let record):
      !hasRequiredReconciliationFailure(record.results)
    case .persistenceFailure, .failure:
      false
    }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }

    switch self {
    case .preview(let manifest, let inspections):
      return
        ([
          "Reconciliation dry run for '\(manifest.themeID)' "
            + "(generation '\(manifest.generationID)').",
          "Inspection:",
        ] + inspections.map(renderInspection)
        + [
          "Canonical state and reconciliation status: unchanged (dry run).",
          "No files written; no processes run.",
        ]).joined(separator: "\n")
    case .completed(let manifest, let record):
      var lines = [
        "Reconciled '\(manifest.themeID)' generation '\(manifest.generationID)'.",
        "Reconciliation:",
      ]
      lines.append(contentsOf: record.results.map(renderAdapterResult))
      if hasRequiredReconciliationFailure(record.results) {
        lines.append("Required reconciliation failed; canonical state was not changed.")
      }
      return lines.joined(separator: "\n")
    case .persistenceFailure(let error):
      return
        ([
          "Adapters ran for '\(error.manifest.themeID)' generation "
            + "'\(error.manifest.generationID)'.",
          "Observed reconciliation:",
        ] + error.results.map(renderAdapterResult)
        + [
          "Reconciliation status was not updated.",
          "Canonical state: unchanged.",
          "Error: \(error.cause)",
        ]).joined(separator: "\n")
    case .failure(_, let error):
      return [
        "Reconciliation could not complete.",
        "Canonical state: unchanged.",
        "Error: \(error)",
      ].joined(separator: "\n")
    }
  }

  private var jsonReport: ReconcileJSONReport {
    switch self {
    case .preview(let manifest, let inspections):
      return ReconcileJSONReport(
        outcome: hasRequiredInspectionFailure(inspections) ? .inspectionFailure : .dryRun,
        dryRun: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        inspections: inspections.map(ReconcileInspection.init)
      )
    case .completed(let manifest, let record):
      let requiredFailure = hasRequiredReconciliationFailure(record.results)
      return ReconcileJSONReport(
        outcome: requiredFailure ? .requiredReconciliationFailure : .success,
        dryRun: false,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        reconciliation: record.results,
        error: requiredFailure ? "Required reconciliation did not complete successfully" : nil
      )
    case .persistenceFailure(let error):
      return ReconcileJSONReport(
        outcome: .persistenceFailure,
        dryRun: false,
        themeID: error.manifest.themeID,
        generationID: error.manifest.generationID,
        reconciliation: error.results,
        error: error.cause
      )
    case .failure(let dryRun, let error):
      return ReconcileJSONReport(
        outcome: .failure,
        dryRun: dryRun,
        error: error
      )
    }
  }

  private func renderInspection(_ inspection: AdapterInspection) -> String {
    let message = inspection.message.map { ": \($0)" } ?? ""
    let status = "\(inspection.status.rawValue)\(message)"
    return "- \(inspection.adapterID) [\(inspection.requirement.rawValue)]: \(status)"
  }
}

private struct ReconcileInspection: Encodable {
  let adapterID: String
  let requirement: AdapterRequirement
  let status: String
  let message: String?

  init(_ inspection: AdapterInspection) {
    adapterID = inspection.adapterID
    requirement = inspection.requirement
    status = inspection.status.rawValue
    message = inspection.message
  }
}

private struct ReconcileJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "reconcile"
  let outcome: ReconcileReport.Outcome
  let dryRun: Bool
  let canonicalChanged = false
  var themeID: String? = nil
  var generationID: String? = nil
  var inspections: [ReconcileInspection]? = nil
  var reconciliation: [AdapterResult]? = nil
  var error: String? = nil
}
