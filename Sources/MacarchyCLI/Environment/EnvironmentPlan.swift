import Foundation
import ThemeCore

struct EnvironmentPlanCommandRunner: Sendable {
  static let live = EnvironmentPlanCommandRunner(
    prerequisites: .live,
    requiresActiveTheme: true
  )

  let prerequisites: EnvironmentPrerequisiteInspector
  let requiresActiveTheme: Bool

  init(
    prerequisites: EnvironmentPrerequisiteInspector = .live,
    requiresActiveTheme: Bool = false
  ) {
    self.prerequisites = prerequisites
    self.requiresActiveTheme = requiresActiveTheme
  }

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL? = nil,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let profile: PortableProfile
    do {
      profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
    } catch {
      let report = EnvironmentPlanReport.blocked(
        profile: profileURL,
        resourcesRoot: resourcesRoot,
        diagnostic: EnvironmentPlanDiagnostic(
          code: "profile_invalid",
          source: profileURL.path,
          message: String(describing: error)
        )
      )
      return (try report.render(json: json), false)
    }

    let composition: EnvironmentComposition
    do {
      composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot,
        profile: profile,
        stateRoot: stateRoot
      )
    } catch {
      let source = (error as? EnvironmentConfigurationError)?.sourceURL ?? resourcesRoot
      let report = EnvironmentPlanReport.blocked(
        profile: profileURL,
        profileStatus: profile.sourceURL == nil ? "absent_default" : "loaded",
        environment: profile.environment,
        resourcesRoot: resourcesRoot,
        diagnostic: EnvironmentPlanDiagnostic(
          code: "environment_configuration_invalid",
          source: source.path,
          message: String(describing: error)
        )
      )
      return (try report.render(json: json), false)
    }

    let provider = homeDirectory.map {
      EnvironmentProviderInspector().inspect(
        composition: composition,
        homeDirectory: $0,
        stateRoot: stateRoot
      )
    }
    let prerequisiteState =
      homeDirectory.map {
        prerequisites.inspect(composition.profile, $0)
      } ?? []
    let generation = EnvironmentGenerationStore(stateRoot: stateRoot).inspect(expected: composition)
    let themeDiagnostic: EnvironmentPlanDiagnostic?
    if requiresActiveTheme,
      !composition.profile.selectedThemeAdapterIDs.isEmpty || composition.profile.presets.slack
    {
      do {
        _ = try ReconciliationStatusStore(root: stateRoot).activeManifest()
        themeDiagnostic = nil
      } catch {
        themeDiagnostic = EnvironmentPlanDiagnostic(
          code: "active_theme_required",
          source: stateRoot.path,
          message: "An active canonical theme is required before environment apply: \(error)"
        )
      }
    } else {
      themeDiagnostic = nil
    }
    let blocked =
      provider?.isBlocked == true
      || prerequisiteState.contains { $0.status == "missing" }
      || EnvironmentStateStore(stateRoot: stateRoot).transactionExists
      || themeDiagnostic != nil
    var diagnostics =
      provider?.blockedMessage.map {
        [EnvironmentPlanDiagnostic(code: "provider_blocked", source: stateRoot.path, message: $0)]
      } ?? []
    if let themeDiagnostic { diagnostics.append(themeDiagnostic) }
    let renderedArtifacts = try Dictionary(
      uniqueKeysWithValues: composition.artifacts.compactMap { artifact -> (String, String)? in
        guard !artifact.path.hasPrefix("neovim/") else { return nil }
        guard let contents = artifact.textContents else {
          throw EnvironmentLifecycleError.blocked(
            "rendered environment artifact \(artifact.path) is not UTF-8"
          )
        }
        return (artifact.path, contents)
      }
    )
    let report = EnvironmentPlanReport(
      outcome: blocked ? "blocked" : "ready",
      profile: profileURL.path,
      profileStatus: profile.sourceURL == nil ? "absent_default" : "loaded",
      terminalProvider: composition.profile.terminal.rawValue,
      shellProvider: composition.profile.shell.rawValue,
      promptProvider: composition.profile.prompt.rawValue,
      historyProvider: composition.profile.history.rawValue,
      editorProvider: composition.profile.editor.rawValue,
      dailyTools: Self.dailyTools(composition.profile),
      presets: Self.presets(composition.profile),
      packagedDefaults: resourcesRoot.path,
      kittyOverride: composition.kittyOverrideURL?.path,
      zshHook: composition.zshHookURL?.path,
      zshHookDigest: composition.zshHookDigest,
      starshipBehavior: composition.starshipBehaviorURL?.path,
      atuinConfiguration: composition.atuinConfigurationURL?.path,
      neovimConfiguration: composition.neovimConfigurationURL?.path,
      renderedArtifacts: renderedArtifacts,
      renderedArtifactDigests: Dictionary(
        uniqueKeysWithValues: composition.artifacts.map { ($0.path, $0.digest) }
      ),
      renderedDigest: composition.renderedDigest,
      proposedInputDigest: composition.inputDigest,
      generation: EnvironmentGenerationReport(generation),
      transactionStatus: EnvironmentStateStore(stateRoot: stateRoot).transactionExists
        ? "recovery_required" : "clear",
      adoptionEvidenceDigest: provider?.adoptionEvidenceDigest,
      prerequisites: prerequisiteState,
      entries: provider?.entries ?? [],
      actions: Self.actions(
        for: composition.profile,
        adoptionRequired: provider?.adoptionEvidenceDigest != nil,
        restorationRequired: provider?.entries.contains {
          $0.status == "restoration_required"
        } == true
      ),
      diagnostics: diagnostics
    )
    return (try report.render(json: json), !blocked)
  }

  fileprivate static func dailyTools(_ profile: EnvironmentProfile) -> [String: String] {
    [
      "bat": profile.tools.bat ? "enabled" : "disabled",
      "btop": profile.tools.btop ? "enabled" : "disabled",
      "eza": profile.tools.eza ? "enabled" : "disabled",
      "yazi": profile.tools.yazi ? "enabled" : "disabled",
    ]
  }

  fileprivate static func presets(_ profile: EnvironmentProfile) -> [String: String] {
    [
      "codex": profile.presets.codex ? "enabled" : "disabled",
      "herdr": profile.presets.herdr ? "enabled" : "disabled",
      "pi": profile.presets.pi ? "enabled" : "disabled",
      "slack": profile.presets.slack ? "enabled" : "disabled",
      "spicetify": profile.presets.spicetify ? "enabled" : "disabled",
      "tuicr": profile.presets.tuicr ? "enabled" : "disabled",
    ]
  }

  private static func actions(
    for profile: EnvironmentProfile,
    adoptionRequired: Bool,
    restorationRequired: Bool
  ) -> [EnvironmentPlanAction] {
    var actions: [EnvironmentPlanAction] = []
    if profile.terminal == .kitty {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_kitty",
          message: "Configure Kitty through the managed environment generation."
        )
      )
    }
    if profile.shell == .zsh {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_zsh",
          message: "Configure zsh through the managed environment generation."
        )
      )
    }
    if profile.prompt == .starship {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_starship",
          message: "Configure Starship behavior while retaining Macarchy palette ownership."
        )
      )
    }
    if profile.history == .atuin {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_atuin",
          message: "Configure Atuin behavior while retaining Macarchy theme ownership."
        )
      )
    }
    if profile.editor == .neovim {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_neovim",
          message: "Configure Neovim behavior and canonical theme integration."
        )
      )
      actions.append(
        EnvironmentPlanAction(
          id: "restore_neovim_plugins",
          message: "Restore the selected Neovim plugin graph from its lock using Lazy."
        )
      )
    }
    if profile.tools.bat {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_bat",
          message: "Configure bat behavior and its canonical theme seam."
        )
      )
    }
    if profile.tools.eza {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_eza",
          message: "Configure eza shell behavior and its canonical theme seam."
        )
      )
    }
    if profile.tools.btop {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_btop",
          message: "Configure btop while preserving its provider-writable state."
        )
      )
    }
    if profile.tools.yazi {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_yazi",
          message: "Configure Yazi behavior and its generated flavor seams."
        )
      )
    }
    if profile.presets.tuicr {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_tuicr",
          message: "Configure tuicr's root theme selector and canonical palette and syntax links."
        )
      )
    }
    if profile.presets.codex {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_codex",
          message: "Configure Codex CLI's [tui].theme selector and canonical TextMate theme link."
        )
      )
    }
    if profile.presets.herdr {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_herdr",
          message:
            "Configure Herdr's [theme] selector and established 16-key [theme.custom] surface."
        )
      )
    }
    if profile.presets.pi {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_pi",
          message: "Configure Pi's root theme member and watched canonical theme link."
        )
      )
    }
    if profile.presets.spicetify {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_spicetify",
          message:
            "Own only ordinary current_theme/color_scheme selectors or accept a complete exact Stow tuple, create only an absent color.ini link, and run an awaited --no-restart refresh."
        )
      )
    }
    if profile.presets.slack {
      actions.append(
        EnvironmentPlanAction(
          id: "publish_slack_manual_import",
          message:
            "Publish Slack manual-import authority and the exact per-workspace action: \(SlackAdapter.importInstructions)"
        )
      )
    }
    if !actions.isEmpty {
      actions.insert(
        EnvironmentPlanAction(
          id: "publish_environment_generation",
          message: "Publish the deterministic daily tool generation."
        ),
        at: 0
      )
    }
    if adoptionRequired {
      actions.insert(
        EnvironmentPlanAction(
          id: "adopt_provider_entries",
          message: "Adopt every reviewed external provider entry as one aggregate transaction."
        ),
        at: 0
      )
    }
    if restorationRequired {
      actions.insert(
        EnvironmentPlanAction(
          id: "restore_disabled_provider_entries",
          message: "Restore adopted entries for roles that are now disabled."
        ),
        at: 0
      )
    }
    return actions
  }
}

