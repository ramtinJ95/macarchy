import Foundation
import ThemeCore

struct DesktopPlanCommandRunner: Sendable {
  static let live = DesktopPlanCommandRunner()

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    var diagnostics: [DesktopPlanDiagnostic] = []
    let profile: PortableProfile?
    do {
      profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
    } catch {
      profile = nil
      diagnostics.append(
        DesktopPlanDiagnostic(
          code: "profile_invalid",
          source: profileURL.path,
          message: String(describing: error)
        )
      )
    }

    let enabled = profile?.desktop.provider == .yabaiSkhd
    var composition: YabaiComposition?
    if let profile, enabled {
      do {
        composition = try YabaiConfigurationComposer().compose(
          defaultsURL: resourcesRoot.appending(path: "yabai/defaults.toml"),
          profile: profile
        )
      } catch {
        let source =
          (error as? YabaiConfigurationError)?.sourceURL
          ?? resourcesRoot.appending(path: "yabai/defaults.toml")
        diagnostics.append(
          DesktopPlanDiagnostic(
            code: "yabai_configuration_invalid",
            source: source.path,
            message: String(describing: error)
          )
        )
      }
    }

    let generation = YabaiGenerationInspector(stateRoot: stateRoot).inspect()
    if enabled, generation.status == .invalid {
      diagnostics.append(
        DesktopPlanDiagnostic(
          code: "yabai_generation_invalid",
          source: stateRoot.appending(path: "desktop/yabai/current").path,
          message: generation.message
        )
      )
    }
    let provider = YabaiProviderPlanInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      enabled: enabled,
      transactionPending: YabaiTransactionStore(stateRoot: stateRoot).exists
    )
    if enabled, provider.status == .blocked || provider.status == .recoveryRequired {
      diagnostics.append(
        DesktopPlanDiagnostic(
          code: "yabai_provider_blocked",
          source: provider.entryPoint,
          message: provider.message
        )
      )
    }
    let blocked = !diagnostics.isEmpty
    let actions = plannedActions(
      enabled: enabled,
      provider: provider,
      composition: composition,
      generation: generation,
      blocked: blocked
    )
    let outcome = blocked ? "blocked" : actions.isEmpty ? "no_change" : "ready"
    let report = DesktopPlanReport(
      outcome: outcome,
      profile: profileURL.path,
      profileStatus: profile == nil
        ? "invalid" : profile?.sourceURL == nil ? "absent_default" : "loaded",
      desktopProvider: profile?.desktop.provider.rawValue,
      topBarProvider: profile?.topBar.rawValue,
      packagedDefaults: resourcesRoot.appending(path: "yabai/defaults.toml").path,
      hook: composition?.hookURL?.path,
      hookDigest: composition?.hookDigest,
      settings: composition?.settings,
      renderedYabairc: composition?.renderedConfiguration,
      renderedDigest: composition?.renderedDigest,
      proposedInputDigest: composition?.inputDigest,
      currentGenerationID: generation.generationID,
      currentGenerationStatus: generation.status.rawValue,
      provider: provider,
      actions: actions,
      diagnostics: diagnostics
    )
    return (try report.render(json: json), !blocked)
  }

  private func plannedActions(
    enabled: Bool,
    provider: YabaiProviderPlanInspection,
    composition: YabaiComposition?,
    generation: YabaiGenerationInspection,
    blocked: Bool
  ) -> [DesktopPlanAction] {
    guard !blocked else { return [] }
    if !enabled {
      return provider.status == .managed
        ? [
          DesktopPlanAction(
            id: "teardown_yabai_provider",
            message: "Restore the exact prior yabai provider and service state."
          )
        ] : []
    }
    guard let composition else { return [] }
    let generationAgrees =
      generation.status == .current
      && generation.manifest?.inputDigest == composition.inputDigest
      && generation.manifest?.renderedDigest == composition.renderedDigest
    if provider.status == .managed, generationAgrees { return [] }
    var actions: [DesktopPlanAction] = []
    if !generationAgrees {
      actions.append(
        DesktopPlanAction(
          id: "publish_yabai_generation",
          message: "Publish deterministic managed yabai configuration."
        )
      )
    }
    switch provider.status {
    case .installRequired:
      actions.append(
        DesktopPlanAction(
          id: "install_yabai_entry",
          message: "Install the managed yabairc provider entry."
        )
      )
    case .adoptionRequired:
      actions.append(
        DesktopPlanAction(
          id: provider.ownership == "directory_symlink"
            ? "adopt_yabai_directory_symlink"
            : "adopt_yabairc_entry",
          message: "Adopt the existing \(provider.ownership) after explicit approval."
        )
      )
    case .managed:
      break
    case .disabled, .externallyManaged, .recoveryRequired, .blocked:
      break
    }
    actions.append(
      DesktopPlanAction(
        id: "restart_yabai_service",
        message: "Restart yabai through its built-in service lifecycle and verify runtime state."
      )
    )
    return actions
  }
}

