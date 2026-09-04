import Darwin
import Foundation
import Synchronization
import ThemeCore

struct DesktopApplyCommandRunner: Sendable {
  let lifecycle: YabaiLifecycleController
  let sketchyBarLifecycle: SketchyBarLifecycleController
  let sketchyBarCoreRuntime: SketchyBarCoreRuntimeController?
  let keybindings: DesktopKeybindingOrchestrator?
  let prerequisites: DesktopPrerequisiteInspector
  let theme: DesktopThemeController?
  let faultInjector: @Sendable (YabaiTransactionCheckpoint) throws -> Void
  let sketchyBarFaultInjector: @Sendable (SketchyBarTransactionCheckpoint) throws -> Void

  static let live = DesktopApplyCommandRunner(
    lifecycle: .live,
    keybindings: .live,
    prerequisites: .live,
    theme: .live
  )

  init(
    lifecycle: YabaiLifecycleController,
    sketchyBarLifecycle: SketchyBarLifecycleController = .live,
    sketchyBarCoreRuntime: SketchyBarCoreRuntimeController? = nil,
    keybindings: DesktopKeybindingOrchestrator?,
    prerequisites: DesktopPrerequisiteInspector,
    theme: DesktopThemeController?,
    faultInjector: @escaping @Sendable (YabaiTransactionCheckpoint) throws -> Void = { _ in },
    sketchyBarFaultInjector: @escaping @Sendable (SketchyBarTransactionCheckpoint) throws -> Void =
      { _ in }
  ) {
    self.lifecycle = lifecycle
    self.sketchyBarLifecycle = sketchyBarLifecycle
    self.sketchyBarCoreRuntime = sketchyBarCoreRuntime
    self.keybindings = keybindings
    self.prerequisites = prerequisites
    self.theme = theme
    self.faultInjector = faultInjector
    self.sketchyBarFaultInjector = sketchyBarFaultInjector
  }

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    sketchyBarAdopt: String? = nil,
    json: Bool,
    macarchyExecutableURL: URL = RuntimeEnvironment.live.executableURL
  ) throws -> (output: String, succeeded: Bool) {
    let desired: DesktopDesiredState
    do {
      desired = try DesktopDesiredState.load(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        macarchyExecutableURL: macarchyExecutableURL
      )
    } catch {
      return try result(
        outcome: "blocked",
        mutated: false,
        yabai: nil,
        sketchyBar: nil,
        message: String(describing: error),
        json: json,
        succeeded: false
      )
    }
    var yabaiBeforeFailure: ApplyResult?
    var sketchyBarBeforeFailure: ApplyResult?
    do {
      let results = try ActivationLock(root: stateRoot).withLock {
        if desired.sketchyBarComposition != nil {
          let palette = SketchyBarPalettePlanInspector().inspect(
            stateRoot: stateRoot,
            enabled: true
          )
          guard palette.status == .current else {
            throw DesktopApplyBlockedError(reason: palette.message)
          }
        }
        let yabai =
          if let composition = desired.yabaiComposition {
            try applyLocked(
              composition: composition,
              stateRoot: stateRoot,
              homeDirectory: homeDirectory,
              adopt: adopt
            )
          } else {
            try YabaiProviderTransaction(
              homeDirectory: homeDirectory,
              stateRoot: stateRoot
            ).teardownLocked(
              lifecycle: lifecycle,
              faultInjector: faultInjector,
              dryRun: false
            )
          }
        yabaiBeforeFailure = yabai
        let sketchyBar = try applySketchyBarLocked(
          composition: desired.sketchyBarComposition,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          adopt: sketchyBarAdopt
        )
        sketchyBarBeforeFailure = sketchyBar
        return (yabai, sketchyBar)
      }
      let changed = results.0.changed || results.1.changed
      let recovered = results.1.lifecycle == "recovery"
      return try self.result(
        outcome: recovered ? "recovered" : changed ? "applied" : "no_change",
        mutated: changed,
        yabai: results.0,
        sketchyBar: results.1,
        message: recovered
          ? "interrupted state was recovered; run desktop apply again"
          : changed ? "desktop provider state changed" : "desktop providers are converged",
        json: json,
        succeeded: !recovered
      )
    } catch let error as DesktopApplyBlockedError {
      return try result(
        outcome: "blocked",
        mutated: false,
        yabai: nil,
        sketchyBar: nil,
        message: error.reason,
        json: json,
        succeeded: false
      )
    } catch is YabaiInterruptionError {
      throw YabaiInterruptionError.injected
    } catch is SketchyBarInterruptionError {
      throw SketchyBarInterruptionError.injected
    } catch {
      return try result(
        outcome: "failed",
        mutated: yabaiBeforeFailure?.changed == true || sketchyBarBeforeFailure?.changed == true
          || YabaiTransactionStore(stateRoot: stateRoot).exists
          || SketchyBarTransactionStore(stateRoot: stateRoot).exists,
        yabai: yabaiBeforeFailure,
        sketchyBar: sketchyBarBeforeFailure,
        message: yabaiBeforeFailure?.changed == true || sketchyBarBeforeFailure?.changed == true
          ? "a prior desktop provider changed before a later provider failed; inspect status before retrying: \(error)"
          : String(describing: error),
        json: json,
        succeeded: false
      )
    }
  }

  func executeAggregate(
    resourcesRoot: URL,
    keybindingsResourcesRoot: URL = RuntimeEnvironment.live.builtInKeybindingsURL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    adopt: String?,
    keybindingsAdopt: String?,
    sketchyBarAdopt: String? = nil,
    json: Bool,
    macarchyExecutableURL: URL = RuntimeEnvironment.live.executableURL,
    profile suppliedProfile: PortableProfile? = nil
  ) async throws -> (output: String, succeeded: Bool) {
    let desired: DesktopDesiredState
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
      let report = DesktopAggregateMutationReport.failure(
        outcome: "blocked",
        message: String(describing: error)
      )
      return (try report.render(json: json), false)
    }

    let adapterIDs = themeAdapterIDs(desired.profile)
    let themeNeedsReconciliation: Bool
    do {
      if !adapterIDs.isEmpty {
        _ = try ReconciliationStatusStore(root: stateRoot).activeManifest()
      }
      if let theme, !adapterIDs.isEmpty {
        let inspections = try theme.inspect(adapterIDs, stateRoot, consumerPaths)
        themeNeedsReconciliation =
          inspections.count != adapterIDs.count
          || inspections.contains { $0.status != "ready" }
      } else {
        themeNeedsReconciliation = false
      }
    } catch {
      let report = DesktopAggregateMutationReport.failure(
        outcome: "blocked",
        message: "desktop theme preflight failed: \(error)"
      )
      return (try report.render(json: json), false)
    }

    let mutations: DesktopAggregateMutations
    let mutationStarted = Mutex(false)
    let coordinator = DesktopAggregateCoordinator(
      lifecycle: lifecycle,
      sketchyBarLifecycle: sketchyBarLifecycle,
      sketchyBarCoreRuntime: sketchyBarCoreRuntime,
      keybindings: keybindings,
      faultInjector: faultInjector,
      sketchyBarFaultInjector: sketchyBarFaultInjector
    )
    do {
      mutations = try ActivationLock(root: stateRoot).withLock {
        do {
          try coordinator.recoverLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
        } catch {
          throw DesktopAggregateError.recoveryRequired(String(describing: error))
        }
        try preflightAggregate(
          desired: desired,
          resourcesRoot: keybindingsResourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          adopt: adopt,
          keybindingsAdopt: keybindingsAdopt,
          sketchyBarAdopt: sketchyBarAdopt,
          profile: desired.profile,
          coordinator: coordinator
        )
        let store = DesktopAggregateTransactionStore(stateRoot: stateRoot)
        try store.write(
          DesktopAggregateTransaction(operation: .apply, phase: .mutating)
        )
        mutationStarted.withLock { $0 = true }
        do {
          let yabai =
            if let composition = desired.yabaiComposition {
              try applyLocked(
                composition: composition,
                stateRoot: stateRoot,
                homeDirectory: homeDirectory,
                adopt: adopt,
                deferFinalization: true
              )
            } else {
              try coordinator.teardownYabaiLocked(
                stateRoot: stateRoot,
                homeDirectory: homeDirectory,
                dryRun: false,
                deferFinalization: true
              )
            }
          let keybinding: SetupIntegrationResult? =
            if let keybindings {
              if desired.profile.desktop.provider == .yabaiSkhd {
                try keybindings.applyLocked(
                  resourcesRoot: keybindingsResourcesRoot,
                  profileURL: profileURL,
                  profileRequired: profileRequired,
                  stateRoot: stateRoot,
                  homeDirectory: homeDirectory,
                  adopt: keybindingsAdopt,
                  profile: desired.profile
                )
              } else {
                try keybindings.teardownLocked(
                  stateRoot: stateRoot,
                  homeDirectory: homeDirectory,
                  dryRun: false
                )
              }
            } else {
              nil
            }
          let sketchyBar = try applySketchyBarLocked(
            composition: desired.sketchyBarComposition,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            adopt: sketchyBarAdopt,
            deferFinalization: true
          )
          return DesktopAggregateMutations(
            yabai: yabai,
            keybindings: keybinding,
            sketchyBar: sketchyBar
          )
        } catch is YabaiInterruptionError {
          throw YabaiInterruptionError.injected
        } catch is SketchyBarInterruptionError {
          throw SketchyBarInterruptionError.injected
        } catch {
          do {
            try coordinator.rollbackApplyLocked(
              stateRoot: stateRoot,
              homeDirectory: homeDirectory
            )
            try store.remove()
          } catch {
            throw DesktopAggregateError.recoveryRequired(String(describing: error))
          }
          throw DesktopAggregateError.rolledBack(String(describing: error))
        }
      }
    } catch is YabaiInterruptionError {
      throw YabaiInterruptionError.injected
    } catch is SketchyBarInterruptionError {
      throw SketchyBarInterruptionError.injected
    } catch {
      let outcome: String
      if case .recoveryRequired = error as? DesktopAggregateError {
        outcome = "recovery_required"
      } else if !mutationStarted.withLock({ $0 }) {
        outcome = "blocked"
      } else {
        outcome = "failed"
      }
      let report = DesktopAggregateMutationReport.failure(
        outcome: outcome,
        mutated: mutationStarted.withLock { $0 },
        message: String(describing: error)
      )
      return (try report.render(json: json), false)
    }

    var themeResult: DesktopThemeReconciliation?
    if let theme, !adapterIDs.isEmpty,
      themeNeedsReconciliation || mutations.changed
    {
      do {
        let reconciled = try await theme.reconcile(adapterIDs, stateRoot, consumerPaths)
        guard reconciled.succeeded else {
          throw DesktopAggregateError.invalidState(
            "required desktop theme reconciliation failed"
          )
        }
        themeResult = reconciled
      } catch {
        do {
          try ActivationLock(root: stateRoot).withLock {
            try coordinator.rollbackApplyLocked(
              stateRoot: stateRoot,
              homeDirectory: homeDirectory
            )
            try DesktopAggregateTransactionStore(stateRoot: stateRoot).remove()
          }
        } catch {
          let report = DesktopAggregateMutationReport.failure(
            outcome: "recovery_required",
            message: "theme reconciliation failed and provider rollback requires recovery: \(error)"
          )
          return (try report.render(json: json), false)
        }
        let report = DesktopAggregateMutationReport(
          outcome: "failed",
          mutated: true,
          yabai: mutations.yabai,
          keybindings: mutations.keybindings,
          sketchyBar: mutations.sketchyBar,
          theme: nil,
          message: "theme reconciliation failed; provider changes were rolled back: \(error)"
        )
        return (try report.render(json: json), false)
      }
    }

    do {
      try ActivationLock(root: stateRoot).withLock {
        let store = DesktopAggregateTransactionStore(stateRoot: stateRoot)
        try store.write(
          DesktopAggregateTransaction(operation: .apply, phase: .committing)
        )
        try coordinator.commitApplyLocked(
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        try store.remove()
      }
    } catch {
      let report = DesktopAggregateMutationReport(
        outcome: "recovery_required",
        mutated: true,
        yabai: mutations.yabai,
        keybindings: mutations.keybindings,
        sketchyBar: mutations.sketchyBar,
        theme: themeResult,
        message: "desktop changes reached the forward commit boundary: \(error)"
      )
      return (try report.render(json: json), false)
    }

    let changed = mutations.changed || themeResult != nil
    let report = DesktopAggregateMutationReport(
      outcome: changed ? "applied" : "no_change",
      mutated: changed,
      yabai: mutations.yabai,
      keybindings: mutations.keybindings,
      sketchyBar: mutations.sketchyBar,
      theme: themeResult,
      message: changed
        ? "desktop providers and selected theme adapters converged"
        : "desktop providers and selected theme adapters are already converged"
    )
    return (try report.render(json: json), true)
  }

  private func preflightAggregate(
    desired: DesktopDesiredState,
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    keybindingsAdopt: String?,
    sketchyBarAdopt: String?,
    profile: PortableProfile,
    coordinator: DesktopAggregateCoordinator
  ) throws {
    let missing = prerequisites.inspect(desired.profile, homeDirectory).filter {
      $0.status == .missing
    }
    guard missing.isEmpty else {
      throw DesktopAggregateError.invalidState(
        missing.map { "\($0.id): \($0.remediation)" }.joined(separator: "; ")
      )
    }
    if desired.profile.desktop.provider == .yabaiSkhd {
      let generation = YabaiGenerationInspector(stateRoot: stateRoot).inspect()
      guard generation.status != .invalid else {
        throw DesktopAggregateError.invalidState(generation.message)
      }
      let provider = YabaiProviderPlanInspector().inspect(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        enabled: true
      )
      guard [.managed, .installRequired, .adoptionRequired].contains(provider.status) else {
        throw DesktopAggregateError.invalidState(provider.message)
      }
      if provider.status == .adoptionRequired {
        guard adopt == provider.adoptionEvidenceDigest else {
          throw DesktopAggregateError.invalidState(
            "yabai adoption requires --adopt \(provider.adoptionEvidenceDigest ?? "unavailable") from the current reviewed plan"
          )
        }
      }
      _ = try lifecycle.preflight()
      if let keybindings {
        let preview = try keybindings.preview(
          resourcesRoot: resourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          adopt: keybindingsAdopt,
          profile: profile
        )
        guard preview.succeeded else {
          throw DesktopAggregateError.invalidState(preview.message)
        }
      }
    } else {
      _ = try coordinator.teardownYabaiLocked(
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        dryRun: true
      )
      _ = try keybindings?.teardownLocked(
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        dryRun: true
      )
    }
    if desired.profile.topBar == .sketchybar {
      let palette = SketchyBarPalettePlanInspector().inspect(
        stateRoot: stateRoot,
        enabled: true
      )
      guard palette.status == .current else {
        throw DesktopAggregateError.invalidState(palette.message)
      }
      let generation = SketchyBarGenerationInspector(stateRoot: stateRoot).inspect()
      guard generation.status != .invalid else {
        throw DesktopAggregateError.invalidState(generation.message)
      }
      let provider = SketchyBarProviderPlanInspector().inspect(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        enabled: true,
        generation: generation
      )
      guard [.managed, .installRequired, .adoptionRequired].contains(provider.status) else {
        throw DesktopAggregateError.invalidState(provider.message)
      }
      if provider.status == .adoptionRequired {
        guard sketchyBarAdopt == provider.adoptionEvidenceDigest else {
          throw DesktopAggregateError.invalidState(
            "SketchyBar adoption requires --sketchybar-adopt \(provider.adoptionEvidenceDigest ?? "unavailable") from the current reviewed plan"
          )
        }
      }
      let wasRunning = try sketchyBarLifecycle.preflight()
      if wasRunning,
        try SketchyBarOwnershipStore(stateRoot: stateRoot).read() == nil,
        provider.status == .installRequired
      {
        throw DesktopAggregateError.invalidState(
          "cannot adopt a running SketchyBar service without a restorable original sketchybarrc"
        )
      }
    } else {
      _ = try coordinator.sketchyBarTransaction(
        stateRoot: stateRoot,
        homeDirectory: homeDirectory
      ).teardownLocked(dryRun: true)
    }
  }

  private func themeAdapterIDs(_ profile: PortableProfile) -> [String] {
    var ids = [String]()
    if profile.desktop.provider == .yabaiSkhd { ids.append("wallpaper") }
    if profile.topBar == .sketchybar { ids.append("sketchybar") }
    return ids.sorted()
  }

  private func applySketchyBarLocked(
    composition: SketchyBarComposition?,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    deferFinalization: Bool = false
  ) throws -> ApplyResult {
    let transaction = SketchyBarProviderTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      lifecycle: sketchyBarLifecycle,
      coreRuntime: sketchyBarCoreRuntime ?? .live(stateRoot: stateRoot),
      faultInjector: sketchyBarFaultInjector
    )
    if let recovered = try transaction.recoverPendingLocked() {
      return ApplyResult(
        changed: true,
        generationID: recovered.generationID,
        lifecycle: "recovery",
        message:
          "recovered interrupted SketchyBar \(recovered.operation.rawValue); run desktop apply again to converge the requested state"
      )
    }
    guard let composition else {
      let outcome = try transaction.teardownLocked(
        dryRun: false,
        deferFinalization: deferFinalization
      )
      return ApplyResult(
        changed: outcome.changed,
        generationID: outcome.generationID,
        lifecycle: outcome.changed ? "restore" : "none",
        message: outcome.changed
          ? "restored the prior SketchyBar provider and service state"
          : "no Macarchy-owned SketchyBar provider exists"
      )
    }
    let outcome = try transaction.convergeLocked(
      composition: composition,
      adoptionEvidenceDigest: adopt,
      deferFinalization: deferFinalization
    )
    return ApplyResult(
      changed: outcome.changed,
      generationID: outcome.generationID,
      lifecycle: outcome.changed ? "reload_or_start" : "none",
      message: outcome.changed
        ? "managed SketchyBar provider and runtime converged"
        : "managed SketchyBar provider and runtime are already converged"
    )
  }

  private func applyLocked(
    composition: YabaiComposition,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    deferFinalization: Bool = false
  ) throws -> ApplyResult {
    let transactionStore = YabaiTransactionStore(stateRoot: stateRoot)
    let providerTransaction = YabaiProviderTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    if let pending = try transactionStore.read() {
      switch pending.operation {
      case .apply:
        try providerTransaction.recoverApply(pending, lifecycle: lifecycle)
      case .teardown:
        try providerTransaction.completeTeardown(pending, lifecycle: lifecycle)
      }
    }

    let generationInspector = YabaiGenerationInspector(stateRoot: stateRoot)
    let previousGeneration = generationInspector.inspect()
    if previousGeneration.status == .invalid {
      throw YabaiDesktopError.invalidState(previousGeneration.message)
    }
    let ownershipStore = YabaiOwnershipStore(stateRoot: stateRoot)
    let previousOwnership = try ownershipStore.read()
    let providerInspector = YabaiProviderPlanInspector()
    let provider = providerInspector.inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      enabled: true
    )
    guard [.managed, .installRequired, .adoptionRequired].contains(provider.status) else {
      throw YabaiDesktopError.invalidState(provider.message)
    }

    let original: YabaiAdoptionEvidence
    let retainedOriginalPath: String?
    let createdDirectory: Bool
    if let previousOwnership {
      original = previousOwnership.original
      retainedOriginalPath = previousOwnership.retainedOriginalPath
      createdDirectory = previousOwnership.createdConfigurationDirectory
    } else {
      let directory = homeDirectory.appending(
        path: ".config/yabai",
        directoryHint: .isDirectory
      )
      let entry = directory.appending(path: "yabairc")
      original = try providerInspector.captureUnowned(directory: directory, entry: entry)
      if provider.status == .adoptionRequired {
        guard let adopt, adopt == original.digest else {
          throw YabaiDesktopError.invalidState(
            "adoption requires --adopt \(original.digest) from the current reviewed plan"
          )
        }
      }
      retainedOriginalPath =
        original.kind == .absent
        ? nil : providerTransaction.retainedOriginalURL().path
      var metadata = stat()
      createdDirectory = original.kind == .absent && lstat(directory.path, &metadata) != 0
    }

    let serviceWasRunning = try lifecycle.preflight()
    let activator = YabaiGenerationActivator(stateRoot: stateRoot)
    let prepared = try activator.prepare(composition)
    let previousLifecycle = try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).read()
    if !prepared.created,
      let previousOwnership,
      previousOwnership.generationID == prepared.manifest.generationID,
      previousLifecycle?.generationID == prepared.manifest.generationID
    {
      let runtime = lifecycle.inspect(composition)
      if runtime.status == .converged || runtime.status == .partial {
        return ApplyResult(
          changed: false,
          generationID: prepared.manifest.generationID,
          lifecycle: "none",
          message: "managed yabai configuration and observable runtime state are already converged"
        )
      }
    }

    let managedTarget = YabaiProviderPlanInspector.managedTarget(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    let ownership = YabaiOwnershipRecord(
      generationID: prepared.manifest.generationID,
      managedTarget: managedTarget,
      original: original,
      retainedOriginalPath: retainedOriginalPath,
      createdConfigurationDirectory: createdDirectory,
      priorServiceRunning: previousOwnership?.priorServiceRunning ?? serviceWasRunning
    )
    var transaction = YabaiTransaction(
      operation: .apply,
      phase: .prepared,
      generationID: prepared.manifest.generationID,
      previousGenerationID: previousGeneration.generationID,
      generationCreated: prepared.created,
      ownership: ownership,
      previousOwnership: previousOwnership,
      previousLifecycle: previousLifecycle,
      serviceWasRunning: serviceWasRunning
    )
    try transactionStore.write(transaction)

    do {
      if prepared.created { try activator.select(prepared) }
      if previousOwnership == nil {
        transaction.phase = .providerChanging
        try transactionStore.write(transaction)
        let directory = homeDirectory.appending(
          path: ".config/yabai",
          directoryHint: .isDirectory
        )
        let entry = directory.appending(path: "yabairc")
        let recaptured = try providerInspector.captureUnowned(directory: directory, entry: entry)
        guard recaptured == original else {
          throw YabaiDesktopError.invalidState(
            "yabai provider changed after the approved adoption preview"
          )
        }
        try providerTransaction.installManaged(ownership)
      }
      try ownershipStore.write(ownership)
      transaction.phase = .providerChanged
      try transactionStore.write(transaction)
      try faultInjector(.providerChanged)

      transaction.phase = .serviceChanging
      try transactionStore.write(transaction)
      try lifecycle.restart()
      transaction.phase = .serviceChanged
      try transactionStore.write(transaction)
      let runtime = lifecycle.inspectAfterRestart(composition)
      guard runtime.status == .converged || runtime.status == .partial else {
        throw YabaiDesktopError.lifecycle(runtime.message)
      }
      try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).write(
        YabaiLifecycleEvidence(
          generationID: prepared.manifest.generationID,
          runtime: runtime
        )
      )
      if !deferFinalization {
        try transactionStore.remove()
      }
      return ApplyResult(
        changed: true,
        generationID: prepared.manifest.generationID,
        lifecycle: "restart",
        message: runtime.message
      )
    } catch is YabaiInterruptionError {
      throw YabaiInterruptionError.injected
    } catch {
      do {
        try providerTransaction.recoverApply(transaction, lifecycle: lifecycle)
      } catch {
        throw YabaiDesktopError.invalidState(
          "apply failed and rollback requires recovery: \(error)"
        )
      }
      throw error
    }
  }

  private func result(
    outcome: String,
    mutated: Bool,
    yabai: ApplyResult?,
    sketchyBar: ApplyResult?,
    message: String,
    json: Bool,
    succeeded: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report = DesktopMutationReport(
      operation: "desktop_apply",
      outcome: outcome,
      mutated: mutated,
      yabai: yabai,
      sketchyBar: sketchyBar,
      message: message
    )
    return (try report.render(json: json), succeeded)
  }
}

