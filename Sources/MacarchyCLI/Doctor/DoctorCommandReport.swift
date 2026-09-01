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

  var succeeded: Bool {
    !findings.contains { $0.status == .failure }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(DoctorJSONReport(findings: findings))
    }
    return
      (["Macarchy doctor:"]
      + findings.map { "- \($0.id) [\($0.status.rawValue)]: \($0.message)" }
      + ["No changes made."])
      .joined(separator: "\n")
  }
}

private struct DoctorJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "doctor"
  let outcome: String
  let mutated = false
  let findings: [DoctorFinding]

  init(findings: [DoctorFinding]) {
    outcome = findings.contains { $0.status == .failure } ? "unhealthy" : "healthy"
    self.findings = findings
  }
}
