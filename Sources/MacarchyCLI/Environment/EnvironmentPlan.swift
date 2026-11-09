import Foundation
import ThemeCore

extension EnvironmentProfile {
  var dailyToolPresentation: [String: String] {
    Dictionary(
      uniqueKeysWithValues: EnvironmentDailyTool.allCases.map {
        ($0.rawValue, $0.isEnabled(in: tools) ? "enabled" : "disabled")
      })
  }

  var presetPresentation: [String: String] {
    Dictionary(
      uniqueKeysWithValues: EnvironmentPreset.allCases.map {
        ($0.rawValue, $0.isEnabled(in: presets) ? "enabled" : "disabled")
      })
  }
}

struct EnvironmentPlanCommandRunner: Sendable {
  static let live = EnvironmentPlanCommandRunner(
    prerequisites: .live,
    requiresActiveTheme: true
  )

  let prerequisites: EnvironmentPrerequisiteInspector
  let requiresActiveTheme: Bool
  let bordersRuntime: EnvironmentBordersRuntime
  let alacrittyVersion: @Sendable () throws -> [Int]
  let ghosttyVersion: @Sendable () throws -> [Int]
  let zedVersion: @Sendable () throws -> [Int]

  init(
    prerequisites: EnvironmentPrerequisiteInspector = .live,
    requiresActiveTheme: Bool = false,
    bordersRuntime: EnvironmentBordersRuntime = .live,
    alacrittyVersion: @escaping @Sendable () throws -> [Int] = AlacrittyAdapter.installedVersion,
    ghosttyVersion: @escaping @Sendable () throws -> [Int] = GhosttyAdapter.installedVersion,
    zedVersion: @escaping @Sendable () throws -> [Int] = ZedAdapter.installedVersion
  ) {
    self.prerequisites = prerequisites
    self.requiresActiveTheme = requiresActiveTheme
    self.bordersRuntime = bordersRuntime
    self.alacrittyVersion = alacrittyVersion
    self.ghosttyVersion = ghosttyVersion
    self.zedVersion = zedVersion
  }

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL? = nil,
    json: Bool,
    profile suppliedProfile: PortableProfile? = nil,
    bootstrapTheme: ThemePackage? = nil,
    nativeStarters: [EnvironmentNativeSeed] = []
  ) throws -> CommandExecution {
    let plan = try report(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      profile: suppliedProfile,
      bootstrapTheme: bootstrapTheme,
      nativeStarters: nativeStarters
    )
    return (try plan.render(json: json), plan.succeeded)
  }

  func report(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL? = nil,
    profile suppliedProfile: PortableProfile? = nil,
    bootstrapTheme: ThemePackage? = nil,
    nativeStarters: [EnvironmentNativeSeed] = []
  ) throws -> EnvironmentPlanReport {
    let profile: PortableProfile
    if let suppliedProfile {
      profile = suppliedProfile
    } else {
      do {
        profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
      } catch {
        return EnvironmentPlanReport.blocked(
          profile: profileURL,
          resourcesRoot: resourcesRoot,
          diagnostic: PlanDiagnostic(
            code: "profile_invalid",
            source: profileURL.path,
            message: String(describing: error)
          )
        )
      }
    }

    let composition: EnvironmentComposition
    let starterPlans: [EnvironmentNativeSeed.Plan]
    do {
      starterPlans = try nativeStarters.map { try $0.plan() }
      composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot,
        profile: profile,
        stateRoot: stateRoot,
        proposedNativeFiles: UnifiedSetupNativeStarters.proposedFiles(starterPlans)
      )
    } catch {
      let source = (error as? EnvironmentConfigurationError)?.sourceURL ?? resourcesRoot
      return EnvironmentPlanReport.blocked(
        profile: profileURL,
        profileStatus: profile.sourceURL == nil ? "absent_default" : "loaded",
        environment: profile.environment,
        resourcesRoot: resourcesRoot,
        diagnostic: PlanDiagnostic(
          code: "environment_configuration_invalid",
          source: source.path,
          message: String(describing: error)
        )
      )
    }

    let provider = homeDirectory.map {
      EnvironmentProviderInspector(
        bootstrapTheme: bootstrapTheme,
        proposedNativeSources: Set(starterPlans.map(\.destination)),
        alacrittyVersion: alacrittyVersion, ghosttyVersion: ghosttyVersion,
        zedVersion: zedVersion
      ).inspectIncludingBordersRuntime(
        composition: composition,
        homeDirectory: $0,
        stateRoot: stateRoot,
        runtime: bordersRuntime
      )
    }
    var prerequisiteState =
      homeDirectory.map {
        prerequisites.inspect(composition.profile, $0)
      } ?? []
    if try EnvironmentStateStore(stateRoot: stateRoot).hasUnverifiedSpicetifyRecovery() {
      prerequisiteState.append(
        EnvironmentPrerequisiteStatus(
          id: "spicetify_runtime_restoration", status: "manual_required",
          requirement: EnvironmentStateStore.spicetifyRecoveryMessage,
          remediation: "Repair Spicetify manually before enabling the preset."))
    }
    let generation = EnvironmentGenerationStore(stateRoot: stateRoot).inspect(expected: composition)
    let themeDiagnostic: PlanDiagnostic?
    if requiresActiveTheme,
      !composition.profile.selectedThemeAdapterIDs.isEmpty || composition.profile.presets.slack
    {
      do {
        _ = try ThemeGenerationReader(root: stateRoot).activeManifest()
        themeDiagnostic = nil
      } catch {
        themeDiagnostic = PlanDiagnostic(
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
        [PlanDiagnostic(code: "provider_blocked", source: stateRoot.path, message: $0)]
      } ?? []
    if let themeDiagnostic { diagnostics.append(themeDiagnostic) }
    for prerequisite in prerequisiteState
    where prerequisite.id == "spicetify_preparation" && prerequisite.status == "missing" {
      diagnostics.append(
        PlanDiagnostic(
          code: "spicetify_unprepared", source: "spicetify",
          message: prerequisite.requirement))
    }
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
    let nativeNeovimRoot = homeDirectory.flatMap { home -> URL? in
      let migration = EnvironmentNeovimMigration(homeDirectory: home, stateRoot: stateRoot)
      return migration.nativeTarget(in: provider?.ownership)
        ?? composition.profile.neovim.nativeConfigurationDirectoryURL
    }
    let freshNativeNeovim =
      try homeDirectory.map {
        try EnvironmentNeovimPreparer.requiresFreshNativePreparation(
          profile: composition.profile, ownership: provider?.ownership,
          homeDirectory: $0, stateRoot: stateRoot, resourcesRoot: resourcesRoot,
          proposedStarters: starterPlans)
      } ?? false
    return EnvironmentPlanReport(
      outcome: blocked ? "blocked" : "ready",
      profile: profileURL.path,
      profileStatus: profile.sourceURL == nil ? "absent_default" : "loaded",
      terminalProvider: composition.profile.terminal.rawValue,
      focusRingProvider: composition.profile.focusRing.rawValue,
      shellProvider: composition.profile.shell.rawValue,
      promptProvider: composition.profile.prompt.rawValue,
      historyProvider: composition.profile.history.rawValue,
      editorProvider: composition.profile.editor.rawValue,
      dailyTools: composition.profile.dailyToolPresentation,
      presets: composition.profile.presetPresentation,
      packagedDefaults: resourcesRoot.path,
      kittyOverride: composition.kittyOverrideURL?.path,
      kittyConfiguration: composition.profile.kitty.configurationURL?.path,
      zshHook: composition.zshHookURL?.path,
      zshHookDigest: composition.zshHookDigest,
      zshConfiguration: composition.profile.zsh.configurationURL?.path,
      starshipBehavior: homeDirectory.flatMap { home in
        let migration = EnvironmentNativeFileMigration(
          provider: .starship, homeDirectory: home, stateRoot: stateRoot)
        return migration.nativeTarget(in: provider?.ownership)?.path
      } ?? composition.starshipBehaviorURL?.path,
      atuinConfiguration: homeDirectory.flatMap { home in
        let migration = EnvironmentNativeFileMigration(
          provider: .atuin, homeDirectory: home, stateRoot: stateRoot)
        return migration.nativeTarget(in: provider?.ownership)?.path
      } ?? composition.atuinConfigurationURL?.path,
      neovimConfiguration: nativeNeovimRoot?.path ?? composition.neovimConfigurationURL?.path,
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
        nativeNeovim: nativeNeovimRoot != nil,
        freshNativeNeovim: freshNativeNeovim,
        adoptionRequired: provider?.adoptionEvidenceDigest != nil,
        restorationRequired: provider?.entries.contains {
          $0.status == .restorationRequired
        } == true
      ),
      diagnostics: diagnostics
    )
  }

  private static func actions(
    for profile: EnvironmentProfile,
    nativeNeovim: Bool,
    freshNativeNeovim: Bool,
    adoptionRequired: Bool,
    restorationRequired: Bool
  ) -> [PlanAction] {
    var actions: [PlanAction] = []
    if !profile.scripts.run.isEmpty {
      actions.append(
        PlanAction(
          id: "run_user_scripts",
          message:
            "Run after theme activation and at teardown: "
            + profile.scripts.run.map(\.path).joined(separator: ", ")))
    }
    if profile.focusRing == .lean {
      actions.append(
        PlanAction(
          id: "configure_lean_focus",
          message:
            "Run the opt-in Macarchy-owned focus service with live canonical palette acknowledgement. Suspend only already-owned Borders; selecting borders switches back. Physical/display/Spaces/app/soak limits remain."
        ))
    }
    if profile.focusRing == .borders {
      actions.append(
        PlanAction(
          id: "configure_borders",
          message:
            "Own the native Borders entry and Homebrew service; request the canonical palette live. Adoption and restoration of running native configuration require restart; settings have no readback."
        ))
    }
    if profile.terminal == .kitty {
      actions.append(
        PlanAction(
          id: "configure_kitty",
          message: "Configure Kitty through the managed environment generation."
        )
      )
    }
    if profile.shell == .zsh {
      actions.append(
        PlanAction(
          id: "configure_zsh",
          message: "Configure zsh through the managed environment generation."
        )
      )
    }
    if profile.prompt == .starship {
      actions.append(
        PlanAction(
          id: "configure_starship",
          message: "Configure Starship behavior while retaining Macarchy palette ownership."
        )
      )
    }
    if profile.history == .atuin {
      actions.append(
        PlanAction(
          id: "configure_atuin",
          message: "Configure Atuin behavior while retaining Macarchy theme ownership."
        )
      )
    }
    if profile.editor == .neovim {
      actions.append(
        PlanAction(
          id: "configure_neovim",
          message: nativeNeovim
            ? "Preserve writable Neovim behavior and Lazy lock; update only canonical theme integration."
            : "Configure immutable Neovim behavior and canonical theme integration. Use environment migrate-neovim before interactive Lazy changes."
        )
      )
      if freshNativeNeovim {
        actions.append(
          PlanAction(
            id: "prepare_fresh_neovim_plugins",
            message:
              "First connection of the unchanged curated Neovim starter: download/build and verify its locked plugins with a 180-second limit using a temporary config copy. Preserve user files and lock; plugin/cache changes survive rollback. Existing native configurations and ordinary reapply skip this step."
          )
        )
      } else if !nativeNeovim {
        actions.append(
          PlanAction(
            id: "restore_neovim_plugins",
            message: "Restore the selected Neovim plugin graph from its lock using Lazy."
          )
        )
      }
    }
    for tool in EnvironmentDailyTool.allCases where tool.isEnabled(in: profile.tools) {
      actions.append(tool.planAction)
    }
    // Plan JSON lists preset actions in this order.
    for preset in [
      EnvironmentPreset.zed, .alacritty, .ghostty, .tuicr, .codex, .herdr, .pi, .spicetify, .slack,
    ]
    where preset.isEnabled(in: profile.presets) {
      actions.append(preset.planAction)
    }
    if !actions.isEmpty {
      actions.insert(
        PlanAction(
          id: "publish_environment_generation",
          message: "Publish the deterministic daily tool generation."
        ),
        at: 0
      )
    }
    if adoptionRequired {
      actions.insert(
        PlanAction(
          id: "adopt_provider_entries",
          message: "Adopt every reviewed external provider entry as one aggregate transaction."
        ),
        at: 0
      )
    }
    if restorationRequired {
      actions.insert(
        PlanAction(
          id: "restore_disabled_provider_entries",
          message: "Restore adopted entries for roles that are now disabled."
        ),
        at: 0
      )
    }
    return actions
  }
}