struct DesktopTeardownCommandRunner: Sendable {
  let lifecycle: YabaiLifecycleController
  let sketchyBarLifecycle: SketchyBarLifecycleController
  let sketchyBarCoreRuntime: SketchyBarCoreRuntimeController?
  let keybindings: DesktopKeybindingOrchestrator?
  let faultInjector: @Sendable (YabaiTransactionCheckpoint) throws -> Void
  let sketchyBarFaultInjector: @Sendable (SketchyBarTransactionCheckpoint) throws -> Void

  static let live = DesktopTeardownCommandRunner(
    lifecycle: .live,
    keybindings: .live
  )

  init(
    lifecycle: YabaiLifecycleController,
    sketchyBarLifecycle: SketchyBarLifecycleController = .live,
    sketchyBarCoreRuntime: SketchyBarCoreRuntimeController? = nil,
    keybindings: DesktopKeybindingOrchestrator?,
    faultInjector: @escaping @Sendable (YabaiTransactionCheckpoint) throws -> Void = { _ in },
    sketchyBarFaultInjector: @escaping @Sendable (SketchyBarTransactionCheckpoint) throws -> Void =
      { _ in }
  ) {
    self.lifecycle = lifecycle
    self.sketchyBarLifecycle = sketchyBarLifecycle
    self.sketchyBarCoreRuntime = sketchyBarCoreRuntime
    self.keybindings = keybindings
    self.faultInjector = faultInjector
    self.sketchyBarFaultInjector = sketchyBarFaultInjector
  }

