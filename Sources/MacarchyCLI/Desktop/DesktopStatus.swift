import Foundation
import ThemeCore

struct DesktopStatusCommandRunner: Sendable {
  let lifecycle: YabaiLifecycleController
  let sketchyBarLifecycle: SketchyBarLifecycleController
  let sketchyBarCoreRuntime: SketchyBarCoreRuntimeController?
  let keybindings: DesktopKeybindingOrchestrator?
  let theme: DesktopThemeController?

  static let live = DesktopStatusCommandRunner(
    lifecycle: .live,
    keybindings: .live,
    theme: .live
  )

  init(
    lifecycle: YabaiLifecycleController,
    sketchyBarLifecycle: SketchyBarLifecycleController = .live,
    sketchyBarCoreRuntime: SketchyBarCoreRuntimeController? = nil,
    keybindings: DesktopKeybindingOrchestrator?,
    theme: DesktopThemeController?
  ) {
    self.lifecycle = lifecycle
    self.sketchyBarLifecycle = sketchyBarLifecycle
    self.sketchyBarCoreRuntime = sketchyBarCoreRuntime
    self.keybindings = keybindings
    self.theme = theme
  }

  func execute(
    resourcesRoot: URL,
    keybindingsResourcesRoot: URL = RuntimeEnvironment.live.builtInKeybindingsURL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    json: Bool,
    consumerPaths: ThemeConsumerPaths? = nil,
    macarchyExecutableURL: URL = RuntimeEnvironment.live.executableURL,
    profile suppliedProfile: PortableProfile? = nil
  ) throws -> (output: String, succeeded: Bool) {
    let desired: DesktopDesiredState?
    var diagnostics: [String] = []
    do {
      desired = try DesktopDesiredState.load(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        macarchyExecutableURL: macarchyExecutableURL,
        profile: suppliedProfile
      )
    } catch {
      desired = nil
      diagnostics.append(String(describing: error))
    }
    let aggregatePending: Bool
    do {
      aggregatePending = try DesktopAggregateTransactionStore(stateRoot: stateRoot).read() != nil
    } catch {
      aggregatePending = true
      diagnostics.append(String(describing: error))
    }
    let yabaiEnabled = desired?.yabaiComposition != nil
    let transactionPending = YabaiTransactionStore(stateRoot: stateRoot).exists
    let generation = YabaiGenerationInspector(stateRoot: stateRoot).inspect()
    let provider = YabaiProviderPlanInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      enabled: yabaiEnabled,
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
      yabaiEnabled
      ? desired?.yabaiComposition.map(lifecycle.inspect) ?? .stopped
      : .disabled

    let generationAgrees =
      generation.status == .current
      && generation.manifest?.inputDigest == desired?.yabaiComposition?.inputDigest
      && generation.manifest?.renderedDigest == desired?.yabaiComposition?.renderedDigest
    let ownershipAgrees = ownership?.generationID == generation.generationID
    let lifecycleAgrees =
      lifecycleEvidence?.generationID == generation.generationID
      && lifecycleEvidence?.runtime.agreesWithCurrentProcess(runtime) == true
    let converged =
      yabaiEnabled && !transactionPending && diagnostics.isEmpty
      && provider.status == .managed && generationAgrees && ownershipAgrees && lifecycleAgrees
      && (runtime.status == .converged || runtime.status == .partial)
    let disabledClean =
      !yabaiEnabled
      && (provider.status == .disabled || provider.status == .externallyManaged)
      && !transactionPending && diagnostics.isEmpty
    let sketchyBarEnabled = desired?.sketchyBarComposition != nil
    let sketchyBarTransactionStore = SketchyBarTransactionStore(stateRoot: stateRoot)
    let sketchyBarTransactionPending: Bool
    do {
      sketchyBarTransactionPending = try sketchyBarTransactionStore.read() != nil
    } catch {
      sketchyBarTransactionPending = false
      diagnostics.append(String(describing: error))
    }
    let sketchyBarGeneration = SketchyBarGenerationInspector(stateRoot: stateRoot).inspect()
    let sketchyBarProvider = SketchyBarProviderPlanInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      enabled: sketchyBarEnabled,
      generation: sketchyBarGeneration,
      transactionPending: sketchyBarTransactionPending
    )
    let sketchyBarPalette = SketchyBarPalettePlanInspector().inspect(
      stateRoot: stateRoot,
      enabled: sketchyBarEnabled
    )
    let sketchyBarOwnership: SketchyBarOwnershipRecord?
    let sketchyBarEvidence: SketchyBarLifecycleEvidence?
    do {
      sketchyBarOwnership = try SketchyBarOwnershipStore(stateRoot: stateRoot).read()
    } catch {
      sketchyBarOwnership = nil
      diagnostics.append(String(describing: error))
    }
    do {
      sketchyBarEvidence = try SketchyBarLifecycleEvidenceStore(stateRoot: stateRoot).read()
    } catch {
      sketchyBarEvidence = nil
      diagnostics.append(String(describing: error))
    }
    var sketchyBarRuntime: SketchyBarRuntimeInspection?
    var sketchyBarCore: SketchyBarCoreRuntimeInspection?
    if sketchyBarEnabled,
      sketchyBarProvider.status == .managed,
      !sketchyBarTransactionPending,
      let composition = desired?.sketchyBarComposition
    {
      do {
        _ = try sketchyBarLifecycle.preflight()
        let inspected = try sketchyBarLifecycle.inspect()
        sketchyBarRuntime = inspected
        if inspected.status == .running {
          let controller = sketchyBarCoreRuntime ?? .live(stateRoot: stateRoot)
          sketchyBarCore = controller.inspect(composition)
        }
      } catch {
        diagnostics.append(String(describing: error))
      }
    }
    let sketchyBarGenerationAgrees =
      sketchyBarGeneration.status == .current
      && sketchyBarGeneration.manifest?.inputDigest
        == desired?.sketchyBarComposition?.inputDigest
      && sketchyBarGeneration.manifest?.renderedDigest
        == desired?.sketchyBarComposition?.renderedDigest
    let sketchyBarOwnershipAgrees =
      sketchyBarOwnership?.generationID == sketchyBarGeneration.generationID
    let sketchyBarLifecycleAgrees =
      sketchyBarEvidence?.generationID == sketchyBarGeneration.generationID
      && sketchyBarEvidence?.runtime == sketchyBarRuntime
      && sketchyBarCore.map {
        sketchyBarEvidence?.coreRuntime.agreesWithProviderRuntime($0) == true
      } == true
    let sketchyBarCoreAgrees =
      sketchyBarCore?.status == .converged
      || (sketchyBarCore?.status == .partial
        && desired?.sketchyBarComposition?.hookURL != nil)
    let sketchyBarConverged =
      sketchyBarEnabled && !sketchyBarTransactionPending && diagnostics.isEmpty
      && sketchyBarProvider.status == .managed && sketchyBarPalette.status == .current
      && sketchyBarGenerationAgrees && sketchyBarOwnershipAgrees && sketchyBarLifecycleAgrees
      && sketchyBarRuntime?.status == .running
      && sketchyBarCoreAgrees
    let sketchyBarDisabledClean =
      !sketchyBarEnabled
      && (sketchyBarProvider.status == .disabled
        || sketchyBarProvider.status == .externallyManaged)
      && sketchyBarGeneration.status == .missing
      && sketchyBarOwnership == nil && sketchyBarEvidence == nil
      && !sketchyBarTransactionPending && diagnostics.isEmpty
    let keybindingState: DesktopKeybindingPlan?
    if let keybindings, desired != nil {
      do {
        keybindingState = try keybindings.plan(
          resourcesRoot: keybindingsResourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          profile: desired?.profile
        )
      } catch {
        keybindingState = nil
        diagnostics.append(String(describing: error))
      }
    } else {
      keybindingState = nil
    }
    let keybindingsConverged =
      if keybindings == nil {
        true
      } else if yabaiEnabled {
        keybindingState?.effectiveStatus == "converged"
          && keybindingState?.transactionPending == false
      } else {
        keybindingState?.providerStatus != "managed"
          && keybindingState?.transactionPending == false
      }
    let themeState: [DesktopThemeAdapterStatus]
    if let theme, let consumerPaths, let profile = desired?.profile {
      var adapterIDs = [String]()
      if profile.desktop.provider == .yabaiSkhd { adapterIDs.append("wallpaper") }
      if profile.topBar == .sketchybar { adapterIDs.append("sketchybar") }
      if adapterIDs.isEmpty {
        themeState = []
      } else {
        do {
          themeState = try theme.inspect(adapterIDs.sorted(), stateRoot, consumerPaths)
        } catch {
          themeState = []
          diagnostics.append(String(describing: error))
        }
      }
    } else {
      themeState = []
    }
    let themeConverged =
      theme == nil || consumerPaths == nil
      || (themeState.count
        == (yabaiEnabled ? 1 : 0) + (sketchyBarEnabled ? 1 : 0)
        && themeState.allSatisfy { $0.status == "ready" })
    let succeeded =
      (converged || disabledClean)
      && (sketchyBarConverged || sketchyBarDisabledClean)
      && keybindingsConverged && themeConverged && !aggregatePending
    let recoveryRequired =
      aggregatePending || transactionPending || sketchyBarTransactionPending
      || keybindingState?.transactionPending == true
    let outcome =
      succeeded
      ? (disabledClean && sketchyBarDisabledClean
        ? "disabled"
        : runtime.status == .partial || sketchyBarCore?.status == .partial
          ? "partial" : "converged")
      : recoveryRequired ? "recovery_required" : "drifted"
    let report = DesktopStatusReport(
      outcome: outcome,
      desktopProvider: desired?.profile.desktop.provider.rawValue,
      topBarProvider: desired?.profile.topBar.rawValue,
      generationStatus: generation.status.rawValue,
      generationID: generation.generationID,
      generationAgrees: generationAgrees,
      ownershipAgrees: ownershipAgrees,
      provider: provider,
      runtime: runtime,
      lifecycleGenerationID: lifecycleEvidence?.generationID,
      transactionPending: transactionPending,
      sketchyBar: DesktopSketchyBarStatusReport(
        generationStatus: sketchyBarGeneration.status.rawValue,
        generationID: sketchyBarGeneration.generationID,
        generationAgrees: sketchyBarGenerationAgrees,
        ownershipAgrees: sketchyBarOwnershipAgrees,
        provider: sketchyBarProvider,
        palette: sketchyBarPalette,
        runtime: sketchyBarRuntime,
        coreRuntime: sketchyBarCore,
        lifecycleGenerationID: sketchyBarEvidence?.generationID,
        transactionPending: sketchyBarTransactionPending
      ),
      keybindings: keybindingState,
      theme: themeState,
      aggregateTransactionPending: aggregatePending,
      diagnostics: diagnostics
    )
    return (try report.render(json: json), succeeded)
  }
}

