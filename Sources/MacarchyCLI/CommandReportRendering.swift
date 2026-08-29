import Foundation
import ThemeCore

func renderSlackManualImport(_ theme: String) -> [String] {
  guard let notice = ConsumerCatalog.shared.manualNotice(for: .slack) else {
    preconditionFailure("Slack manual notice is missing from the consumer catalog")
  }
  return [
    notice.summary,
    theme.trimmingCharacters(in: .whitespacesAndNewlines),
    notice.instructions,
    notice.artifactSummary,
  ]
}

func renderAdapterResult(_ result: AdapterResult) -> String {
  let message = result.message.map { ": \($0)" } ?? ""
  return
    "- \(result.adapterID) [\(result.requirement.rawValue)]: "
    + "\(result.status.rawValue)\(message)"
}

func hasRequiredReconciliationFailure(_ results: [AdapterResult]) -> Bool {
  results.contains { result in
    result.requirement == .required && !isAcceptedReconciliationResult(result)
  }
}

func hasRequiredInspectionFailure(_ inspections: [AdapterInspection]) -> Bool {
  inspections.contains { inspection in
    inspection.requirement == .required
      && inspection.status != .ready
      && !(inspection.status == .unsupported
        && namedThemeOnlyAdapterIDs.contains(inspection.adapterID))
  }
}

func inspectionFindingStatus(_ inspection: AdapterInspection) -> DoctorFinding.Status {
  if inspection.status == .ready { return .ok }
  if inspection.status == .unsupported,
    namedThemeOnlyAdapterIDs.contains(inspection.adapterID)
  {
    return .warning
  }
  return inspection.requirement == .required ? .failure : .warning
}

let namedThemeOnlyAdapterIDs = GeneratedThemeCapabilities.namedThemeAdapterIDs

func isAcceptedReconciliationResult(_ result: AdapterResult) -> Bool {
  result.status == .applied
    || result.status == .restartRequired
    || (result.status == .unsupported && namedThemeOnlyAdapterIDs.contains(result.adapterID))
}

func renderJSON<Value: Encodable>(_ value: Value) throws -> String {
  let encoder = JSONEncoder()
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}