  func executeAggregate(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let coordinator = DesktopAggregateCoordinator(
      lifecycle: lifecycle,
      sketchyBarLifecycle: sketchyBarLifecycle,
      sketchyBarCoreRuntime: sketchyBarCoreRuntime,
      keybindings: keybindings,
      faultInjector: faultInjector,
      sketchyBarFaultInjector: sketchyBarFaultInjector
    )
    if dryRun {
      do {
        let sketchyBar = try coordinator.sketchyBarTransaction(
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        ).teardownLocked(dryRun: true)
        let keybinding = try keybindings?.teardownLocked(
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          dryRun: true
        )
        let yabai = try coordinator.teardownYabaiLocked(
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          dryRun: true
        )
        let report = DesktopAggregateTeardownReport(
          outcome: sketchyBar.changed || keybinding?.status == .planned || yabai.changed
            ? "planned" : "no_change",
          mutated: false,
          yabai: yabai,
          keybindings: keybinding,
          sketchyBar: ApplyResult(
            changed: sketchyBar.changed,
            generationID: sketchyBar.generationID,
            lifecycle: sketchyBar.changed ? "restore" : "none",
            message: sketchyBar.changed
              ? "would restore the prior SketchyBar provider"
              : "no Macarchy-owned SketchyBar provider exists"
          ),
          message: "aggregate teardown preview completed without mutation"
        )
        return (try report.render(json: json), true)
      } catch {
        let report = DesktopAggregateTeardownReport.failure(
          outcome: "blocked",
          message: String(describing: error)
        )
        return (try report.render(json: json), false)
      }
    }

    let mutations: DesktopAggregateMutations
    let mutationStarted = Mutex(false)
    do {
      mutations = try ActivationLock(root: stateRoot).withLock {
        do {
          try coordinator.recoverLocked(
            stateRoot: stateRoot,
            homeDirectory: homeDirectory
          )
        } catch {
          throw DesktopAggregateError.recoveryRequired(String(describing: error))
        }
        let store = DesktopAggregateTransactionStore(stateRoot: stateRoot)
        try store.write(
          DesktopAggregateTransaction(operation: .teardown, phase: .mutating)
        )
        mutationStarted.withLock { $0 = true }
        do {
          let sketchyOutcome = try coordinator.sketchyBarTransaction(
            stateRoot: stateRoot,
            homeDirectory: homeDirectory
          ).teardownLocked(dryRun: false, deferFinalization: true)
          let sketchyBar = ApplyResult(
            changed: sketchyOutcome.changed,
            generationID: sketchyOutcome.generationID,
            lifecycle: sketchyOutcome.changed ? "restore" : "none",
            message: sketchyOutcome.changed
              ? "restored the prior SketchyBar provider pending aggregate commit"
              : "no Macarchy-owned SketchyBar provider exists"
          )
          let keybinding = try keybindings?.teardownLocked(
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            dryRun: false
          )
          let yabai = try coordinator.teardownYabaiLocked(
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            dryRun: false,
            deferFinalization: true
          )
          return DesktopAggregateMutations(
            yabai: yabai,
            keybindings: keybinding,
            sketchyBar: sketchyBar
          )
        } catch is YabaiInterruptionError {
          throw YabaiInterruptionError.injected
        } catch is SketchyBarInterruptionError {
          throw SketchyBarInterruptionError.injected
        } catch {
          do {
            try coordinator.rollbackTeardownLocked(
              stateRoot: stateRoot,
              homeDirectory: homeDirectory
            )
            try store.remove()
          } catch {
            throw DesktopAggregateError.recoveryRequired(String(describing: error))
          }
          throw DesktopAggregateError.rolledBack(String(describing: error))
        }
      }
    } catch is YabaiInterruptionError {
      throw YabaiInterruptionError.injected
    } catch is SketchyBarInterruptionError {
      throw SketchyBarInterruptionError.injected
    } catch {
      let outcome: String
      if case .recoveryRequired = error as? DesktopAggregateError {
        outcome = "recovery_required"
      } else {
        outcome = "failed"
      }
      let report = DesktopAggregateTeardownReport.failure(
        outcome: outcome,
        mutated: mutationStarted.withLock { $0 },
        message: String(describing: error)
      )
      return (try report.render(json: json), false)
    }

    do {
      try ActivationLock(root: stateRoot).withLock {
        let store = DesktopAggregateTransactionStore(stateRoot: stateRoot)
        try store.write(
          DesktopAggregateTransaction(operation: .teardown, phase: .committing)
        )
        try coordinator.commitTeardownLocked(
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        try store.remove()
      }
    } catch {
      let report = DesktopAggregateTeardownReport(
        outcome: "recovery_required",
        mutated: true,
        yabai: mutations.yabai,
        keybindings: mutations.keybindings,
        sketchyBar: mutations.sketchyBar,
        message: "desktop teardown reached the forward commit boundary: \(error)"
      )
      return (try report.render(json: json), false)
    }

    let report = DesktopAggregateTeardownReport(
      outcome: mutations.changed ? "removed" : "no_change",
      mutated: mutations.changed,
      yabai: mutations.yabai,
      keybindings: mutations.keybindings,
      sketchyBar: mutations.sketchyBar,
      message: mutations.changed
        ? "desktop providers were restored in reverse dependency order"
        : "no Macarchy-owned desktop providers exist"
    )
    return (try report.render(json: json), true)
  }

  func execute(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    var sketchyBarBeforeFailure: ApplyResult?
    do {
      let outcomes = try ActivationLock(root: stateRoot).withLock {
        let transaction = SketchyBarProviderTransaction(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot,
          lifecycle: sketchyBarLifecycle,
          coreRuntime: sketchyBarCoreRuntime ?? .live(stateRoot: stateRoot),
          faultInjector: sketchyBarFaultInjector
        )
        let sketchyBar: ApplyResult
        if !dryRun, let recovered = try transaction.recoverPendingLocked() {
          sketchyBar = ApplyResult(
            changed: true,
            generationID: recovered.generationID,
            lifecycle: "recovery",
            message: "recovered interrupted SketchyBar \(recovered.operation.rawValue)"
          )
        } else {
          let outcome = try transaction.teardownLocked(dryRun: dryRun)
          sketchyBar = ApplyResult(
            changed: outcome.changed,
            generationID: outcome.generationID,
            lifecycle: outcome.changed ? "restore" : "none",
            message: outcome.changed
              ? "restore the prior SketchyBar provider and service state"
              : "no Macarchy-owned SketchyBar provider exists"
          )
        }
        sketchyBarBeforeFailure = sketchyBar
        let yabai = try YabaiProviderTransaction(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot
        ).teardownLocked(
          lifecycle: lifecycle,
          faultInjector: faultInjector,
          dryRun: dryRun
        )
        return (yabai, sketchyBar)
      }
      let changed = outcomes.0.changed || outcomes.1.changed
      let recovered = outcomes.1.lifecycle == "recovery"
      let report = DesktopMutationReport(
        operation: "desktop_teardown",
        outcome: recovered
          ? "recovered" : changed ? (dryRun ? "planned" : "removed") : "no_change",
        mutated: changed && !dryRun,
        yabai: outcomes.0,
        sketchyBar: outcomes.1,
        message: recovered
          ? "interrupted state was recovered; run desktop teardown again"
          : changed ? "desktop provider teardown changed state" : "no managed providers exist"
      )
      return (try report.render(json: json), !recovered)
    } catch is YabaiInterruptionError {
      throw YabaiInterruptionError.injected
    } catch is SketchyBarInterruptionError {
      throw SketchyBarInterruptionError.injected
    } catch {
      let report = DesktopMutationReport(
        operation: "desktop_teardown",
        outcome: "failed",
        mutated: !dryRun
          && (sketchyBarBeforeFailure?.changed == true
            || YabaiTransactionStore(stateRoot: stateRoot).exists
            || SketchyBarTransactionStore(stateRoot: stateRoot).exists),
        yabai: nil,
        sketchyBar: sketchyBarBeforeFailure,
        message: sketchyBarBeforeFailure?.changed == true
          ? "SketchyBar teardown completed before a later provider failed; inspect status before retrying: \(error)"
          : String(describing: error)
      )
      return (try report.render(json: json), false)
    }
  }
}

private struct DesktopApplyBlockedError: Error {
  let reason: String
}

struct DesktopDesiredState: Sendable {
  let profile: PortableProfile
  let yabaiComposition: YabaiComposition?
  let sketchyBarComposition: SketchyBarComposition?

