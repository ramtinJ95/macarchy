import Foundation
import ThemeCore

enum ThemeSetReport {
  enum Outcome: String, Encodable {
    case dryRun = "dry_run"
    case success
    case precommitFailure = "precommit_failure"
    case requiredReconciliationFailure = "required_reconciliation_failure"
    case committedActivationError = "committed_activation_error"
    case committedReconciliationError = "committed_reconciliation_error"
  }

  case dryRun(themeID: String)
  case precommitFailure(themeID: String, error: String)
  case committed(result: ThemeActivationResult, requiredFailure: Bool, slackTheme: String?)
  case committedActivationError(
    manifest: GenerationManifest,
    cause: String,
    slackTheme: String?
  )
  case committedError(manifest: GenerationManifest, cause: String, slackTheme: String?)

  var succeeded: Bool {
    switch self {
    case .dryRun, .committed(_, requiredFailure: false, _):
      true
    case .precommitFailure, .committed(_, requiredFailure: true, _), .committedActivationError,
      .committedError:
      false
    }
  }

  /// Whether canonical state changed. A committed activation keeps its package (ADR-0052).
  var isCommitted: Bool {
    switch self {
    case .dryRun, .precommitFailure:
      false
    case .committed, .committedActivationError, .committedError:
      true
    }
  }

  init(_ outcome: ThemeActivationOutcome, themeID: String, slackTheme: String?) {
    switch outcome {
    case .committed(let result, let requiredFailure):
      self = .committed(result: result, requiredFailure: requiredFailure, slackTheme: slackTheme)
    case .committedActivationError(let manifest, let cause):
      self = .committedActivationError(manifest: manifest, cause: cause, slackTheme: slackTheme)
    case .committedReconciliationError(let manifest, let cause):
      self = .committedError(manifest: manifest, cause: cause, slackTheme: slackTheme)
    case .precommitFailure(let error):
      self = .precommitFailure(themeID: themeID, error: error)
    }
  }

  static func precommitFailure(themeID: String, error: any Error) -> Self {
    .precommitFailure(themeID: themeID, error: String(describing: error))
  }

  func execution(json: Bool) throws -> CommandExecution {
    (try render(json: json), succeeded)
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }

    switch self {
    case .dryRun(let themeID):
      return [
        "Theme '\(themeID)' is valid.",
        "Required adapter preflight passed.",
        "Canonical state: unchanged (dry run).",
        "No files written; no processes run.",
      ].joined(separator: "\n")
    case .precommitFailure(let themeID, let error):
      return [
        "Theme '\(themeID)' was not activated.",
        "Canonical state: unchanged.",
        "Error: \(error)",
      ].joined(separator: "\n")
    case .committed(let result, let requiredFailure, let slackTheme):
      let headline =
        "Activated '\(result.manifest.themeID)' as generation '\(result.manifest.generationID)'."
      return
        (renderCommittedActivation(
          headline: headline, result: result, requiredFailure: requiredFailure)
        + renderSlackManualImport(slackTheme)).joined(separator: "\n")
    case .committedActivationError(let manifest, let cause, let slackTheme):
      return
        (renderCommittedFailure(
          headline: "Committed '\(manifest.themeID)' as generation '\(manifest.generationID)'.",
          cause: "Postcommit activation work could not complete: \(cause)")
        + renderSlackManualImport(slackTheme)).joined(separator: "\n")
    case .committedError(let manifest, let cause, let slackTheme):
      return
        (renderCommittedFailure(
          headline: "Committed '\(manifest.themeID)' as generation '\(manifest.generationID)'.",
          cause: "Reconciliation could not complete: \(cause)")
        + renderSlackManualImport(slackTheme)).joined(separator: "\n")
    }
  }

  var jsonReport: ThemeSetJSONReport {
    switch self {
    case .dryRun(let themeID):
      ThemeSetJSONReport(
        themeID: themeID,
        outcome: .dryRun,
        committed: false
      )
    case .precommitFailure(let themeID, let error):
      ThemeSetJSONReport(
        themeID: themeID,
        outcome: .precommitFailure,
        committed: false,
        error: error
      )
    case .committed(let result, let requiredFailure, let slackTheme):
      ThemeSetJSONReport(
        themeID: result.manifest.themeID,
        outcome: requiredFailure ? .requiredReconciliationFailure : .success,
        committed: true,
        generationID: result.manifest.generationID,
        reconciliation: result.reconciliation.results,
        notice: result.notice,
        slackTheme: slackTheme?.trimmingCharacters(in: .whitespacesAndNewlines),
        error: requiredFailure ? "Required reconciliation did not complete successfully" : nil
      )
    case .committedActivationError(let manifest, let cause, let slackTheme):
      ThemeSetJSONReport(
        themeID: manifest.themeID,
        outcome: .committedActivationError,
        committed: true,
        generationID: manifest.generationID,
        slackTheme: slackTheme?.trimmingCharacters(in: .whitespacesAndNewlines),
        error: cause
      )
    case .committedError(let manifest, let cause, let slackTheme):
      ThemeSetJSONReport(
        themeID: manifest.themeID,
        outcome: .committedReconciliationError,
        committed: true,
        generationID: manifest.generationID,
        slackTheme: slackTheme?.trimmingCharacters(in: .whitespacesAndNewlines),
        error: cause
      )
    }
  }

}

struct ThemeSetJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "theme_set"
  let themeID: String
  let outcome: ThemeSetReport.Outcome
  let committed: Bool
  var generationID: String? = nil
  var reconciliation: [AdapterResult]? = nil
  var notice: String? = nil
  var slackTheme: String? = nil
  var error: String? = nil

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, committed
    case themeID = "theme_id"
    case generationID = "generation_id"
    case reconciliation
    case notice
    case slackTheme = "slack_theme"
    case error
  }
}

/// The text lines of a committed activation under its command's headline.
func renderCommittedActivation(
  headline: String, result: ThemeActivationResult, requiredFailure: Bool
) -> [String] {
  var lines = [headline]
  if let notice = result.notice { lines.append("Notice: \(notice)") }
  lines.append("Reconciliation:")
  lines.append(contentsOf: result.reconciliation.results.map(renderAdapterResult))
  if requiredFailure {
    lines.append("Required reconciliation failed; the commit was not rolled back.")
  }
  return lines
}

/// The text lines of an activation that committed before `cause` stopped its later work.
func renderCommittedFailure(headline: String, cause: String) -> [String] {
  [headline, cause, "The commit was not rolled back."]
}

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
