import Foundation
import ThemeCore

struct DoctorFinding: Encodable {
  enum Status: String, Encodable {
    case ok
    case warning
    case failure
  }

  let id: String
  let status: Status
  let message: String
}

struct DoctorReport {
  let findings: [DoctorFinding]
  let operation: String
  let title: String

  init(
    findings: [DoctorFinding],
    operation: String = "doctor",
    title: String = "Macarchy doctor"
  ) {
    self.findings = findings
    self.operation = operation
    self.title = title
  }

  var succeeded: Bool {
    !findings.contains { $0.status == .failure }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(DoctorJSONReport(operation: operation, findings: findings))
    }
    return
      (["\(title):"]
      + findings.map { "- \($0.id) [\($0.status.rawValue)]: \($0.message)" }
      + ["No changes made."])
      .joined(separator: "\n")
  }
}

private struct DoctorJSONReport: Encodable {
  let schemaVersion = 1
  let operation: String
  let outcome: String
  let mutated = false
  let findings: [DoctorFinding]

  init(operation: String, findings: [DoctorFinding]) {
    self.operation = operation
    outcome = findings.contains { $0.status == .failure } ? "unhealthy" : "healthy"
    self.findings = findings
  }
}