  static func load(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    macarchyExecutableURL: URL = RuntimeEnvironment.live.executableURL,
    profile suppliedProfile: PortableProfile? = nil
  ) throws -> Self {
    let profile =
      try suppliedProfile
      ?? PortableProfileLoader().load(at: profileURL, required: profileRequired)
    let yabaiComposition: YabaiComposition? =
      if profile.desktop.provider == .yabaiSkhd {
        try YabaiConfigurationComposer().compose(
          defaultsURL: resourcesRoot.appending(path: "yabai/defaults.toml"),
          profile: profile,
          macarchyExecutableURL: macarchyExecutableURL
        )
      } else {
        nil
      }
    let sketchyBarComposition: SketchyBarComposition? =
      if profile.topBar == .sketchybar {
        try SketchyBarConfigurationComposer().compose(
          defaultsURL: resourcesRoot.appending(path: "sketchybar/defaults.toml"),
          profile: profile,
          stateRoot: stateRoot,
          macarchyExecutableURL: macarchyExecutableURL
        )
      } else {
        nil
      }
    return Self(
      profile: profile,
      yabaiComposition: yabaiComposition,
      sketchyBarComposition: sketchyBarComposition
    )
  }
}

struct ApplyResult: Encodable {
  let changed: Bool
  let generationID: String?
  let lifecycle: String
  let message: String

