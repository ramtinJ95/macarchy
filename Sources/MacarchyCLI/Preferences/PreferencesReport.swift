import Foundation
import ThemeCore

struct PreferencesReport: Encodable, Sendable {
  struct Row: Encodable, Sendable {
    let key: MacOSPreference
    let title: String
    let current: Bool
    let desired: Bool?
    let original: Bool
    let target: Bool
    let action: String
  }
  struct Action: Encodable, Sendable {
    let id: String
    let message: String
  }
  struct Diagnostic: Encodable, Sendable {
    let message: String
  }

  let schemaVersion = 1
  let operation = "macos_preferences"
  var outcome: String
  // Absent on unresolved writes: never report "no mutation" for an unknown outcome.
  var mutated: Bool? = false
  let receiptPath: String
  let target = "Current user on this Mac; --state-root relocates receipts, not native preferences."
  let runtime =
    "Public Apple Events; changes take effect without restart/logout. Dock inspection may start Apple's System Events query helper. No consent prompts or permission grants."
  var approvalDigest: String?
  var preferences: [Row] = []
  var actions: [Action] = []
  var diagnostics: [Diagnostic] = []
  var message: String?

  var succeeded: Bool {
    ["ready", "disabled", "no_change", "applied", "pending_commit", "recovered"].contains(outcome)
  }

  func componentExecution() throws -> SetupComponentExecution {
    try SetupComponentExecution((output: render(json: true), succeeded: succeeded))
  }

  static func failure(_ error: Error, context: PreferencesContext) -> Self {
    let outcome: String
    switch error {
    case PreferencesError.recoveryRequired, PreferencesError.uncertain:
      outcome = "recovery_required"
    case PreferencesError.drift: outcome = "drifted"
    case PreferencesError.rolledBack: outcome = "rolled_back"
    default: outcome = "blocked"
    }
    return Self(
      outcome: outcome, mutated: outcome == "recovery_required" ? nil : outcome == "rolled_back",
      receiptPath: PreferencesStore(context: context).url.path,
      diagnostics: [.init(message: String(describing: error))])
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = ["macOS preferences: \(outcome)", target, runtime]
    if mutated == nil {
      lines.append("Mutation outcome is unresolved; follow recovery instructions.")
    }
    for row in preferences {
      lines.append(
        "- \(row.key.rawValue): \(row.current) → \(row.target) [\(row.action)]; original: \(row.original)"
      )
    }
    if let approvalDigest { lines.append("Approval: \(approvalDigest)") }
    lines += diagnostics.map(\.message)
    return lines.joined(separator: "\n")
  }
}