private struct DesktopStatusReport: Encodable {
  let schemaVersion = 2
  let operation = "desktop_status"
  let outcome: String
  let desktopProvider: String?
  let topBarProvider: String?
  let generationStatus: String
  let generationID: String?
  let generationAgrees: Bool
  let ownershipAgrees: Bool
  let provider: YabaiProviderPlanInspection
  let runtime: YabaiRuntimeInspection
  let lifecycleGenerationID: String?
  let transactionPending: Bool
  let sketchyBar: DesktopSketchyBarStatusReport
  let keybindings: DesktopKeybindingPlan?
  let theme: [DesktopThemeAdapterStatus]
  let aggregateTransactionPending: Bool
  let diagnostics: [String]

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy desktop status [\(outcome)]:",
      "- desktop provider: \(desktopProvider ?? "unavailable")",
      "- top-bar provider: \(topBarProvider ?? "unavailable")",
      "- generation [\(generationStatus)]: \(generationID ?? "none")",
      "- desired generation agreement: \(generationAgrees ? "yes" : "no")",
      "- ownership generation agreement: \(ownershipAgrees ? "yes" : "no")",
      "- provider [\(provider.status.rawValue)]: \(provider.message)",
      "- runtime [\(runtime.status.rawValue)]: \(runtime.message)",
      "- lifecycle generation: \(lifecycleGenerationID ?? "none")",
      "- interrupted transaction: \(transactionPending ? "yes" : "no")",
      "- SketchyBar generation [\(sketchyBar.generationStatus)]: \(sketchyBar.generationID ?? "none")",
      "- SketchyBar desired generation agreement: \(sketchyBar.generationAgrees ? "yes" : "no")",
      "- SketchyBar ownership generation agreement: \(sketchyBar.ownershipAgrees ? "yes" : "no")",
      "- SketchyBar provider [\(sketchyBar.provider.status.rawValue)]: \(sketchyBar.provider.message)",
      "- SketchyBar palette [\(sketchyBar.palette.status.rawValue)]: \(sketchyBar.palette.message)",
      "- SketchyBar runtime: \(sketchyBar.runtime?.message ?? "not inspected")",
      "- SketchyBar core: \(sketchyBar.coreRuntime?.message ?? "not inspected")",
      "- SketchyBar lifecycle generation: \(sketchyBar.lifecycleGenerationID ?? "none")",
      "- interrupted SketchyBar transaction: \(sketchyBar.transactionPending ? "yes" : "no")",
      "- aggregate transaction: \(aggregateTransactionPending ? "pending" : "clear")",
    ]
    if let keybindings {
      lines.append(
        "- skhd [\(keybindings.effectiveStatus), \(keybindings.providerStatus)]: "
          + keybindings.message
      )
    }
    lines += theme.map {
      "- theme \($0.adapterID) [\($0.status)]: \($0.message ?? "no detail")"
    }
    lines += diagnostics.map { "- error: \($0)" }
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome
    case desktopProvider = "desktop_provider"
    case topBarProvider = "top_bar_provider"
    case generationStatus = "generation_status"
    case generationID = "generation_id"
    case generationAgrees = "generation_agrees"
    case ownershipAgrees = "ownership_agrees"
    case provider, runtime
    case lifecycleGenerationID = "lifecycle_generation_id"
    case transactionPending = "transaction_pending"
    case sketchyBar = "sketchybar"
    case keybindings, theme
    case aggregateTransactionPending = "aggregate_transaction_pending"
    case diagnostics
  }
}

private struct DesktopSketchyBarStatusReport: Encodable {
  let generationStatus: String
  let generationID: String?
  let generationAgrees: Bool
  let ownershipAgrees: Bool
  let provider: SketchyBarProviderPlanInspection
  let palette: SketchyBarPalettePlanInspection
  let runtime: SketchyBarRuntimeInspection?
  let coreRuntime: SketchyBarCoreRuntimeInspection?
  let lifecycleGenerationID: String?
  let transactionPending: Bool

  enum CodingKeys: String, CodingKey {
    case generationStatus = "generation_status"
    case generationID = "generation_id"
    case generationAgrees = "generation_agrees"
    case ownershipAgrees = "ownership_agrees"
    case provider, palette, runtime
    case coreRuntime = "core_runtime"
    case lifecycleGenerationID = "lifecycle_generation_id"
    case transactionPending = "transaction_pending"
  }
}
