import Foundation
import ThemeCore

struct DoctorCommandRunner: Sendable {
  let read: @Sendable (URL) throws -> ThemeStatusSnapshot
  let inspect: @Sendable (URL, ThemeConsumerPaths) throws -> [AdapterInspection]

  static let live = DoctorCommandRunner(
    read: readThemeStatusSnapshot,
    inspect: { stateRoot, consumerPaths in
      try ThemeActivationCoordinator(
        root: stateRoot,
        consumerPaths: consumerPaths
      ).inspectAdapters([], includeRuntimeChecks: true)
    }
  )

  func execute(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    var findings = canonicalFindings(stateRoot: stateRoot)
    do {
      findings.append(
        contentsOf: try inspect(stateRoot, consumerPaths).map { inspection in
          DoctorFinding(
            id: "\(inspection.adapterID).integration",
            status: inspectionFindingStatus(inspection),
            message: inspection.message ?? "Integration preflight passed."
          )
        }
      )
    } catch {
      findings.append(
        DoctorFinding(
          id: "adapter.integration",
          status: .failure,
          message: String(describing: error)
        )
      )
    }
    let report = DoctorReport(findings: findings)
    return (try report.render(json: json), report.succeeded)
  }

  private func canonicalFindings(stateRoot: URL) -> [DoctorFinding] {
    do {
      switch try read(stateRoot) {
      case .reconciliationFailure(let manifest, let error):
        return [
          canonicalFinding(manifest),
          DoctorFinding(id: "reconciliation", status: .failure, message: error),
        ]
      case .state(let manifest, let reconciliation):
        var findings = [canonicalFinding(manifest)]
        switch reconciliation {
        case .missing:
          findings.append(
            DoctorFinding(
              id: "reconciliation",
              status: .failure,
              message: "Status is missing for the active generation."
            )
          )
        case .stale(_, let record):
          findings.append(
            DoctorFinding(
              id: "reconciliation",
              status: .failure,
              message:
                "Status belongs to theme '\(record.themeID)' generation '\(record.generationID)'."
            )
          )
        case .current(let record):
          findings.append(
            DoctorFinding(
              id: "reconciliation",
              status: .ok,
              message: "Status matches the active generation."
            )
          )
          for result in record.results {
            guard let requirement = ThemeActivationCoordinator.adapterRequirements[result.adapterID]
            else {
              findings.append(
                DoctorFinding(
                  id: "reconciliation.\(result.adapterID)",
                  status: .failure,
                  message: "Status contains an unknown adapter result."
                )
              )
              continue
            }
            if result.requirement != requirement {
              findings.append(
                DoctorFinding(
                  id: "reconciliation.\(result.adapterID)",
                  status: .failure,
                  message:
                    "Requirement is \(result.requirement.rawValue), expected \(requirement.rawValue)."
                )
              )
            } else {
              findings.append(reconciliationFinding(result))
            }
          }
          for adapterID in ThemeActivationCoordinator.adapterRequirements.keys.sorted()
          where !record.results.contains(where: { $0.adapterID == adapterID }) {
            findings.append(
              DoctorFinding(
                id: "reconciliation.\(adapterID)",
                status: .failure,
                message: "Current status has no result for this known adapter."
              )
            )
          }
        }
        return findings
      }
    } catch ReconciliationStatusError.noActiveGeneration {
      return [
        DoctorFinding(id: "canonical", status: .failure, message: "No active generation."),
        DoctorFinding(
          id: "reconciliation",
          status: .failure,
          message: "Unavailable without an active generation."
        ),
      ]
    } catch {
      return [
        DoctorFinding(
          id: "canonical",
          status: .failure,
          message: String(describing: error)
        ),
        DoctorFinding(
          id: "reconciliation",
          status: .failure,
          message: "Unavailable because canonical state is invalid."
        ),
      ]
    }
  }

  private func canonicalFinding(_ manifest: GenerationManifest) -> DoctorFinding {
    DoctorFinding(
      id: "canonical",
      status: .ok,
      message: "Theme '\(manifest.themeID)' generation '\(manifest.generationID)' is active."
    )
  }

  private func reconciliationFinding(_ result: AdapterResult) -> DoctorFinding {
    let status: DoctorFinding.Status =
      if isAcceptedReconciliationResult(result) {
        result.status == .unsupported ? .warning : .ok
      } else {
        result.requirement == .required ? .failure : .warning
      }
    let carried =
      result.carriedForwardFromGenerationID.map { " (carried from \($0))" } ?? ""
    let message =
      result.message.map { "\(result.status.rawValue)\(carried): \($0)" }
      ?? "\(result.status.rawValue)\(carried)"
    return DoctorFinding(
      id: "reconciliation.\(result.adapterID)",
      status: status,
      message: message
    )
  }
}