private struct DesktopPlanReport: Encodable {
  let schemaVersion = 1
  let operation = "desktop_plan"
  let outcome: String
  let mutated = false
  let profile: String
  let profileStatus: String
  let desktopProvider: String?
  let topBarProvider: String?
  let packagedDefaults: String
  let hook: String?
  let hookDigest: String?
  let settings: YabaiSettings?
  let renderedYabairc: String?
  let renderedDigest: String?
  let proposedInputDigest: String?
  let currentGenerationID: String?
  let currentGenerationStatus: String
  let provider: YabaiProviderPlanInspection
  let actions: [DesktopPlanAction]
  let diagnostics: [DesktopPlanDiagnostic]

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy desktop plan [\(outcome)]:",
      "- profile [\(profileStatus)]: \(profile)",
      "- desktop provider: \(desktopProvider ?? "unavailable")",
      "- top-bar provider: \(topBarProvider ?? "unavailable")",
      "- packaged yabai defaults: \(packagedDefaults)",
      "- trusted yabai hook: \(hook ?? "none")",
      "- hook digest: \(hookDigest ?? "none")",
      "- effective layout: \(settings?.layout ?? "unavailable")",
      "- effective window gap: \(settings.map { String($0.windowGap) } ?? "unavailable")",
      "- proposed input digest: \(proposedInputDigest ?? "unavailable")",
      "- rendered digest: \(renderedDigest ?? "unavailable")",
      "- current generation [\(currentGenerationStatus)]: \(currentGenerationID ?? "none")",
      "- yabai provider [\(provider.status.rawValue), \(provider.ownership)]: "
        + provider.message,
      "- provider entry point: \(provider.entryPoint)",
      "- provider original target: \(provider.originalTarget ?? "none")",
      "- provider source: \(provider.source ?? "none")",
      "- adoption evidence digest: \(provider.adoptionEvidenceDigest ?? "none")",
    ]
    lines.append(actions.isEmpty ? "Actions: none" : "Actions:")
    lines += actions.map { "- \($0.id): \($0.message)" }
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines += diagnostics.map { "- \($0.source): error [\($0.code)]: \($0.message)" }
    }
    if let renderedYabairc {
      lines.append(
        "Rendered yabairc:\n--- begin exact bytes ---\n\(renderedYabairc)"
          + "--- end exact bytes ---"
      )
    }
    lines.append("No changes made.")
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation
    case outcome
    case mutated
    case profile
    case profileStatus = "profile_status"
    case desktopProvider = "desktop_provider"
    case topBarProvider = "top_bar_provider"
    case packagedDefaults = "packaged_defaults"
    case hook
    case hookDigest = "hook_digest"
    case settings
    case renderedYabairc = "rendered_yabairc"
    case renderedDigest = "rendered_digest"
    case proposedInputDigest = "proposed_input_digest"
    case currentGenerationID = "current_generation_id"
    case currentGenerationStatus = "current_generation_status"
    case provider
    case actions
    case diagnostics
  }
}

private struct DesktopPlanAction: Encodable {
  let id: String
  let message: String
}

private struct DesktopPlanDiagnostic: Encodable {
  let severity = "error"
  let code: String
  let source: String
  let message: String
}
