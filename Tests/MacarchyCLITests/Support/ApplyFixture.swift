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
        let keybindingsStatus =
          requiredAdoptions.keybindings == nil ? "install_required" : "adoption_required"
        let yabaiStatus =
          requiredAdoptions.yabai == nil ? "install_required" : "adoption_required"
        let sketchybarStatus =
          requiredAdoptions.sketchybar == nil ? "install_required" : "adoption_required"
        let desktopActions =
          paletteRefresh
          ? actionsJSON(true, id: DesktopPlanCommandRunner.themePaletteActionID)
          : actionsJSON(plannedStages.contains(.desktop), id: "desktop")
        return try planComponent(
          """
          {
            "outcome":"ready",
            "keybindings":{
              "outcome":"ready",
              "provider_status":"\(keybindingsStatus)",
              "ownership":"absent",
              "adoption_evidence_digest":\(jsonString(requiredAdoptions.keybindings))
            },
            "provider":{
              "entry_point":"\(context.homeDirectory.path)/.config/yabai/yabairc",
              "status":"\(yabaiStatus)",
              "ownership":"absent",
              "adoption_evidence_digest":\(jsonString(requiredAdoptions.yabai))
            },
            "sketchybar":{
              "provider":{
                "entry_point":"\(context.homeDirectory.path)/.config/sketchybar/sketchybarrc",
                "status":"\(sketchybarStatus)",
                "ownership":"absent",
                "adoption_evidence_digest":\(jsonString(requiredAdoptions.sketchybar))
              }
            },
            "actions":\(desktopActions)
          }
          """
        )
      },
      environmentPlanner: { _, _, _ in
        try planComponent(
          """
          {"outcome":"ready","adoption_evidence_digest":\(jsonString(requiredAdoptions.environment)),"entries":[],"actions":\(actionsJSON(plannedStages.contains(.environment), id: "environment"))}
          """
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

private func jsonString(_ value: String?) -> String {
  value.map { "\"\($0)\"" } ?? "null"
}

private func actionsJSON(_ planned: Bool, id: String) -> String {
  planned ? #"[{"id":"\#(id)","message":"planned"}]"# : "[]"
}

func planComponent(_ json: String) throws -> SetupComponentExecution {
  try SetupComponentExecution((output: json, succeeded: true))
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
