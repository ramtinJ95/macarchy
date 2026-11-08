import Foundation
import ThemeCore

struct DoctorFinding: Encodable, Sendable {
  enum Status: String, Encodable, Sendable {
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
  var operation = "doctor"
  var title = "Macarchy doctor"

  var succeeded: Bool {
    !findings.contains { $0.status == .failure }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }
    return
      (["\(title):"]
      + findings.map { "- \($0.id) [\($0.status.rawValue)]: \($0.message)" }
      + ["No changes made."])
      .joined(separator: "\n")
  }

  var jsonReport: DoctorJSONReport { DoctorJSONReport(operation: operation, findings: findings) }
}

struct DoctorJSONReport: Encodable, Sendable {
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

  var succeeded: Bool { outcome == "healthy" }
}