struct EnvironmentPlanReport: CommandReport, Sendable {
  let schemaVersion = 1
  let operation = "environment_plan"
  let outcome: String
  let mutated = false
  let profile: String
  let profileStatus: String
  let terminalProvider: String?
  let focusRingProvider: String?
  let shellProvider: String?
  let promptProvider: String?
  let historyProvider: String?
  let editorProvider: String?
  let dailyTools: [String: String]
  let presets: [String: String]
  let packagedDefaults: String
  let kittyOverride: String?
  let kittyConfiguration: String?
  let zshHook: String?
  let zshHookDigest: String?
  let zshConfiguration: String?
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
  let actions: [PlanAction]
  let diagnostics: [PlanDiagnostic]

  /// A blocked plan is the only failed outcome.
  var succeeded: Bool { outcome != "blocked" }

  static func blocked(
    profile: URL,
    profileStatus: String = "invalid",
    environment: EnvironmentProfile? = nil,
    resourcesRoot: URL,
    diagnostic: PlanDiagnostic
  ) -> EnvironmentPlanReport {
    EnvironmentPlanReport(
      outcome: "blocked",
      profile: profile.path,
      profileStatus: profileStatus,
      terminalProvider: environment?.terminal.rawValue,
      focusRingProvider: environment?.focusRing.rawValue,
      shellProvider: environment?.shell.rawValue,
      promptProvider: environment?.prompt.rawValue,
      historyProvider: environment?.history.rawValue,
      editorProvider: environment?.editor.rawValue,
      dailyTools: environment?.dailyToolPresentation ?? [:],
      presets: environment?.presetPresentation ?? [:],
      packagedDefaults: resourcesRoot.path,
      kittyOverride: environment?.kitty.overrideDirectoryURL?.path,
      kittyConfiguration: environment?.kitty.configurationURL?.path,
      zshHook: environment?.zsh.hookURL?.path,
      zshHookDigest: nil,
      zshConfiguration: environment?.zsh.configurationURL?.path,
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

  func renderText() throws -> String {
    var lines: [String] = [
      "Macarchy environment plan [\(outcome)]:",
      "- profile [\(profileStatus)]: \(profile)",
      "- terminal provider: " + (terminalProvider ?? "unavailable"),
      "- focus-ring provider: " + (focusRingProvider ?? "unavailable"),
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
      "- live Kitty configuration (user-owned): " + (kittyConfiguration ?? "none"),
      "- trusted zsh hook: " + (zshHook ?? "none"),
      "- zsh hook digest: " + (zshHookDigest ?? "none"),
      "- live zsh configuration (user-owned): " + (zshConfiguration ?? "none"),
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
      lines.append("- \(entry.id) [\(entry.status.rawValue)]: \(entry.path) — \(entry.message)")
      if let evidence = entry.evidence {
        let evidenceParts: [String] = [
          "  evidence: kind=\(evidence.kind.rawValue)",
          " device=\(evidence.device.map(String.init) ?? "none")",
          " inode=\(evidence.inode.map(String.init) ?? "none")",
          " mode=\(evidence.mode.map(String.init) ?? "none")",
          " size=\(evidence.size.map(String.init) ?? "none")",
          " link=\(evidence.linkDestination ?? "none")",
          " content=\(evidence.contentDigest ?? "none")",
          " metadata=\(evidence.metadataDigest ?? "none")",
          " inventory=\(evidence.inventory)",
        ]
        lines.append(evidenceParts.joined())
      }
    }
    lines += PlanAction.renderLines(actions)
    lines += PlanDiagnostic.renderLines(diagnostics)
    for (path, contents) in renderedArtifacts.sorted(by: { $0.key < $1.key }) {
      lines.append(renderExactBytes(path, contents))
    }
    lines.append("No changes made.")
    return lines.joined(separator: "\n")
  }
}
