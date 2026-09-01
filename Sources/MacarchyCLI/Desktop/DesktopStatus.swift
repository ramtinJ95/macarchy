import Foundation
import ThemeCore

struct DesktopStatusCommandRunner: Sendable {
  let lifecycle: YabaiLifecycleController

  static let live = DesktopStatusCommandRunner(lifecycle: .live)

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let desired: DesktopDesiredYabaiState?
    var diagnostics: [String] = []
    do {
      desired = try DesktopDesiredYabaiState.load(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired
      )
    } catch {
      desired = nil
      diagnostics.append(String(describing: error))
    }
    let enabled = desired?.profile.desktop.provider == .yabaiSkhd
    let transactionPending = YabaiTransactionStore(stateRoot: stateRoot).exists
    let generation = YabaiGenerationInspector(stateRoot: stateRoot).inspect()
    let provider = YabaiProviderPlanInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      enabled: enabled,
      transactionPending: transactionPending
    )
    let lifecycleEvidence: YabaiLifecycleEvidence?
    do {
      lifecycleEvidence = try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).read()
    } catch {
      lifecycleEvidence = nil
      diagnostics.append(String(describing: error))
    }
    let ownership: YabaiOwnershipRecord?
    do {
      ownership = try YabaiOwnershipStore(stateRoot: stateRoot).read()
    } catch {
      ownership = nil
      diagnostics.append(String(describing: error))
    }
    let runtime =
      enabled
      ? desired?.composition.map(lifecycle.inspect) ?? .stopped
      : .disabled

    let generationAgrees =
      generation.status == .current
      && generation.manifest?.inputDigest == desired?.composition?.inputDigest
      && generation.manifest?.renderedDigest == desired?.composition?.renderedDigest
    let ownershipAgrees = ownership?.generationID == generation.generationID
    let lifecycleAgrees =
      lifecycleEvidence?.generationID == generation.generationID
      && lifecycleEvidence?.runtime == runtime
    let converged =
      enabled && !transactionPending && diagnostics.isEmpty
      && provider.status == .managed && generationAgrees && ownershipAgrees && lifecycleAgrees
      && (runtime.status == .converged || runtime.status == .partial)
    let disabledClean =
      !enabled
      && (provider.status == .disabled || provider.status == .externallyManaged)
      && !transactionPending && diagnostics.isEmpty
    let outcome =
      converged
      ? (runtime.status == .partial ? "partial" : "converged")
      : disabledClean ? "disabled" : transactionPending ? "recovery_required" : "drifted"
    let report = DesktopStatusReport(
      outcome: outcome,
      desktopProvider: desired?.profile.desktop.provider.rawValue,
      generationStatus: generation.status.rawValue,
      generationID: generation.generationID,
      generationAgrees: generationAgrees,
      ownershipAgrees: ownershipAgrees,
      provider: provider,
      runtime: runtime,
      lifecycleGenerationID: lifecycleEvidence?.generationID,
      transactionPending: transactionPending,
      diagnostics: diagnostics
    )
    return (try report.render(json: json), converged || disabledClean)
  }
}

private struct DesktopStatusReport: Encodable {
  let schemaVersion = 1
  let operation = "desktop_status"
  let outcome: String
  let desktopProvider: String?
  let generationStatus: String
  let generationID: String?
  let generationAgrees: Bool
  let ownershipAgrees: Bool
  let provider: YabaiProviderPlanInspection
  let runtime: YabaiRuntimeInspection
  let lifecycleGenerationID: String?
  let transactionPending: Bool
  let diagnostics: [String]

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy desktop status [\(outcome)]:",
      "- desktop provider: \(desktopProvider ?? "unavailable")",
      "- generation [\(generationStatus)]: \(generationID ?? "none")",
      "- desired generation agreement: \(generationAgrees ? "yes" : "no")",
      "- ownership generation agreement: \(ownershipAgrees ? "yes" : "no")",
      "- provider [\(provider.status.rawValue)]: \(provider.message)",
      "- runtime [\(runtime.status.rawValue)]: \(runtime.message)",
      "- lifecycle generation: \(lifecycleGenerationID ?? "none")",
      "- interrupted transaction: \(transactionPending ? "yes" : "no")",
    ]
    lines += diagnostics.map { "- error: \($0)" }
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome
    case desktopProvider = "desktop_provider"
    case generationStatus = "generation_status"
    case generationID = "generation_id"
    case generationAgrees = "generation_agrees"
    case ownershipAgrees = "ownership_agrees"
    case provider, runtime
    case lifecycleGenerationID = "lifecycle_generation_id"
    case transactionPending = "transaction_pending"
    case diagnostics
  }
}
