import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

final class ApplyFixture: @unchecked Sendable {
  let root: URL
  let home: URL
  let state: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-unified-setup-apply-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
  }

  var context: UnifiedSetupPlanContext {
    UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory),
      keybindingsResourcesRoot: root.appending(path: "Keybindings"),
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: root.appending(path: "Environment"),
      profileURL: state.appending(path: "profile.toml"),
      profileRequired: false,
      machineProfileURL: state.appending(path: "machine.toml"),
      machineProfileRequired: false,
      stateRoot: state,
      homeDirectory: home
    )
  }

  func writeMachineProfile(_ text: String) throws {
    try text.write(
      to: state.appending(path: "machine.toml"),
      atomically: true,
      encoding: .utf8
    )
  }

  func activateSetupOwnedTheme() throws -> GenerationManifest {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")
    )
    let manifest = try ThemeActivator(root: state).activate(package: package)
    try SetupCoreOwnershipStore(stateRoot: state).write(
      SetupCoreOwnership(themeGenerationID: manifest.generationID, originalAppearance: .light)
    )
    return manifest
  }

  func runner(
    available: @escaping @Sendable (DependencyCapability) -> Bool,
    requiredAdoptions: UnifiedSetupAdoptionApprovals = .none,
    plannedStages: Set<SetupStage> = [],
    paletteRefresh: Bool = false,
    preferences: PreferencesLifecycle = .live,
    themeInspection: @escaping UnifiedSetupThemeInspection = {
      model, ownership, _ in
      let active = model.theme.currentGenerationID
      let succeeded = ownership.map { $0.themeGenerationID == active } ?? true
      return UnifiedSetupThemeLifecycleStatus(
        succeeded: succeeded,
        status: active == nil ? "absent" : ownership == nil ? "external" : "managed",
        generationID: active,
        message: succeeded ? "current" : "drifted"
      )
    },
    packages: SetupBrewfile = SetupBrewfile(packages: []),
    inventory: @escaping @Sendable () -> HomebrewPackageObservation = {
      .init(packages: [], issues: [])
    },
    installer: HomebrewBundleInstaller = .init(apply: { _, _ in
      Issue.record("Homebrew must not run")
      return .init(status: 1, diagnostic: "unexpected")
    }),
    writePlan: @escaping @Sendable (String) throws -> Void = { _ in },
    theme: @escaping UnifiedSetupApplyCommandRunner.ThemeApply,
    themeRefresh: @escaping UnifiedSetupApplyCommandRunner.ThemeRefresh = { _, _, _, _, _ in
      Issue.record("No theme reactivation reviewed")
      return try applyComponent("{}")
    },
    desktop: @escaping UnifiedSetupApplyCommandRunner.ComponentApply,
    environment: @escaping UnifiedSetupApplyCommandRunner.ComponentApply,
    transactionTeardown: UnifiedSetupTeardownCommandRunner? = nil,
    faultInjector: @escaping @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void = {
      _ in
    }
  ) -> UnifiedSetupApplyCommandRunner {
    var planner = planner(
      available: available,
      requiredAdoptions: requiredAdoptions,
      plannedStages: plannedStages,
      paletteRefresh: paletteRefresh,
      preferences: preferences
    )
    planner.standardBrewfile = { _ in packages }
    planner.packageInventoryReader = inventory
    return UnifiedSetupApplyCommandRunner(
      planner: planner,
      themeInspection: themeInspection,
      packageInstaller: installer,
      capabilityIsAvailable: available,
      writePreMutationPlan: writePlan,
      themeApply: theme,
      themeRefresh: themeRefresh,
      desktopApply: desktop,
      environmentApply: environment,
      transactionTeardown: transactionTeardown
        ?? UnifiedSetupTeardownCommandRunner(
          planner: planner,
          environmentTeardown: { _, _, _ in
            try applyComponent(
              #"{"outcome":"no_change","mutated":false,"message":"environment"}"#
            )
          },
          desktopTeardown: { _, _, _ in
            try applyComponent(
              #"{"outcome":"no_change","mutated":false,"message":"desktop"}"#
            )
          },
          themeTeardown: { _, _, _, _ in .noChange("theme") }
        ),
      faultInjector: faultInjector
    )
  }

  func planner(
    available: @escaping @Sendable (DependencyCapability) -> Bool = { _ in true },
    requiredAdoptions: UnifiedSetupAdoptionApprovals = .none,
    plannedStages: Set<SetupStage> = [],
    paletteRefresh: Bool = false,
    preferences: PreferencesLifecycle = .live
  ) -> UnifiedSetupPlanCommandRunner {
    UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: available,
      desktopPlanner: { context, _ in
        func status(_ adoption: String?) -> DesktopProviderPlanStatus {
          adoption == nil ? .installRequired : .adoptionRequired
        }
        let desktopActions =
          paletteRefresh
          ? plannedActions(true, id: DesktopPlanCommandRunner.themePaletteActionID)
          : plannedActions(plannedStages.contains(.desktop), id: "desktop")
        return desktopPlanStub(
          keybindings: keybindingPlanStub(
            providerStatus: status(requiredAdoptions.keybindings).rawValue,
            ownership: "absent",
            adoptionEvidenceDigest: requiredAdoptions.keybindings
          ),
          provider: providerPlanStub(
            "\(context.homeDirectory.path)/.config/yabai/yabairc",
            status: status(requiredAdoptions.yabai),
            ownership: .absent,
            adoptionEvidenceDigest: requiredAdoptions.yabai
          ),
          sketchyBar: providerPlanStub(
            "\(context.homeDirectory.path)/.config/sketchybar/sketchybarrc",
            status: status(requiredAdoptions.sketchybar),
            ownership: .absent,
            adoptionEvidenceDigest: requiredAdoptions.sketchybar
          ),
          actions: desktopActions
        )
      },
      environmentPlanner: { _, _, _ in
        environmentPlanStub(
          adoptionEvidenceDigest: requiredAdoptions.environment,
          actions: plannedActions(plannedStages.contains(.environment), id: "environment")
        )
      },
      packageInventoryReader: { HomebrewPackageObservation(packages: [], issues: []) },
      standardBrewfile: { _ in
        try SetupBrewfile.read(at: repositoryRoot.appending(path: "Environment/Brewfile"))
      },
      preferences: preferences
    )
  }

  func cleanup(expectedThemeGenerationID: String? = nil) {
    if let expectedThemeGenerationID {
      _ = try? ThemeActivator(root: state).deactivate(
        expectedGenerationID: expectedThemeGenerationID,
        dryRun: false
      )
    }
    try? FileManager.default.removeItem(at: root)
  }
}