  enum CodingKeys: String, CodingKey {
    case changed
    case generationID = "generation_id"
    case lifecycle, message
  }
}

private struct DesktopAggregateMutations {
  let yabai: ApplyResult
  let keybindings: SetupIntegrationResult?
  let sketchyBar: ApplyResult

  var changed: Bool {
    yabai.changed || keybindings?.mutationAttempted == true || sketchyBar.changed
  }
}

private struct DesktopAggregateMutationReport: Encodable {
  let schemaVersion = 1
  let operation = "desktop_apply"
  let outcome: String
  let mutated: Bool
  let yabai: ApplyResult?
  let keybindings: SetupIntegrationResult?
  let sketchyBar: ApplyResult?
  let theme: DesktopThemeReconciliation?
  let message: String

  static func failure(
    outcome: String,
    mutated: Bool = false,
    message: String
  ) -> Self {
    Self(
      outcome: outcome,
      mutated: mutated,
      yabai: nil,
      keybindings: nil,
      sketchyBar: nil,
      theme: nil,
      message: message
    )
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy desktop apply [\(outcome)]:",
      "- mutated: \(mutated ? "yes" : "no")",
      "- \(message)",
    ]
    if let yabai {
      lines.append("- yabai [\(yabai.changed ? "changed" : "no_change")]: \(yabai.message)")
    }
    if let keybindings {
      lines.append("- skhd [\(keybindings.status.rawValue)]: \(keybindings.message)")
    }
    if let sketchyBar {
      lines.append(
        "- SketchyBar [\(sketchyBar.changed ? "changed" : "no_change")]: "
          + sketchyBar.message
      )
    }
    if let theme {
      lines.append(
        "- theme [\(theme.succeeded ? "converged" : "failed")]: "
          + theme.results.map { "\($0.adapterID)=\($0.status)" }.joined(separator: ", ")
      )
    }
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, mutated, yabai, keybindings
    case sketchyBar = "sketchybar"
    case theme, message
  }
}

