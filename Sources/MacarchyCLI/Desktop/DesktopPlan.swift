import Foundation
import ThemeCore

enum DesktopPlanScope: Sendable {
  case allProviders
  case yabaiOnly
}

struct DesktopPlanCommandRunner: Sendable {
  static let live = DesktopPlanCommandRunner()

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    json: Bool,
    scope: DesktopPlanScope = .allProviders
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

    let yabaiEnabled = profile?.desktop.provider == .yabaiSkhd
    let sketchyBarEnabled = scope == .allProviders && profile?.topBar == .sketchybar
    var yabaiComposition: YabaiComposition?
    if let profile, yabaiEnabled {
      do {
        yabaiComposition = try YabaiConfigurationComposer().compose(
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
    var sketchyBarComposition: SketchyBarComposition?
    if let profile, sketchyBarEnabled {
      do {
        sketchyBarComposition = try SketchyBarConfigurationComposer().compose(
          defaultsURL: resourcesRoot.appending(path: "sketchybar/defaults.toml"),
          profile: profile,
          stateRoot: stateRoot
        )
      } catch {
        let source =
          (error as? SketchyBarConfigurationError)?.sourceURL
          ?? resourcesRoot.appending(path: "sketchybar/defaults.toml")
        diagnostics.append(
          DesktopPlanDiagnostic(
            code: "sketchybar_configuration_invalid",
            source: source.path,
            message: String(describing: error)
          )
        )
      }
    }

    let yabaiGeneration = YabaiGenerationInspector(stateRoot: stateRoot).inspect()
    if yabaiEnabled, yabaiGeneration.status == .invalid {
      diagnostics.append(
        DesktopPlanDiagnostic(
          code: "yabai_generation_invalid",
          source: stateRoot.appending(path: "desktop/yabai/current").path,
          message: yabaiGeneration.message
        )
      )
    }
    let yabaiProvider = YabaiProviderPlanInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      enabled: yabaiEnabled,
      transactionPending: YabaiTransactionStore(stateRoot: stateRoot).exists
    )
    if yabaiEnabled,
      yabaiProvider.status == .blocked || yabaiProvider.status == .recoveryRequired
    {
      diagnostics.append(
        DesktopPlanDiagnostic(
          code: "yabai_provider_blocked",
          source: yabaiProvider.entryPoint,
          message: yabaiProvider.message
        )
      )
    }
    let sketchyBarGeneration: SketchyBarGenerationInspection
    let sketchyBarProvider: SketchyBarProviderPlanInspection
    let sketchyBarPalette: SketchyBarPalettePlanInspection
    if scope == .allProviders {
      sketchyBarGeneration = SketchyBarGenerationInspector(stateRoot: stateRoot).inspect()
      if sketchyBarEnabled, sketchyBarGeneration.status == .invalid {
        diagnostics.append(
          DesktopPlanDiagnostic(
            code: "sketchybar_generation_invalid",
            source: stateRoot.appending(path: "desktop/sketchybar/current").path,
            message: sketchyBarGeneration.message
          )
        )
      }
      sketchyBarProvider = SketchyBarProviderPlanInspector().inspect(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        enabled: sketchyBarEnabled,
        generation: sketchyBarGeneration,
        transactionPending: SketchyBarTransactionStore(stateRoot: stateRoot).exists
      )
      if sketchyBarProvider.status == .blocked
        || sketchyBarProvider.status == .recoveryRequired
      {
        diagnostics.append(
          DesktopPlanDiagnostic(
            code: "sketchybar_provider_blocked",
            source: sketchyBarProvider.entryPoint,
            message: sketchyBarProvider.message
          )
        )
      }
      sketchyBarPalette = SketchyBarPalettePlanInspector().inspect(
        stateRoot: stateRoot,
        enabled: sketchyBarEnabled
      )
      if sketchyBarPalette.status == .invalid {
        diagnostics.append(
          DesktopPlanDiagnostic(
            code: "sketchybar_theme_palette_invalid",
            source: stateRoot.appending(path: "current").path,
            message: sketchyBarPalette.message
          )
        )
      }
    } else {
      sketchyBarGeneration = .missing
      sketchyBarProvider = SketchyBarProviderPlanInspection(
        status: .disabled,
        ownership: "not_inspected",
        entryPoint: homeDirectory.appending(path: ".config/sketchybar/sketchybarrc").path,
        originalTarget: nil,
        source: nil,
        message: "SketchyBar is outside this plan scope",
        adoptionEvidenceDigest: nil
      )
      sketchyBarPalette = SketchyBarPalettePlanInspection(
        status: .disabled,
        generationID: nil,
        message: "SketchyBar is outside this plan scope"
      )
    }
    let blocked = !diagnostics.isEmpty
    let actions =
      yabaiActions(
        enabled: yabaiEnabled,
        provider: yabaiProvider,
        composition: yabaiComposition,
        generation: yabaiGeneration,
        blocked: blocked
      )
      + sketchyBarActions(
        enabled: sketchyBarEnabled,
        provider: sketchyBarProvider,
        composition: sketchyBarComposition,
        generation: sketchyBarGeneration,
        palette: sketchyBarPalette,
        blocked: blocked
      )
    let outcome = blocked ? "blocked" : actions.isEmpty ? "no_change" : "ready"
    let sketchyBarReport =
      scope == .allProviders
      ? DesktopSketchyBarPlanReport(
        packagedDefaults: resourcesRoot.appending(path: "sketchybar/defaults.toml").path,
        settings: sketchyBarComposition?.settings,
        spaceModule: sketchyBarComposition?.spaceModule.rawValue,
        renderedArtifacts: sketchyBarComposition.map {
          Dictionary(uniqueKeysWithValues: $0.artifacts.map { ($0.path, $0.contents) })
        },
        renderedDigest: sketchyBarComposition?.renderedDigest,
        proposedInputDigest: sketchyBarComposition?.inputDigest,
        currentGenerationID: sketchyBarGeneration.generationID,
        currentGenerationStatus: sketchyBarGeneration.status.rawValue,
        provider: sketchyBarProvider,
        themePalette: sketchyBarPalette
      ) : nil
    let report = DesktopPlanReport(
      outcome: outcome,
      profile: profileURL.path,
      profileStatus: profile == nil
        ? "invalid" : profile?.sourceURL == nil ? "absent_default" : "loaded",
      desktopProvider: profile?.desktop.provider.rawValue,
      topBarProvider: profile?.topBar.rawValue,
      packagedDefaults: resourcesRoot.appending(path: "yabai/defaults.toml").path,
      hook: yabaiComposition?.hookURL?.path,
      hookDigest: yabaiComposition?.hookDigest,
      settings: yabaiComposition?.settings,
      renderedYabairc: yabaiComposition?.renderedConfiguration,
      renderedDigest: yabaiComposition?.renderedDigest,
      proposedInputDigest: yabaiComposition?.inputDigest,
      currentGenerationID: yabaiGeneration.generationID,
      currentGenerationStatus: yabaiGeneration.status.rawValue,
      provider: yabaiProvider,
      sketchyBar: sketchyBarReport,
      actions: actions,
      diagnostics: diagnostics
    )
    return (try report.render(json: json), !blocked)
  }

  private func yabaiActions(
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

  private func sketchyBarActions(
    enabled: Bool,
    provider: SketchyBarProviderPlanInspection,
    composition: SketchyBarComposition?,
    generation: SketchyBarGenerationInspection,
    palette: SketchyBarPalettePlanInspection,
    blocked: Bool
  ) -> [DesktopPlanAction] {
    guard !blocked else { return [] }
    if !enabled {
      return provider.status == .managed
        ? [
          DesktopPlanAction(
            id: "teardown_sketchybar_provider",
            message: "Restore the exact prior SketchyBar provider entry and service state."
          )
        ] : []
    }
    guard let composition else { return [] }
    let generationAgrees =
      generation.status == .current
      && generation.manifest?.inputDigest == composition.inputDigest
      && generation.manifest?.renderedDigest == composition.renderedDigest
    if provider.status == .managed, generationAgrees, palette.status == .current { return [] }
    var actions: [DesktopPlanAction] = []
    if palette.status == .unavailable || palette.status == .refreshRequired {
      actions.append(
        DesktopPlanAction(
          id: "activate_sketchybar_theme_palette",
          message: palette.status == .unavailable
            ? "Activate a canonical theme to publish the managed SketchyBar shell palette."
            : "Reactivate the current theme to publish the managed SketchyBar shell palette."
        )
      )
    }
    if !generationAgrees {
      actions.append(
        DesktopPlanAction(
          id: "publish_sketchybar_generation",
          message: "Publish deterministic managed SketchyBar configuration."
        )
      )
    }
    switch provider.status {
    case .installRequired:
      actions.append(
        DesktopPlanAction(
          id: "install_sketchybar_entry",
          message: "Install the managed sketchybarrc provider entry."
        )
      )
    case .adoptionRequired:
      actions.append(
        DesktopPlanAction(
          id: provider.ownership == "directory_symlink"
            ? "adopt_sketchybar_directory_symlink"
            : "adopt_sketchybarrc_entry",
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
        id: "reload_sketchybar_service",
        message: "Reload SketchyBar and verify its palette, items, and ready marker."
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
  let sketchyBar: DesktopSketchyBarPlanReport?
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
    if let sketchyBar {
      lines += sketchyBar.humanLines
    }
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
    for (path, contents) in (sketchyBar?.renderedArtifacts ?? [:]).sorted(by: {
      $0.key < $1.key
    }) {
      lines.append(
        "Rendered SketchyBar \(path):\n--- begin exact bytes ---\n\(contents)"
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
    case sketchyBar = "sketchybar"
    case actions
    case diagnostics
  }
}

private struct DesktopSketchyBarPlanReport: Encodable {
  let packagedDefaults: String
  let settings: SketchyBarSettings?
  let spaceModule: String?
  let renderedArtifacts: [String: String]?
  let renderedDigest: String?
  let proposedInputDigest: String?
  let currentGenerationID: String?
  let currentGenerationStatus: String
  let provider: SketchyBarProviderPlanInspection
  let themePalette: SketchyBarPalettePlanInspection

  var humanLines: [String] {
    [
      "- packaged SketchyBar defaults: \(packagedDefaults)",
      "- SketchyBar Space module: \(spaceModule ?? "unavailable")",
      "- SketchyBar proposed input digest: \(proposedInputDigest ?? "unavailable")",
      "- SketchyBar rendered digest: \(renderedDigest ?? "unavailable")",
      "- SketchyBar current generation [\(currentGenerationStatus)]: "
        + (currentGenerationID ?? "none"),
      "- SketchyBar provider [\(provider.status.rawValue), \(provider.ownership)]: "
        + provider.message,
      "- SketchyBar provider entry point: \(provider.entryPoint)",
      "- SketchyBar provider original target: \(provider.originalTarget ?? "none")",
      "- SketchyBar provider source: \(provider.source ?? "none")",
      "- SketchyBar adoption evidence digest: \(provider.adoptionEvidenceDigest ?? "none")",
      "- SketchyBar theme palette [\(themePalette.status.rawValue)]: \(themePalette.message)",
    ]
  }

  enum CodingKeys: String, CodingKey {
    case packagedDefaults = "packaged_defaults"
    case settings
    case spaceModule = "space_module"
    case renderedArtifacts = "rendered_artifacts"
    case renderedDigest = "rendered_digest"
    case proposedInputDigest = "proposed_input_digest"
    case currentGenerationID = "current_generation_id"
    case currentGenerationStatus = "current_generation_status"
    case provider
    case themePalette = "theme_palette"
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
