import Foundation
import ThemeCore

struct KeybindingsStatusCommandRunner: Sendable {
  func execute(
    behavior: KeybindingEffectiveBehavior,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report = KeybindingsStatusReport(behavior)
    return (try report.render(json: json), report.succeeded)
  }
}

private struct KeybindingsStatusReport: Encodable {
  let schemaVersion = 1
  let operation = "keybindings_status"
  let outcome: KeybindingEffectiveStatus
  let message: String
  let generation: KeybindingsStatusGeneration
  let provider: KeybindingProviderInspection
  let transaction: KeybindingTransactionInspection
  let process: KeybindingProcessInspection
  let lifecycleEvidence: KeybindingLifecycleEvidenceInspection
  let diagnostics: [KeybindingsStatusDiagnostic]

  init(_ behavior: KeybindingEffectiveBehavior) {
    outcome = behavior.status
    message = behavior.statusMessage
    generation = KeybindingsStatusGeneration(behavior)
    provider = behavior.provider
    transaction = behavior.transaction
    process = behavior.process
    lifecycleEvidence = behavior.lifecycleEvidence
    diagnostics = behavior.configuration.diagnostics.map(KeybindingsStatusDiagnostic.init)
  }

  var succeeded: Bool { outcome == .converged }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy keybindings status [\(outcome.rawValue)]:",
      "- \(message)",
      "- generation [\(generation.status), agreement=\(generation.agreement)]: "
        + "\(generation.message)",
      "- provider [\(provider.status.rawValue), \(provider.ownership)]: \(provider.message)",
      "- transaction [\(transaction.status.rawValue)]: \(transaction.message)",
      "- process [\(process.status.rawValue)]: \(process.message)",
      "- lifecycle evidence [\(lifecycleEvidence.status.rawValue)]: "
        + lifecycleEvidence.message,
      "- runtime equivalence: unobservable; skhd exposes no complete in-memory binding query",
    ]
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines.append(contentsOf: diagnostics.map(\.humanDescription))
    }
    return lines.joined(separator: "\n")
  }
}

private struct KeybindingsStatusGeneration: Encodable {
  let status: String
  let agreement: String
  let generationID: String?
  let inputDigest: String?
  let renderedDigest: String?
  let message: String

  init(_ behavior: KeybindingEffectiveBehavior) {
    status = behavior.generation.status.rawValue
    agreement = behavior.generationAgreement.rawValue
    generationID = behavior.generation.generationID
    inputDigest = behavior.generation.inputDigest
    renderedDigest = behavior.generation.renderedDigest
    switch behavior.generation.status {
    case .missing:
      message = "No current generated keybinding configuration exists."
    case .current:
      message = "Current generation \(behavior.generation.generationID ?? "unknown") is valid."
    case .invalid:
      message = behavior.generation.message ?? "Current generated keybinding state is invalid."
    }
  }
}

private struct KeybindingsStatusDiagnostic: Encodable {
  let code: String
  let severity: String
  let source: String
  let line: Int?
  let relatedLine: Int?
  let identity: String?
  let message: String

  init(_ diagnostic: KeybindingCompositionDiagnostic) {
    code = diagnostic.code
    severity = diagnostic.severity.rawValue
    source = diagnostic.source
    line = diagnostic.line
    relatedLine = diagnostic.relatedLine
    identity = diagnostic.identity
    message = diagnostic.message
  }

  var humanDescription: String {
    let location = line.map { "\(source):\($0)" } ?? source
    return "- \(location): \(severity) [\(code)]: \(message)"
  }
}
