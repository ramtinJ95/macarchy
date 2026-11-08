import ArgumentParser
import Foundation

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