private struct DesktopAggregateTeardownReport: Encodable {
  let schemaVersion = 1
  let operation = "desktop_teardown"
  let outcome: String
  let mutated: Bool
  let yabai: ApplyResult?
  let keybindings: SetupIntegrationResult?
  let sketchyBar: ApplyResult?
  let message: String

  static func failure(
    outcome: String,
    mutated: Bool = false,
    message: String
  ) -> Self {
    Self(
      outcome: outcome,
      mutated: mutated,
      yabai: nil,
      keybindings: nil,
      sketchyBar: nil,
      message: message
    )
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy desktop teardown [\(outcome)]:",
      "- mutated: \(mutated ? "yes" : "no")",
      "- \(message)",
    ]
    if let sketchyBar { lines.append("- SketchyBar: \(sketchyBar.message)") }
    if let keybindings { lines.append("- skhd: \(keybindings.message)") }
    if let yabai { lines.append("- yabai: \(yabai.message)") }
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, mutated, yabai, keybindings
    case sketchyBar = "sketchybar"
    case message
  }
}

private struct DesktopMutationReport: Encodable {
  let schemaVersion = 2
  let operation: String
  let outcome: String
  let mutated: Bool
  let yabai: ApplyResult?
  let sketchyBar: ApplyResult?
  let message: String

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy \(operation.replacingOccurrences(of: "_", with: " ")) [\(outcome)]:",
      "- mutated: \(mutated ? "yes" : "no")",
      "- \(message)",
    ]
    if let yabai { lines.append(providerLine("yabai", yabai)) }
    if let sketchyBar { lines.append(providerLine("SketchyBar", sketchyBar)) }
    return lines.joined(separator: "\n")
  }

  private func providerLine(_ name: String, _ result: ApplyResult) -> String {
    "- \(name) [\(result.changed ? "changed" : "no_change"), \(result.lifecycle)]: \(result.generationID ?? "none"); \(result.message)"
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, mutated
    case yabai
    case sketchyBar = "sketchybar"
    case message
  }
}