private func plannedActions(_ planned: Bool, id: String) -> [PlanAction] {
  planned ? [PlanAction(id: id, message: "planned")] : []
}

/// A desktop plan whose projected fields are given; every other field is a placeholder.
func desktopPlanStub(
  outcome: String = "ready",
  keybindings: DesktopKeybindingPlan? = keybindingPlanStub(),
  provider: DesktopProviderPlanInspection = providerPlanStub("/yabai"),
  sketchyBar: DesktopProviderPlanInspection? = nil,
  actions: [PlanAction] = [],
  diagnostics: [PlanDiagnostic] = []
) -> SetupComponentPlan<DesktopPlanReport> {
  SetupComponentPlan(
    DesktopPlanReport(
      outcome: outcome,
      profile: "/profile.toml",
      profileStatus: "loaded",
      desktopProvider: nil,
      topBarProvider: nil,
      packagedDefaults: "/Desktop",
      hook: nil,
      hookDigest: nil,
      behaviorAuthority: "managed",
      settings: nil,
      renderedYabairc: nil,
      renderedDigest: nil,
      proposedInputDigest: nil,
      currentGenerationID: nil,
      currentGenerationStatus: "missing",
      provider: provider,
      sketchyBar: sketchyBar.map {
        DesktopSketchyBarPlanReport(
          packagedDefaults: "/Desktop",
          settings: nil,
          layout: nil,
          automaticClock: nil,
          spaceModule: nil,
          moduleCapabilities: nil,
          hook: nil,
          hookDigest: nil,
          behaviorAuthority: "managed",
          renderedArtifacts: nil,
          renderedDigest: nil,
          proposedInputDigest: nil,
          currentGenerationID: nil,
          currentGenerationStatus: "missing",
          provider: $0,
          themePalette: SketchyBarPalettePlanInspection(
            status: .current, generationID: nil, message: "palette")
        )
      },
      prerequisites: [],
      keybindings: keybindings,
      actions: actions,
      diagnostics: diagnostics
    ))
}

