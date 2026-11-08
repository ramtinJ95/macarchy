import ArgumentParser
import Foundation
import ThemeCore

func renderSlackManualImport(_ theme: String?) -> [String] {
  guard let theme else { return [] }
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
  let carried = result.carriedForwardFromGenerationID.map { " (carried from \($0))" } ?? ""
  return
    "- \(result.adapterID) [\(result.requirement.rawValue)]: "
    + "\(result.status.rawValue)\(carried)\(message)"
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
    || (result.adapterID == "wallpaper" && result.status == .disabled)
    || (result.status == .unsupported && namedThemeOnlyAdapterIDs.contains(result.adapterID))
}

/// A command's rendered output and whether it exits successfully.
typealias CommandExecution = (output: String, succeeded: Bool)

/// A report whose `--json` form is the report itself.
protocol CommandReport: Encodable {
  func renderText() throws -> String
}

extension CommandReport {
  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    return try renderText()
  }
}

struct PlanAction: Encodable, Sendable {
  let id: String
  let message: String

  static func renderLines(_ actions: [Self]) -> [String] {
    [actions.isEmpty ? "Actions: none" : "Actions:"]
      + actions.map { "- \($0.id): \($0.message)" }
  }
}

struct PlanDiagnostic: Encodable, Sendable {
  let severity = "error"
  let code: String
  let source: String
  let message: String

  static func renderLines(_ diagnostics: [Self]) -> [String] {
    guard !diagnostics.isEmpty else { return [] }
    return ["Diagnostics:"]
      + diagnostics.map { "- \($0.source): error [\($0.code)]: \($0.message)" }
  }
}

/// A rendered artifact shown verbatim in plan text.
func renderExactBytes(_ name: String, _ contents: String) -> String {
  "Rendered \(name):\n--- begin exact bytes ---\n\(contents)--- end exact bytes ---"
}

func emitExecution(_ execution: CommandExecution) throws {
  print(execution.output)
  if !execution.succeeded {
    throw ExitCode.failure
  }
}

func renderJSON<Value: Encodable>(_ value: Value) throws -> String {
  let encoder = JSONEncoder()
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}
