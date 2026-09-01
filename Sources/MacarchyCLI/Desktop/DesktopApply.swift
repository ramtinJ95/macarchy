import Darwin
import Foundation
import ThemeCore

struct DesktopApplyCommandRunner: Sendable {
  let lifecycle: YabaiLifecycleController
  let sketchyBarLifecycle: SketchyBarLifecycleController
  let sketchyBarCoreRuntime: SketchyBarCoreRuntimeController?
  let faultInjector: @Sendable (YabaiTransactionCheckpoint) throws -> Void
  let sketchyBarFaultInjector: @Sendable (SketchyBarTransactionCheckpoint) throws -> Void

  static let live = DesktopApplyCommandRunner(lifecycle: .live)

  init(
    lifecycle: YabaiLifecycleController,
    sketchyBarLifecycle: SketchyBarLifecycleController = .live,
    sketchyBarCoreRuntime: SketchyBarCoreRuntimeController? = nil,
    faultInjector: @escaping @Sendable (YabaiTransactionCheckpoint) throws -> Void = { _ in },
    sketchyBarFaultInjector: @escaping @Sendable (SketchyBarTransactionCheckpoint) throws -> Void =
      { _ in }
  ) {
    self.lifecycle = lifecycle
    self.sketchyBarLifecycle = sketchyBarLifecycle
    self.sketchyBarCoreRuntime = sketchyBarCoreRuntime
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
            try DesktopTeardownCommandRunner(
              lifecycle: lifecycle,
              sketchyBarLifecycle: sketchyBarLifecycle,
              sketchyBarCoreRuntime: sketchyBarCoreRuntime,
              faultInjector: faultInjector
            ).teardownLocked(
              stateRoot: stateRoot,
              homeDirectory: homeDirectory,
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

  private func applySketchyBarLocked(
    composition: SketchyBarComposition?,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?
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
      let outcome = try transaction.teardownLocked(dryRun: false)
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
      adoptionEvidenceDigest: adopt
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
    adopt: String?
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
      let runtime = lifecycle.inspect(composition)
      guard runtime.status == .converged || runtime.status == .partial else {
        throw YabaiDesktopError.lifecycle(runtime.message)
      }
      try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).write(
        YabaiLifecycleEvidence(
          generationID: prepared.manifest.generationID,
          runtime: runtime
        )
      )
      try transactionStore.remove()
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
  let faultInjector: @Sendable (YabaiTransactionCheckpoint) throws -> Void
  let sketchyBarFaultInjector: @Sendable (SketchyBarTransactionCheckpoint) throws -> Void

  static let live = DesktopTeardownCommandRunner(lifecycle: .live)

  init(
    lifecycle: YabaiLifecycleController,
    sketchyBarLifecycle: SketchyBarLifecycleController = .live,
    sketchyBarCoreRuntime: SketchyBarCoreRuntimeController? = nil,
    faultInjector: @escaping @Sendable (YabaiTransactionCheckpoint) throws -> Void = { _ in },
    sketchyBarFaultInjector: @escaping @Sendable (SketchyBarTransactionCheckpoint) throws -> Void =
      { _ in }
  ) {
    self.lifecycle = lifecycle
    self.sketchyBarLifecycle = sketchyBarLifecycle
    self.sketchyBarCoreRuntime = sketchyBarCoreRuntime
    self.faultInjector = faultInjector
    self.sketchyBarFaultInjector = sketchyBarFaultInjector
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
        let yabai = try teardownLocked(
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
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

  fileprivate func teardownLocked(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool
  ) throws -> ApplyResult {
    let providerTransaction = YabaiProviderTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    let transactionStore = YabaiTransactionStore(stateRoot: stateRoot)
    var recovered: YabaiTransaction?
    if let pending = try transactionStore.read() {
      if dryRun {
        return ApplyResult(
          changed: true,
          generationID: pending.generationID,
          lifecycle: "recovery_required",
          message: "would recover the interrupted \(pending.operation.rawValue) transaction first"
        )
      }
      switch pending.operation {
      case .apply: try providerTransaction.recoverApply(pending, lifecycle: lifecycle)
      case .teardown: try providerTransaction.completeTeardown(pending, lifecycle: lifecycle)
      }
      recovered = pending
    }
    guard let ownership = try YabaiOwnershipStore(stateRoot: stateRoot).read() else {
      if let recovered {
        return ApplyResult(
          changed: true,
          generationID: recovered.generationID,
          lifecycle: "recovery",
          message:
            "recovered interrupted \(recovered.operation.rawValue); no managed yabai provider remains"
        )
      }
      return ApplyResult(
        changed: false,
        generationID: nil,
        lifecycle: "none",
        message: "no Macarchy-owned yabai provider exists"
      )
    }
    if dryRun {
      return ApplyResult(
        changed: true,
        generationID: ownership.generationID,
        lifecycle: ownership.priorServiceRunning ? "restart" : "stop",
        message:
          "would restore exact \(ownership.original.kind.rawValue) evidence \(ownership.original.digest)"
      )
    }
    let serviceWasRunning = try lifecycle.preflight()
    var transaction = YabaiTransaction(
      operation: .teardown,
      phase: .providerChanging,
      generationID: ownership.generationID,
      previousGenerationID: ownership.generationID,
      generationCreated: false,
      ownership: ownership,
      previousOwnership: ownership,
      previousLifecycle: try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).read(),
      serviceWasRunning: serviceWasRunning
    )
    try transactionStore.write(transaction)
    try providerTransaction.restoreOriginal(ownership)
    transaction.phase = .providerChanged
    try transactionStore.write(transaction)
    try faultInjector(.providerRestored)
    transaction.phase = .serviceChanging
    try transactionStore.write(transaction)
    try providerTransaction.completeTeardown(transaction, lifecycle: lifecycle)
    return ApplyResult(
      changed: true,
      generationID: ownership.generationID,
      lifecycle: ownership.priorServiceRunning ? "restart" : "stop",
      message:
        "restored exact \(ownership.original.kind.rawValue) evidence \(ownership.original.digest)"
    )
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
    macarchyExecutableURL: URL = RuntimeEnvironment.live.executableURL
  ) throws -> Self {
    let profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
    let yabaiComposition: YabaiComposition? =
      if profile.desktop.provider == .yabaiSkhd {
        try YabaiConfigurationComposer().compose(
          defaultsURL: resourcesRoot.appending(path: "yabai/defaults.toml"),
          profile: profile
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

private struct ApplyResult: Encodable {
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