func keybindingPlanStub(
  providerStatus: String = "managed",
  ownership: String = "managed",
  adoptionEvidenceDigest: String? = nil
) -> DesktopKeybindingPlan {
  DesktopKeybindingPlan(
    outcome: "ready",
    effectiveStatus: "current",
    message: "keybindings",
    generationID: nil,
    providerStatus: providerStatus,
    ownership: ownership,
    adoptionEvidenceDigest: adoptionEvidenceDigest,
    transactionStatus: "clear"
  )
}

func providerPlanStub(
  _ entryPoint: String,
  status: DesktopProviderPlanStatus = .managed,
  ownership: DesktopProviderOwnership = .managed,
  adoptionEvidenceDigest: String? = nil
) -> DesktopProviderPlanInspection {
  DesktopProviderPlanInspection(
    status: status,
    ownership: ownership,
    entryPoint: entryPoint,
    originalTarget: nil,
    source: nil,
    message: "provider",
    adoptionEvidenceDigest: adoptionEvidenceDigest
  )
}

/// An environment plan whose projected fields are given; every other field is a placeholder.
func environmentPlanStub(
  outcome: String = "ready",
  adoptionEvidenceDigest: String? = nil,
  entries: [EnvironmentEntryInspection] = [],
  actions: [PlanAction] = [],
  diagnostics: [PlanDiagnostic] = []
) -> SetupComponentPlan<EnvironmentPlanReport> {
  SetupComponentPlan(
    EnvironmentPlanReport(
      outcome: outcome,
      profile: "/profile.toml",
      profileStatus: "loaded",
      terminalProvider: nil,
      focusRingProvider: nil,
      shellProvider: nil,
      promptProvider: nil,
      historyProvider: nil,
      editorProvider: nil,
      dailyTools: [:],
      presets: [:],
      packagedDefaults: "/Environment",
      kittyOverride: nil,
      kittyConfiguration: nil,
      zshHook: nil,
      zshHookDigest: nil,
      zshConfiguration: nil,
      starshipBehavior: nil,
      atuinConfiguration: nil,
      neovimConfiguration: nil,
      renderedArtifacts: [:],
      renderedArtifactDigests: [:],
      renderedDigest: nil,
      proposedInputDigest: nil,
      generation: EnvironmentGenerationReport(status: "missing", message: "environment"),
      transactionStatus: "clear",
      adoptionEvidenceDigest: adoptionEvidenceDigest,
      prerequisites: [],
      entries: entries,
      actions: actions,
      diagnostics: diagnostics
    ))
}

func applyComponent(
  _ json: String,
  succeeded: Bool = true
) throws -> SetupComponentExecution {
  try SetupComponentExecution((output: json, succeeded: succeeded))
}

func teardownComponent(
  dryRun: Bool,
  mutated: Bool,
  previewOutcome: String = "planned"
) throws -> SetupComponentExecution {
  try applyComponent(
    """
    {"outcome":"\(dryRun ? previewOutcome : mutated ? "restored" : "no_change")","mutated":\(mutated),"message":"component"}
    """
  )
}