private struct EnvironmentPlanReport: Encodable {
  let schemaVersion = 1
  let operation = "environment_plan"
  let outcome: String
  let mutated = false
  let profile: String
  let profileStatus: String
  let terminalProvider: String?
  let shellProvider: String?
  let promptProvider: String?
  let historyProvider: String?
  let editorProvider: String?
  let dailyTools: [String: String]
  let presets: [String: String]
  let packagedDefaults: String
  let kittyOverride: String?
  let zshHook: String?
  let zshHookDigest: String?
  let starshipBehavior: String?
  let atuinConfiguration: String?
  let neovimConfiguration: String?
  let renderedArtifacts: [String: String]
  let renderedArtifactDigests: [String: String]
  let renderedDigest: String?
  let proposedInputDigest: String?
  let generation: EnvironmentGenerationReport
  let transactionStatus: String
  let adoptionEvidenceDigest: String?
  let prerequisites: [EnvironmentPrerequisiteStatus]
  let entries: [EnvironmentEntryInspection]
  let actions: [EnvironmentPlanAction]
  let diagnostics: [EnvironmentPlanDiagnostic]

  static func blocked(
    profile: URL,
    profileStatus: String = "invalid",
    environment: EnvironmentProfile? = nil,
    resourcesRoot: URL,
    diagnostic: EnvironmentPlanDiagnostic
  ) -> EnvironmentPlanReport {
    EnvironmentPlanReport(
      outcome: "blocked",
      profile: profile.path,
      profileStatus: profileStatus,
      terminalProvider: environment?.terminal.rawValue,
      shellProvider: environment?.shell.rawValue,
      promptProvider: environment?.prompt.rawValue,
      historyProvider: environment?.history.rawValue,
      editorProvider: environment?.editor.rawValue,
      dailyTools: environment.map(EnvironmentPlanCommandRunner.dailyTools) ?? [:],
      presets: environment.map(EnvironmentPlanCommandRunner.presets) ?? [:],
      packagedDefaults: resourcesRoot.path,
      kittyOverride: environment?.kitty.overrideDirectoryURL?.path,
      zshHook: environment?.zsh.hookURL?.path,
      zshHookDigest: nil,
      starshipBehavior: environment?.starship.behaviorURL?.path,
      atuinConfiguration: environment?.atuin.configurationURL?.path,
      neovimConfiguration: environment?.neovim.configurationDirectoryURL?.path,
      renderedArtifacts: [:],
      renderedArtifactDigests: [:],
      renderedDigest: nil,
      proposedInputDigest: nil,
      generation: EnvironmentGenerationReport(
        status: "unavailable",
        message: diagnostic.message
      ),
      transactionStatus: "unknown",
      adoptionEvidenceDigest: nil,
      prerequisites: [],
      entries: [],
      actions: [],
      diagnostics: [diagnostic]
    )
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy environment plan [\(outcome)]:",
      "- profile [\(profileStatus)]: \(profile)",
      "- terminal provider: " + (terminalProvider ?? "unavailable"),
      "- shell provider: " + (shellProvider ?? "unavailable"),
      "- prompt provider: " + (promptProvider ?? "unavailable"),
      "- history provider: " + (historyProvider ?? "unavailable"),
      "- editor provider: " + (editorProvider ?? "unavailable"),
      "- daily tools: "
        + dailyTools.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        .joined(separator: ", "),
      "- presets: "
        + presets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        .joined(separator: ", "),
      "- packaged defaults: \(packagedDefaults)",
      "- Kitty override: " + (kittyOverride ?? "none"),
      "- trusted zsh hook: " + (zshHook ?? "none"),
      "- zsh hook digest: " + (zshHookDigest ?? "none"),
      "- Starship behavior: " + (starshipBehavior ?? "none"),
      "- Atuin configuration: " + (atuinConfiguration ?? "none"),
      "- Neovim configuration: " + (neovimConfiguration ?? "none"),
      "- proposed input digest: " + (proposedInputDigest ?? "unavailable"),
      "- rendered digest: " + (renderedDigest ?? "unavailable"),
      "- generation: \(generation.status)",
      "- transaction: \(transactionStatus)",
      "- adoption evidence: " + (adoptionEvidenceDigest ?? "none"),
    ]
    let neovimArtifactDigests = renderedArtifactDigests.filter {
      $0.key.hasPrefix("neovim/")
    }.sorted { $0.key < $1.key }
    if !neovimArtifactDigests.isEmpty {
      lines.append("Neovim artifacts:")
      lines += neovimArtifactDigests.map { "- \($0.key): \($0.value)" }
    }
    lines += prerequisites.map {
      "- prerequisite \($0.id) [\($0.status)]: \($0.requirement)"
    }
    for entry in entries {
      lines.append("- \(entry.id) [\(entry.status)]: \(entry.path) — \(entry.message)")
      if let evidence = entry.evidence {
        lines.append(
          "  evidence: kind=\(evidence.kind.rawValue)"
            + " device=\(evidence.device.map(String.init) ?? "none")"
            + " inode=\(evidence.inode.map(String.init) ?? "none")"
            + " mode=\(evidence.mode.map(String.init) ?? "none")"
            + " size=\(evidence.size.map(String.init) ?? "none")"
            + " link=\(evidence.linkDestination ?? "none")"
            + " content=\(evidence.contentDigest ?? "none")"
            + " metadata=\(evidence.metadataDigest ?? "none")"
            + " inventory=\(evidence.inventory)"
        )
      }
    }
    lines.append(actions.isEmpty ? "Actions: none" : "Actions:")
    lines += actions.map { "- \($0.id): \($0.message)" }
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines += diagnostics.map { "- \($0.source): error [\($0.code)]: \($0.message)" }
    }
    for (path, contents) in renderedArtifacts.sorted(by: { $0.key < $1.key }) {
      lines.append(
        "Rendered \(path):\n" + "--- begin exact bytes ---\n" + contents
          + "--- end exact bytes ---"
      )
    }
    lines.append("No changes made.")
    return lines.joined(separator: "\n")
  }
}

private struct EnvironmentPlanAction: Encodable {
  let id: String
  let message: String
}

private struct EnvironmentPlanDiagnostic: Encodable {
  let severity = "error"
  let code: String
  let source: String
  let message: String
}
