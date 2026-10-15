import Darwin
import Foundation
import Synchronization
import ThemeCore

enum KeybindingLifecycleAction: String, Codable, Sendable {
  case none
  case reload
  case restart
  case start
  case stop
}

struct KeybindingLifecycleController: Sendable {
  let preflight: @Sendable () throws -> Void
  let restart: @Sendable () throws -> Void
  let reload: @Sendable () throws -> Void
  let verifyProcess: @Sendable () throws -> Void
  let inspectProcess: @Sendable () -> KeybindingProcessInspection
  let service: SkhdUserService?

  init(
    preflight: @escaping @Sendable () throws -> Void = {},
    restart: @escaping @Sendable () throws -> Void,
    reload: @escaping @Sendable () throws -> Void,
    verifyProcess: @escaping @Sendable () throws -> Void,
    inspectProcess: @escaping @Sendable () -> KeybindingProcessInspection = { .notRunning },
    service: SkhdUserService? = nil
  ) {
    self.preflight = preflight
    self.restart = restart
    self.reload = reload
    self.verifyProcess = verifyProcess
    self.inspectProcess = inspectProcess
    self.service = service
  }

  static let live = KeybindingLifecycleController(
    preflight: {
      let executable = "/opt/homebrew/bin/skhd"
      guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw KeybindingsApplyError.lifecycle("supported skhd is unavailable at \(executable)")
      }
      try requireSupportedProcess()
    },
    restart: { try runSkhd(["--restart-service"]) },
    reload: { try runSkhd(["--reload"]) },
    verifyProcess: { try requireSupportedProcess() },
    inspectProcess: KeybindingProcessInspector.live.inspect,
    service: .live
  )

  private static func requireSupportedProcess() throws {
    var last = KeybindingProcessInspection.notRunning
    for _ in 0..<20 {
      last = KeybindingProcessInspector.live.inspect()
      if last.status == .running { return }
      if last.status == .unsupported || last.status == .unavailable { break }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw KeybindingsApplyError.lifecycle(
      last.message + " Verify skhd's manual Accessibility grant in System Settings.")
  }

  private static func runSkhd(_ arguments: [String]) throws {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/opt/homebrew/bin/skhd"),
        arguments: arguments,
        timeout: 10
      )
    )
    guard result.terminationStatus == 0 else {
      let output = result.output.isEmpty ? "no output" : result.output
      throw KeybindingsApplyError.lifecycle(
        "skhd \(arguments.joined(separator: " ")) exited with status "
          + "\(result.terminationStatus): \(output)"
      )
    }
  }
}

struct KeybindingsApplyCommandRunner: Sendable {
  let lifecycle: KeybindingLifecycleController
  let planner: KeybindingsPlanCommandRunner
  #if MACARCHY_ACCEPTANCE_TESTING
    private let acceptanceFailure: KeybindingAcceptanceFailureInjector?
  #endif

  static let live = KeybindingsApplyCommandRunner(lifecycle: .live, planner: .live)

  init(
    lifecycle: KeybindingLifecycleController,
    planner: KeybindingsPlanCommandRunner? = nil
  ) {
    self.lifecycle = lifecycle
    self.planner =
      planner
      ?? KeybindingsPlanCommandRunner(
        effectiveInspector: KeybindingEffectiveBehaviorInspector(
          processInspector: KeybindingProcessInspector(inspect: lifecycle.inspectProcess)
        ),
        service: lifecycle.service
      )
    #if MACARCHY_ACCEPTANCE_TESTING
      acceptanceFailure = nil
    #endif
  }

  #if MACARCHY_ACCEPTANCE_TESTING
    private init(
      lifecycle: KeybindingLifecycleController,
      planner: KeybindingsPlanCommandRunner,
      acceptanceFailure: KeybindingAcceptanceFailureInjector
    ) {
      self.lifecycle = lifecycle
      self.planner = planner
      self.acceptanceFailure = acceptanceFailure
    }

    func withAcceptanceManagedUpdateRollbackCheckpoint(
      observer: @escaping @Sendable (String) -> Void = { _ in }
    ) -> Self {
      Self(
        lifecycle: lifecycle,
        planner: planner,
        acceptanceFailure: KeybindingAcceptanceFailureInjector(observer: observer)
      )
    }
  #endif

  func teardownLocked(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool,
    deferFinalization: Bool = false
  ) throws -> SetupIntegrationResult {
    let target = skhdEntry(homeDirectory)
    let transactionStore = KeybindingApplyTransactionStore(stateRoot: stateRoot)
    var recovered = false
    var recoveryLifecycle = KeybindingLifecycleAction.none
    if let pending = try transactionStore.read() {
      if dryRun {
        return try previewTeardownAfterRecovery(
          pending,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      }
      recoveryLifecycle = try recoverForTeardown(
        pending,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        transactionStore: transactionStore
      )
      recovered = true
    }

    guard let record = try keybindingOwnershipRecord(homeDirectory: homeDirectory) else {
      return SetupIntegrationResult(
        id: KeybindingProviderInspector.ownershipID,
        status: .none,
        target: target.path,
        message:
          recovered
          ? "Recovered the interrupted keybinding transaction; no Macarchy-owned provider entry remains; recovery lifecycle=\(recoveryLifecycle.rawValue)"
          : "No Macarchy-owned keybinding provider entry exists",
        mutationAttempted: recovered,
        lifecycle: recoveryLifecycle
      )
    }
    let preparation = try prepareTeardown(
      record: record,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      target: target
    )
    let serviceChange = try lifecycle.service?.prepare(home: homeDirectory, stateRoot: stateRoot)
    let teardownAction: KeybindingLifecycleAction =
      serviceChange?.previousOwnership?.original.running == false ? .stop : .restart
    if dryRun {
      return SetupIntegrationResult(
        id: KeybindingProviderInspector.ownershipID,
        status: .planned,
        target: target.path,
        message:
          "Would restore \(preparation.restorationDescription) and the prior service state; lifecycle=\(teardownAction.rawValue)",
        mutationAttempted: false,
        lifecycle: teardownAction
      )
    }

    var transaction = KeybindingApplyTransaction(
      operation: .teardownEntry,
      phase: .staged,
      generationID: preparation.generationID,
      previousGenerationID: preparation.generationID,
      generationCreated: false,
      service: serviceChange
    )
    do {
      try restoreTeardownEntry(
        preparation.provider,
        transaction: &transaction,
        transactionStore: transactionStore
      )
      try activateRestoredTeardownEntry(
        transaction: &transaction,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        transactionStore: transactionStore
      )
      if deferFinalization {
        return SetupIntegrationResult(
          id: KeybindingProviderInspector.ownershipID,
          status: .removed,
          target: target.path,
          message: "Restored the prior skhd entry; aggregate finalization is pending",
          mutationAttempted: true,
          lifecycle: combinedLifecycle(recoveryLifecycle, teardownAction)
        )
      }
      try finalizeTeardown(
        preparation.provider,
        transaction: &transaction,
        transactionStore: transactionStore
      )
      return SetupIntegrationResult(
        id: KeybindingProviderInspector.ownershipID,
        status: .removed,
        target: target.path,
        message:
          recovered
          ? "Recovered the interrupted keybinding transaction, then restored \(preparation.restorationDescription); recovery lifecycle=\(recoveryLifecycle.rawValue); teardown lifecycle=\(teardownAction.rawValue)"
          : "Restored \(preparation.restorationDescription); lifecycle=\(teardownAction.rawValue)",
        mutationAttempted: true,
        lifecycle: combinedLifecycle(recoveryLifecycle, teardownAction)
      )
    } catch {
      let failure: any Error
      if transaction.phase.isRestorationFinalizing {
        failure = KeybindingsRecoveryRequiredError(
          cause: String(describing: error),
          rollbackCause:
            "the incumbent service already restarted on the restored entry; teardown finalization must resume"
        )
      } else {
        do {
          try preflightAndRollback(
            transaction,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            transactionStore: transactionStore
          )
          failure = KeybindingsApplyError.rolledBack(String(describing: error), .restart)
        } catch let rollbackError {
          failure = KeybindingsRecoveryRequiredError(
            cause: String(describing: error),
            rollbackCause: String(describing: rollbackError)
          )
        }
      }
      throw SetupOwnershipTransactionError(
        failure,
        integrationID: KeybindingProviderInspector.ownershipID,
        target: target
      )
    }
  }

  private func recoverForTeardown(
    _ pending: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws -> KeybindingLifecycleAction {
    let recoveryLifecycle = rollbackLifecycle(for: pending)
    if pending.isFinalizingTeardown {
      try completeTeardownFinalization(
        pending,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        transactionStore: transactionStore
      )
    } else {
      try preflightAndRollback(
        pending,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        transactionStore: transactionStore
      )
    }
    return recoveryLifecycle
  }

  private func prepareTeardown(
    record: SetupOwnershipRecord,
    stateRoot: URL,
    homeDirectory: URL,
    target: URL
  ) throws -> PreparedKeybindingsTeardown {
    let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    guard generation.status == .current, let generationID = generation.generationID else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let providerInspection = KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: generation
    )
    guard providerInspection.status == .managed else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let usesLegacySymlinkRestoration =
      record.retainedOriginalPath == nil
      && [.symbolicLink, .directorySymbolicLink].contains(record.originalKind ?? .absent)
    let restorationDescription =
      usesLegacySymlinkRestoration
      ? "the reviewed prior skhd symlink text (legacy record; exact inode metadata unavailable)"
      : "the exact prior skhd entry"
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    try provider.preflightOriginalRestoration()
    do {
      if lifecycle.service == nil { try lifecycle.preflight() }
    } catch {
      throw KeybindingsApplyError.blocked(String(describing: error))
    }
    return PreparedKeybindingsTeardown(
      generationID: generationID,
      restorationDescription: restorationDescription,
      provider: provider
    )
  }

  private func restoreTeardownEntry(
    _ provider: KeybindingProviderTransaction,
    transaction: inout KeybindingApplyTransaction,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    try transactionStore.write(transaction)
    try provider.restoreOriginalEntry()
    transaction = transaction.withPhase(.entryRestored)
    try transactionStore.write(transaction)
  }

  private func activateRestoredTeardownEntry(
    transaction: inout KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    transaction = transaction.withPhase(.activating)
    try transactionStore.write(transaction)
    if let service = lifecycle.service, let ownership = transaction.service?.previousOwnership {
      try service.restoreOriginal(ownership, home: homeDirectory)
      if ownership.original.running {
        try perform(.restart)
        try lifecycle.verifyProcess()
      }
    } else {
      try perform(.restart)
      try lifecycle.verifyProcess()
    }
    try KeybindingLifecycleEvidenceStore(stateRoot: stateRoot).remove()
  }

  private func finalizeTeardown(
    _ provider: KeybindingProviderTransaction,
    transaction: inout KeybindingApplyTransaction,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    transaction = transaction.withPhase(.restorationFinalizing)
    try transactionStore.write(transaction)
    if let service = lifecycle.service, let ownership = transaction.service?.previousOwnership {
      try service.finalizeTeardown(
        ownership, home: provider.homeDirectory, stateRoot: transactionStore.stateRoot)
    }
    try provider.finalizeOriginalRestoration()
    transaction = transaction.withPhase(.restorationFinalized)
    try transactionStore.write(transaction)
    try transactionStore.remove()
  }

  func preview(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String? = nil,
    json: Bool,
    profile: PortableProfile? = nil
  ) throws -> (output: String, succeeded: Bool) {
    do {
      guard isCanonicalStateRoot(stateRoot, homeDirectory: homeDirectory) else {
        throw KeybindingsApplyError.blocked(
          "keybinding apply requires the canonical per-user state root"
        )
      }
      let effectiveBehavior = planner.effectiveInspector.inspect(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        profile: profile
      )
      if effectiveBehavior.transaction.status == .invalid {
        throw KeybindingsApplyError.blocked(effectiveBehavior.transaction.message)
      }
      if let pending = effectiveBehavior.transaction.pendingTransaction {
        try preflightRecovery(
          pending,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        let lifecycleAction: KeybindingLifecycleAction =
          pending.phase == .activating
          ? pending.operation.reactivationLifecycle
          : .none
        let report = KeybindingsApplyReport(
          outcome: "recovery_planned",
          mutated: false,
          lifecycle: lifecycleAction,
          generationID: pending.previousGenerationID,
          message: "Would roll back interrupted \(pending.operation.rawValue) "
            + "phase \(pending.phase.rawValue) before replanning apply."
        )
        return (try report.render(json: json), true)
      }
      let preparation = try planner.prepare(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        ignoreTransaction: true,
        effectiveBehavior: effectiveBehavior,
        profile: profile
      )
      guard preparation.outcome != "blocked", preparation.composition != nil else {
        throw KeybindingsApplyError.blocked(
          preparation.blockingMessages.joined(separator: "; ")
        )
      }
      let serviceChange = try lifecycle.service?.prepare(home: homeDirectory, stateRoot: stateRoot)
      let eligibility = try eligibility(preparation, adopt: adopt)
      if serviceChange?.previous.running != false { try lifecycle.preflight() }
      if eligibility.operation.mutatesEntry {
        guard let evidence = preparation.provider.adoptionEvidence else {
          throw KeybindingsApplyError.blocked("provider mutation evidence is unavailable")
        }
        try KeybindingProviderTransaction(homeDirectory: homeDirectory).preflightInstall(
          expectedEvidence: evidence,
          approvedEvidenceDigest: adopt
        )
      }
      if preparation.outcome == "no_change" {
        try lifecycle.verifyProcess()
        let report = KeybindingsApplyReport(
          outcome: "no_change",
          mutated: false,
          lifecycle: .none,
          generationID: preparation.generation.generationID,
          message: "Keybindings are already converged."
        )
        return (try report.render(json: json), true)
      }
      let report = KeybindingsApplyReport(
        outcome: "planned",
        mutated: false,
        lifecycle: serviceChange?.previous.running == false ? .start : eligibility.lifecycle,
        generationID: preparation.generation.generationID,
        message:
          eligibility.operation == .adoptEntry
          ? "Would adopt the exact existing skhd entry, publish, and activate managed keybindings."
          : (serviceChange?.previous.running == false
            ? "Would publish managed keybindings, register the user service if missing, and start skhd; Accessibility remains manual."
            : "Would publish and activate managed keybindings.")
      )
      return (try report.render(json: json), true)
    } catch {
      let report = KeybindingsApplyReport.failure(
        outcome: "blocked",
        message: String(describing: error)
      )
      return (try report.render(json: json), false)
    }
  }

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String? = nil,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    guard isCanonicalStateRoot(stateRoot, homeDirectory: homeDirectory) else {
      let report = KeybindingsApplyReport.failure(
        outcome: "blocked",
        message: "keybinding apply requires the canonical per-user state root"
      )
      return (try report.render(json: json), false)
    }

    let evidence = Mutex(KeybindingsApplyEvidence())
    do {
      let result = try ActivationLock(root: stateRoot).withLock {
        #if MACARCHY_ACCEPTANCE_TESTING
          if let acceptanceFailure {
            try preflightAcceptanceFailure(
              acceptanceFailure,
              resourcesRoot: resourcesRoot,
              profileURL: profileURL,
              profileRequired: profileRequired,
              stateRoot: stateRoot,
              homeDirectory: homeDirectory,
              adopt: adopt
            )
          }
        #endif
        return try applyLocked(
          resourcesRoot: resourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          adopt: adopt,
          evidence: evidence,
          deferFinalization: false
        )
      }
      return (try result.render(json: json), result.succeeded)
    } catch {
      let outcome: String
      var observed = evidence.withLock { $0 }
      switch error {
      case is KeybindingsRecoveryRequiredError:
        outcome = "recovery_required"
        observed.mutated = true
      case KeybindingsApplyError.blocked:
        outcome = "blocked"
      case KeybindingsApplyError.rolledBack(_, let action):
        outcome = "failed"
        observed.mutated = true
        observed.lifecycle = action
      default:
        outcome = "failed"
      }
      let report = KeybindingsApplyReport.failure(
        outcome: outcome,
        mutated: observed.mutated,
        lifecycle: observed.lifecycle,
        message: String(describing: error)
      )
      return (try report.render(json: json), false)
    }
  }

  func applyIntegrationLocked(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    deferFinalization: Bool,
    profile: PortableProfile? = nil,
    approvedInputDigest: String? = nil
  ) throws -> SetupIntegrationResult {
    guard isCanonicalStateRoot(stateRoot, homeDirectory: homeDirectory) else {
      throw KeybindingsApplyError.blocked(
        "keybinding apply requires the canonical per-user state root"
      )
    }
    let report = try applyLocked(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      adopt: adopt,
      evidence: Mutex(KeybindingsApplyEvidence()),
      deferFinalization: deferFinalization,
      profile: profile,
      approvedInputDigest: approvedInputDigest
    )
    return SetupIntegrationResult(
      id: KeybindingProviderInspector.ownershipID,
      status: .owned,
      target: skhdEntry(homeDirectory).path,
      message: report.message,
      mutationAttempted: report.mutated,
      lifecycle: report.lifecycle
    )
  }

  func recoverPendingLocked(
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    let store = KeybindingApplyTransactionStore(stateRoot: stateRoot)
    guard let transaction = try store.read() else { return }
    _ = try recoverForTeardown(
      transaction,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      transactionStore: store
    )
  }

  func rollbackDeferredLocked(
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    let store = KeybindingApplyTransactionStore(stateRoot: stateRoot)
    guard let transaction = try store.read() else { return }
    guard !transaction.phase.isRestorationFinalizing else {
      throw KeybindingsApplyError.postcondition(
        "deferred keybinding transaction has crossed its rollback boundary"
      )
    }
    try preflightAndRollback(
      transaction,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      transactionStore: store
    )
  }

  func commitDeferredLocked(
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    let store = KeybindingApplyTransactionStore(stateRoot: stateRoot)
    guard var transaction = try store.read() else { return }
    if transaction.operation == .teardownEntry {
      try finalizeTeardown(
        KeybindingProviderTransaction(homeDirectory: homeDirectory),
        transaction: &transaction,
        transactionStore: store
      )
    } else {
      try finalizeApply(
        selectedGenerationID: transaction.generationID,
        transaction: transaction,
        activator: KeybindingGenerationActivator(stateRoot: stateRoot),
        homeDirectory: homeDirectory,
        transactionStore: store
      )
    }
  }

  private func applyLocked(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    evidence: borrowing Mutex<KeybindingsApplyEvidence>,
    deferFinalization: Bool,
    profile: PortableProfile? = nil,
    approvedInputDigest: String? = nil
  ) throws -> KeybindingsApplyReport {
    let transactionStore = KeybindingApplyTransactionStore(stateRoot: stateRoot)
    try recoverInterruptedApply(
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      transactionStore: transactionStore,
      evidence: evidence
    )
    let prepared = try prepareApply(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      adopt: adopt,
      profile: profile
    )

    if let approvedInputDigest {
      guard prepared.composition.inputDigest == approvedInputDigest,
        prepared.eligibility.operation == .updateGeneration,
        prepared.eligibility.lifecycle == .reload
      else {
        throw KeybindingsApplyError.blocked(
          "Keybinding inputs or ownership changed since the scoped save was validated")
      }
    }

    if prepared.preparation.outcome == "no_change" {
      try lifecycle.verifyProcess()
      let observed = evidence.withLock { $0 }
      return KeybindingsApplyReport(
        outcome: "no_change",
        mutated: observed.mutated,
        lifecycle: observed.lifecycle,
        generationID: prepared.preparation.generation.generationID,
        message: "Keybindings are already converged."
      )
    }

    let activator = KeybindingGenerationActivator(stateRoot: stateRoot)
    let needsGeneration = Self.publishesGeneration(
      prepared.preparation.generation,
      prepared.composition
    )
    let selectedGenerationID =
      needsGeneration
      ? "k-\(UUID().uuidString.lowercased())"
      : prepared.preparation.generation.generationID
    guard let selectedGenerationID else {
      throw KeybindingsApplyError.blocked("no valid generation is available for provider apply")
    }
    var transaction = KeybindingApplyTransaction(
      operation: prepared.eligibility.operation,
      phase: needsGeneration ? .staging : .staged,
      generationID: selectedGenerationID,
      previousGenerationID: prepared.preparation.generation.generationID,
      generationCreated: needsGeneration,
      service: prepared.service
    )
    do {
      let stagedGeneration = try stageApplyGeneration(
        prepared.composition,
        generationID: selectedGenerationID,
        activator: activator,
        transaction: &transaction,
        transactionStore: transactionStore
      )
      try installApplyProviderEntry(
        operation: prepared.eligibility.operation,
        providerEvidence: prepared.providerEvidence,
        approvedEvidenceDigest: adopt,
        homeDirectory: homeDirectory,
        transaction: &transaction,
        transactionStore: transactionStore
      )
      try activateApply(
        stagedGeneration: stagedGeneration,
        selectedGenerationID: selectedGenerationID,
        lifecycleAction: prepared.eligibility.lifecycle,
        activator: activator,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        transaction: &transaction,
        transactionStore: transactionStore
      )
      try verifyAppliedBehavior(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        profile: profile
      )
      if !deferFinalization {
        try finalizeApply(
          selectedGenerationID: selectedGenerationID,
          transaction: transaction,
          activator: activator,
          homeDirectory: homeDirectory,
          transactionStore: transactionStore
        )
      }
      return KeybindingsApplyReport(
        outcome: "applied",
        mutated: true,
        lifecycle: prepared.eligibility.lifecycle,
        generationID: selectedGenerationID,
        message: "Published and activated managed keybindings."
      )
    } catch {
      do {
        try preflightAndRollback(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          transactionStore: transactionStore
        )
      } catch let rollbackError {
        throw KeybindingsRecoveryRequiredError(
          cause: String(describing: error),
          rollbackCause: String(describing: rollbackError)
        )
      }
      throw KeybindingsApplyError.rolledBack(
        String(describing: error),
        transaction.phase == .activating ? prepared.eligibility.lifecycle : .none
      )
    }
  }

  private func recoverInterruptedApply(
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore,
    evidence: borrowing Mutex<KeybindingsApplyEvidence>
  ) throws {
    do {
      try KeybindingGenerationActivator(stateRoot: stateRoot).recoverResidue()
      guard let transaction = try transactionStore.read() else { return }
      evidence.withLock {
        $0.mutated = true
        if transaction.phase == .activating {
          $0.lifecycle = transaction.operation.reactivationLifecycle
        }
      }
      try preflightRecovery(
        transaction,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory
      )
      if transaction.isFinalizingTeardown {
        try completeTeardownFinalization(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          transactionStore: transactionStore
        )
      } else {
        try rollback(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          transactionStore: transactionStore
        )
      }
    } catch {
      throw KeybindingsRecoveryRequiredError(
        cause: "interrupted transaction recovery failed",
        rollbackCause: String(describing: error)
      )
    }
  }

  private func prepareApply(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    profile: PortableProfile? = nil
  ) throws -> PreparedKeybindingsApply {
    let serviceChange = try lifecycle.service?.prepare(home: homeDirectory, stateRoot: stateRoot)
    var preparation = try planner.prepare(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      profile: profile
    )
    guard preparation.outcome != "blocked", var composition = preparation.composition else {
      throw KeybindingsApplyError.blocked(preparation.blockingMessages.joined(separator: "; "))
    }
    var eligibilityDecision = try eligibility(preparation, adopt: adopt)
    if serviceChange?.previous.running == false {
      eligibilityDecision.lifecycle = .start
    }
    do {
      if serviceChange?.previous.running != false { try lifecycle.preflight() }
    } catch {
      throw KeybindingsApplyError.blocked(String(describing: error))
    }
    let providerEvidence = preparation.provider.adoptionEvidence
    if eligibilityDecision.operation.mutatesEntry {
      guard let providerEvidence else {
        throw KeybindingsApplyError.blocked("provider mutation evidence is unavailable")
      }
      do {
        try KeybindingProviderTransaction(homeDirectory: homeDirectory).preflightInstall(
          expectedEvidence: providerEvidence,
          approvedEvidenceDigest: adopt
        )
      } catch {
        throw KeybindingsApplyError.blocked(String(describing: error))
      }
    }

    #if MACARCHY_ACCEPTANCE_TESTING
      if let acceptanceFailure {
        preparation = try planner.prepare(
          resourcesRoot: resourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          profile: profile
        )
        guard preparation.outcome != "blocked", let finalComposition = preparation.composition
        else {
          throw KeybindingsApplyError.blocked(
            preparation.blockingMessages.joined(separator: "; ")
          )
        }
        composition = finalComposition
        eligibilityDecision = try eligibility(preparation, adopt: adopt)
        try validateAcceptanceFailure(
          acceptanceFailure,
          preparation: preparation,
          composition: composition,
          eligibility: eligibilityDecision
        )
      }
    #endif

    return PreparedKeybindingsApply(
      preparation: preparation,
      composition: composition,
      eligibility: eligibilityDecision,
      providerEvidence: providerEvidence,
      service: serviceChange
    )
  }

  private func stageApplyGeneration(
    _ composition: KeybindingComposition,
    generationID: String,
    activator: KeybindingGenerationActivator,
    transaction: inout KeybindingApplyTransaction,
    transactionStore: KeybindingApplyTransactionStore
  ) throws -> StagedKeybindingGeneration? {
    try transactionStore.write(transaction)
    guard transaction.generationCreated else { return nil }
    let stagedGeneration = try activator.stage(composition, generationID: generationID)
    transaction = transaction.withPhase(.staged)
    try transactionStore.write(transaction)
    return stagedGeneration
  }

  private func installApplyProviderEntry(
    operation: KeybindingApplyOperation,
    providerEvidence: KeybindingAdoptionEvidence?,
    approvedEvidenceDigest: String?,
    homeDirectory: URL,
    transaction: inout KeybindingApplyTransaction,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    guard operation.mutatesEntry else { return }
    guard let providerEvidence else {
      throw KeybindingsApplyError.blocked("provider mutation evidence is unavailable")
    }
    try KeybindingProviderTransaction(homeDirectory: homeDirectory).installEntry(
      expectedEvidence: providerEvidence,
      approvedEvidenceDigest: approvedEvidenceDigest
    )
    transaction = transaction.withPhase(.entryInstalled)
    try transactionStore.write(transaction)
  }

  private func activateApply(
    stagedGeneration: StagedKeybindingGeneration?,
    selectedGenerationID: String,
    lifecycleAction: KeybindingLifecycleAction,
    activator: KeybindingGenerationActivator,
    stateRoot: URL,
    homeDirectory: URL,
    transaction: inout KeybindingApplyTransaction,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    if let stagedGeneration { try activator.select(stagedGeneration) }
    transaction = transaction.withPhase(.currentSelected)
    try transactionStore.write(transaction)
    transaction = transaction.withPhase(.activating)
    try transactionStore.write(transaction)
    if let service = lifecycle.service, var change = transaction.service, !change.previous.running {
      if change.previous.registration == nil {
        change.installationAttempted = true
        transaction.service = change
        try transactionStore.write(transaction)
        change.installed = try service.install(home: homeDirectory)
        transaction.service = change
        try transactionStore.write(transaction)
      }
      guard let registration = change.expectedRegistration else {
        throw KeybindingsApplyError.lifecycle("skhd service has no registration after installation")
      }
      try service.start(home: homeDirectory, expected: registration)
    } else {
      try perform(lifecycleAction)
    }
    try lifecycle.verifyProcess()
    if let service = lifecycle.service {
      guard try service.inspect(home: homeDirectory).running else {
        throw KeybindingsApplyError.lifecycle("skhd user service is not running after activation")
      }
    }
    try persistLifecycleEvidence(
      action: lifecycleAction,
      generationID: selectedGenerationID,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory
    )
    #if MACARCHY_ACCEPTANCE_TESTING
      try acceptanceFailure?.failAfterVerifiedReload(generationID: selectedGenerationID)
    #endif
  }

  private func verifyAppliedBehavior(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    profile: PortableProfile? = nil
  ) throws {
    // Only the effective behavior is checked, so skip the plan's service prerequisites.
    let verified = planner.effectiveInspector.inspect(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      ignoreTransaction: true,
      profile: profile
    )
    guard verified.status == .converged else {
      throw KeybindingsApplyError.postcondition(
        "effective behavior remained \(verified.status.rawValue): \(verified.statusMessage)"
      )
    }
  }

  private func finalizeApply(
    selectedGenerationID: String,
    transaction: KeybindingApplyTransaction,
    activator: KeybindingGenerationActivator,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    var retained = Set([selectedGenerationID])
    if let previous = transaction.previousGenerationID { retained.insert(previous) }
    try activator.retainGenerations(retained)
    if let service = lifecycle.service, let change = transaction.service {
      try service.commit(change, home: homeDirectory, stateRoot: transactionStore.stateRoot)
    }
    try transactionStore.remove()
  }

  private func preflightAndRollback(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    try preflightRollback(transaction, stateRoot: stateRoot, homeDirectory: homeDirectory)
    try rollback(
      transaction,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      transactionStore: transactionStore
    )
  }

  private func rollback(
    _ originalTransaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    var transaction = originalTransaction
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    let restoredOriginalOwnership = try restoreRollbackProvider(
      transaction,
      provider: provider,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory
    )
    let activator = KeybindingGenerationActivator(stateRoot: stateRoot)
    try activator.restoreCurrent(generationID: transaction.previousGenerationID)
    if let service = lifecycle.service, let change = transaction.service,
      transaction.phase == .activating || change.installationAttempted
    {
      try service.rollback(change, home: homeDirectory, stateRoot: stateRoot)
    }
    try reactivateRollbackIfNeeded(transaction)
    if transaction.service?.previous.running == false {
      try KeybindingLifecycleEvidenceStore(stateRoot: stateRoot).remove()
    }
    let restored = try verifyRollbackGeneration(transaction, stateRoot: stateRoot)
    if restoredOriginalOwnership {
      try finalizeRollbackOriginalRestoration(
        provider,
        transaction: &transaction,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        transactionStore: transactionStore
      )
    }
    try verifyRollbackProvider(
      transaction,
      restoredGeneration: restored,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory
    )
    try persistRollbackLifecycleEvidence(
      transaction,
      restoredGeneration: restored,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory
    )
    try removeRolledBackGeneration(
      transaction,
      activator: activator
    )
    try transactionStore.remove()
  }

  private func restoreRollbackProvider(
    _ transaction: KeybindingApplyTransaction,
    provider: KeybindingProviderTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws -> Bool {
    if transaction.operation.mutatesEntry {
      if try keybindingOwnershipRecord(homeDirectory: homeDirectory) != nil {
        try provider.restoreOriginalEntry()
        return true
      } else if transaction.phase.isRestorationFinalizing {
        try verifyFinalizedOriginalRestoration(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        return true
      } else if transaction.phase == .entryInstalled || transaction.phase == .activating {
        throw entryDrift(homeDirectory)
      }
    } else if transaction.operation == .teardownEntry {
      try provider.restoreManagedEntry()
    }
    return false
  }

  private func reactivateRollbackIfNeeded(
    _ transaction: KeybindingApplyTransaction
  ) throws {
    if transaction.phase == .activating, transaction.service?.previous.running != false {
      try perform(transaction.operation.reactivationLifecycle)
      try lifecycle.verifyProcess()
    }
  }

  private func verifyRollbackGeneration(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL
  ) throws -> KeybindingGenerationInspection {
    let restored = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    if let previous = transaction.previousGenerationID {
      guard restored.status == .current, restored.generationID == previous else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore generation \(previous)"
        )
      }
    } else {
      guard restored.status == .missing else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore the missing generation state"
        )
      }
    }
    return restored
  }

  private func finalizeRollbackOriginalRestoration(
    _ provider: KeybindingProviderTransaction,
    transaction: inout KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    if !transaction.phase.isRestorationFinalizing {
      transaction = transaction.withPhase(.restorationFinalizing)
      try transactionStore.write(transaction)
    }
    if try keybindingOwnershipRecord(homeDirectory: homeDirectory) != nil {
      try provider.finalizeOriginalRestoration()
    } else {
      try verifyFinalizedOriginalRestoration(
        transaction,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory
      )
      try provider.finalizeCompletedTeardownResidue()
    }
    transaction = transaction.withPhase(.restorationFinalized)
    try transactionStore.write(transaction)
  }

  private func verifyRollbackProvider(
    _ transaction: KeybindingApplyTransaction,
    restoredGeneration: KeybindingGenerationInspection,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    let providerInspection = KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: restoredGeneration
    )
    switch transaction.operation {
    case .installEntry:
      guard
        providerInspection.status == .installRequired,
        providerInspection.ownership == "ordinary_directory"
      else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore the absent provider entry"
        )
      }
    case .adoptEntry:
      guard providerInspection.status == .adoptionRequired else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore the adopted provider entry"
        )
      }
    case .teardownEntry, .updateGeneration:
      guard providerInspection.status == .managed else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore managed provider ownership"
        )
      }
    }
  }

  private func persistRollbackLifecycleEvidence(
    _ transaction: KeybindingApplyTransaction,
    restoredGeneration: KeybindingGenerationInspection,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    if transaction.phase == .activating, transaction.service?.previous.running != false {
      if transaction.operation.mutatesEntry {
        try KeybindingLifecycleEvidenceStore(stateRoot: stateRoot).remove()
      } else if let generationID = restoredGeneration.generationID {
        try persistLifecycleEvidence(
          action: transaction.operation.reactivationLifecycle,
          generationID: generationID,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      }
    }
  }

  private func removeRolledBackGeneration(
    _ transaction: KeybindingApplyTransaction,
    activator: KeybindingGenerationActivator
  ) throws {
    if transaction.generationCreated {
      guard transaction.generationID != transaction.previousGenerationID else {
        throw KeybindingsApplyError.postcondition(
          "refusing to delete the generation restored by rollback"
        )
      }
      try activator.removeGeneration(transaction.generationID)
    }
  }

  private func perform(_ action: KeybindingLifecycleAction) throws {
    switch action {
    case .none:
      return
    case .reload:
      try lifecycle.reload()
    case .restart:
      try lifecycle.restart()
    case .start, .stop:
      throw KeybindingsApplyError.lifecycle(
        "first-use service changes require durable service state")
    }
  }

  private func persistLifecycleEvidence(
    action: KeybindingLifecycleAction,
    generationID: String,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    guard action != .none else {
      throw KeybindingsApplyError.postcondition("no lifecycle action can produce success evidence")
    }
    let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    let provider = KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: generation
    )
    let process = lifecycle.inspectProcess()
    guard
      generation.status == .current,
      generation.generationID == generationID,
      provider.status == .managed,
      process.status == .running
    else {
      throw KeybindingsApplyError.postcondition(
        "cannot correlate lifecycle success to the selected generation, managed entry, and "
          + "supported process"
      )
    }
    try KeybindingLifecycleEvidenceStore(stateRoot: stateRoot).write(
      try KeybindingLifecycleEvidence(
        generationID: generationID,
        providerEntryPoint: provider.entryPoint,
        providerTarget: provider.expectedTarget,
        action: action,
        process: process
      )
    )
  }

  private func keybindingOwnershipRecord(
    homeDirectory: URL
  ) throws -> SetupOwnershipRecord? {
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    return try SetupOwnershipManager().keybindingOwnershipRecord(context: context)
  }

  private func preflightRollback(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    if let service = lifecycle.service, let change = transaction.service {
      try service.validateRecovery(change, home: homeDirectory)
    }
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    let ownershipRecord = try keybindingOwnershipRecord(homeDirectory: homeDirectory)
    switch transaction.operation {
    case .installEntry, .adoptEntry:
      if ownershipRecord != nil {
        if transaction.phase.isRestorationFinalizing {
          try provider.preflightOriginalRestorationFinalization()
        } else {
          try provider.preflightOriginalRestoration()
        }
      } else if transaction.phase.isRestorationFinalizing {
        try verifyFinalizedOriginalRestoration(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      } else if transaction.phase == .entryInstalled || transaction.phase == .activating {
        throw entryDrift(homeDirectory)
      } else {
        try verifyUnclaimedOriginalProvider(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      }
    case .teardownEntry:
      guard ownershipRecord != nil else {
        throw entryDrift(homeDirectory)
      }
      try provider.preflightManagedRestoration()
    case .updateGeneration:
      guard ownershipRecord != nil else {
        throw entryDrift(homeDirectory)
      }
      let inspection = inspectCurrentProvider(stateRoot: stateRoot, homeDirectory: homeDirectory)
      guard inspection.status == .managed else {
        throw SetupOwnershipError.ownershipDrift(URL(filePath: inspection.entryPoint))
      }
    }
    if transaction.phase == .activating, transaction.service == nil {
      try lifecycle.preflight()
    }
  }

  private func preflightRecovery(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    if transaction.isFinalizingTeardown {
      if try keybindingOwnershipRecord(homeDirectory: homeDirectory) != nil {
        try KeybindingProviderTransaction(homeDirectory: homeDirectory)
          .preflightOriginalRestorationFinalization()
      } else {
        try verifyFinalizedOriginalRestoration(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      }
    } else {
      try preflightRollback(
        transaction,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory
      )
    }
  }

  private func previewTeardownAfterRecovery(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws -> SetupIntegrationResult {
    let target = skhdEntry(homeDirectory)
    let recoveryLifecycle = rollbackLifecycle(for: transaction)
    try preflightRecovery(transaction, stateRoot: stateRoot, homeDirectory: homeDirectory)

    let teardownFollows =
      !transaction.isFinalizingTeardown
      && (transaction.operation == .updateGeneration || transaction.operation == .teardownEntry)
    if teardownFollows {
      try KeybindingProviderTransaction(homeDirectory: homeDirectory)
        .preflightOriginalRestoration()
      try lifecycle.preflight()
    }
    let teardownLifecycle: KeybindingLifecycleAction = teardownFollows ? .restart : .none
    let message =
      teardownFollows
      ? "Would recover interrupted keybinding \(transaction.operation.rawValue), then restore the exact prior skhd entry; recovery lifecycle=\(recoveryLifecycle.rawValue); teardown lifecycle=restart"
      : "Would recover interrupted keybinding \(transaction.operation.rawValue); no Macarchy-owned provider entry would remain; recovery lifecycle=\(recoveryLifecycle.rawValue); teardown lifecycle=none"
    return SetupIntegrationResult(
      id: KeybindingProviderInspector.ownershipID,
      status: .planned,
      target: target.path,
      message: message,
      mutationAttempted: false,
      lifecycle: combinedLifecycle(recoveryLifecycle, teardownLifecycle)
    )
  }

  private func verifyUnclaimedOriginalProvider(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    let inspection = inspectCurrentProvider(stateRoot: stateRoot, homeDirectory: homeDirectory)
    if transaction.operation == .installEntry {
      guard
        inspection.status == .installRequired,
        ["ordinary_directory", "absent"].contains(inspection.ownership)
      else {
        throw SetupOwnershipError.ownershipDrift(URL(filePath: inspection.entryPoint))
      }
    } else {
      guard inspection.status == .adoptionRequired else {
        throw SetupOwnershipError.ownershipDrift(URL(filePath: inspection.entryPoint))
      }
    }
  }

  private func rollbackLifecycle(
    for transaction: KeybindingApplyTransaction
  ) -> KeybindingLifecycleAction {
    guard transaction.phase == .activating else { return .none }
    if transaction.service?.previous.running == false { return .stop }
    return transaction.operation.reactivationLifecycle
  }

  private func combinedLifecycle(
    _ first: KeybindingLifecycleAction,
    _ second: KeybindingLifecycleAction
  ) -> KeybindingLifecycleAction {
    if second == .start || second == .stop { return second }
    if first == .start || first == .stop { return first }
    if first == .restart || second == .restart { return .restart }
    if first == .reload || second == .reload { return .reload }
    return .none
  }

  private func verifyFinalizedOriginalRestoration(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    guard transaction.phase.isRestorationFinalizing else {
      throw entryDrift(homeDirectory)
    }
    let inspection = inspectCurrentProvider(stateRoot: stateRoot, homeDirectory: homeDirectory)
    guard
      inspection.status == .adoptionRequired
        || (inspection.status == .installRequired
          && inspection.ownership == "ordinary_directory")
    else {
      throw SetupOwnershipError.ownershipDrift(URL(filePath: inspection.entryPoint))
    }
    try KeybindingProviderTransaction(homeDirectory: homeDirectory)
      .preflightCompletedRestorationResidue()
  }

  private func completeTeardownFinalization(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    guard transaction.isFinalizingTeardown else {
      throw entryDrift(homeDirectory)
    }
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    if let service = lifecycle.service, let ownership = transaction.service?.previousOwnership {
      try service.finalizeTeardown(ownership, home: homeDirectory, stateRoot: stateRoot)
    }
    if try keybindingOwnershipRecord(homeDirectory: homeDirectory) != nil {
      try provider.preflightOriginalRestorationFinalization()
      try provider.finalizeOriginalRestoration()
    } else {
      try verifyFinalizedOriginalRestoration(
        transaction,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory
      )
      try provider.finalizeCompletedTeardownResidue()
    }
    if transaction.phase != .restorationFinalized {
      try transactionStore.write(transaction.withPhase(.restorationFinalized))
    }
    try transactionStore.remove()
  }

  private func eligibility(
    _ preparation: KeybindingsPlanPreparation,
    adopt: String?
  ) throws -> KeybindingsApplyEligibility {
    switch preparation.provider.status {
    case .managed:
      return KeybindingsApplyEligibility(operation: .updateGeneration, lifecycle: .reload)
    case .installRequired
    where ["ordinary_directory", "absent"].contains(preparation.provider.ownership):
      return KeybindingsApplyEligibility(operation: .installEntry, lifecycle: .restart)
    case .installRequired:
      throw KeybindingsApplyError.blocked(
        "clean apply requires an ordinary or absent ~/.config/skhd directory"
      )
    case .adoptionRequired:
      guard let expected = preparation.provider.adoptionEvidenceDigest else {
        throw KeybindingsApplyError.blocked("adoption evidence is unavailable")
      }
      guard let adopt else {
        throw KeybindingsApplyError.blocked(
          "existing skhd configuration requires --adopt \(expected)"
        )
      }
      guard adopt == expected else {
        throw KeybindingsApplyError.blocked(
          "--adopt evidence does not match the current preview; review \(expected)"
        )
      }
      return KeybindingsApplyEligibility(operation: .adoptEntry, lifecycle: .restart)
    case .blocked:
      throw KeybindingsApplyError.blocked(preparation.provider.message)
    }
  }

  #if MACARCHY_ACCEPTANCE_TESTING
    private func preflightAcceptanceFailure(
      _ failure: KeybindingAcceptanceFailureInjector,
      resourcesRoot: URL,
      profileURL: URL,
      profileRequired: Bool,
      stateRoot: URL,
      homeDirectory: URL,
      adopt: String?
    ) throws {
      let preparation = try planner.prepare(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory
      )
      guard preparation.outcome != "blocked", let composition = preparation.composition else {
        throw KeybindingsApplyError.blocked(
          preparation.blockingMessages.joined(separator: "; ")
        )
      }
      let eligibility = try eligibility(preparation, adopt: adopt)
      try validateAcceptanceFailure(
        failure,
        preparation: preparation,
        composition: composition,
        eligibility: eligibility
      )
    }

    private func validateAcceptanceFailure(
      _ failure: KeybindingAcceptanceFailureInjector,
      preparation: KeybindingsPlanPreparation,
      composition: KeybindingComposition,
      eligibility: KeybindingsApplyEligibility
    ) throws {
      try failure.validate(
        operation: eligibility.operation,
        lifecycle: eligibility.lifecycle,
        publishesGeneration: Self.publishesGeneration(preparation.generation, composition),
        outcome: preparation.outcome,
        providerStatus: preparation.provider.status
      )
    }
  #endif

  private static func publishesGeneration(
    _ generation: KeybindingGenerationInspection,
    _ composition: KeybindingComposition
  ) -> Bool {
    generation.status == .missing
      || generation.inputDigest != composition.inputDigest
      || generation.renderedDigest != composition.renderedDigest
  }

  private func inspectCurrentProvider(
    stateRoot: URL,
    homeDirectory: URL
  ) -> KeybindingProviderInspection {
    KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    )
  }

  /// The skhd entry point under the caller's home, as passed (not standardized).
  private func skhdEntry(_ homeDirectory: URL) -> URL {
    homeDirectory.appending(path: ".config/skhd/skhdrc")
  }

  private func entryDrift(_ homeDirectory: URL) -> SetupOwnershipError {
    .ownershipDrift(skhdEntry(homeDirectory))
  }

  private func isCanonicalStateRoot(_ stateRoot: URL, homeDirectory: URL) -> Bool {
    stateRoot.standardizedFileURL
      == homeDirectory.appending(
        path: ".config/macarchy",
        directoryHint: .isDirectory
      ).standardizedFileURL
  }
}

#if MACARCHY_ACCEPTANCE_TESTING
  private final class KeybindingAcceptanceFailureInjector: Sendable {
    private let armed = Mutex(true)
    private let observer: @Sendable (String) -> Void

    init(observer: @escaping @Sendable (String) -> Void = { _ in }) {
      self.observer = observer
    }

    func validate(
      operation: KeybindingApplyOperation,
      lifecycle: KeybindingLifecycleAction,
      publishesGeneration: Bool,
      outcome: String,
      providerStatus: KeybindingProviderStatus
    ) throws {
      guard
        operation == .updateGeneration,
        lifecycle == .reload,
        publishesGeneration,
        outcome == "ready",
        providerStatus == .managed
      else {
        throw KeybindingsApplyError.blocked(
          "the acceptance rollback checkpoint requires one managed generation update with reload"
        )
      }
    }

    func failAfterVerifiedReload(generationID: String) throws {
      let shouldFail = armed.withLock { armed in
        guard armed else { return false }
        armed = false
        return true
      }
      guard shouldFail else { return }
      observer(generationID)
      throw KeybindingsApplyError.postcondition(
        "acceptance checkpoint failed after verified managed update reload"
      )
    }
  }
#endif

private struct KeybindingsApplyEvidence: Sendable {
  var mutated = false
  var lifecycle = KeybindingLifecycleAction.none
}

private struct PreparedKeybindingsApply {
  let preparation: KeybindingsPlanPreparation
  let composition: KeybindingComposition
  let eligibility: KeybindingsApplyEligibility
  let providerEvidence: KeybindingAdoptionEvidence?
  let service: SkhdServiceChange?
}

private struct KeybindingsApplyEligibility {
  let operation: KeybindingApplyOperation
  var lifecycle: KeybindingLifecycleAction
}

private struct PreparedKeybindingsTeardown {
  let generationID: String
  let restorationDescription: String
  let provider: KeybindingProviderTransaction
}

private struct KeybindingsApplyReport: Encodable {
  let schemaVersion = 1
  let operation = "keybindings_apply"
  let outcome: String
  let mutated: Bool
  let lifecycle: KeybindingLifecycleAction
  let generationID: String?
  let message: String

  var succeeded: Bool { outcome == "applied" || outcome == "no_change" }

  static func failure(
    outcome: String,
    mutated: Bool = false,
    lifecycle: KeybindingLifecycleAction = .none,
    message: String
  ) -> Self {
    Self(
      outcome: outcome,
      mutated: mutated,
      lifecycle: lifecycle,
      generationID: nil,
      message: message
    )
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    return """
      Macarchy keybindings apply [\(outcome)]:
      - mutated: \(mutated)
      - lifecycle: \(lifecycle.rawValue)
      - generation: \(generationID ?? "none")
      - \(message)
      """
  }
}

enum KeybindingsApplyError: Error, CustomStringConvertible, Sendable {
  case blocked(String)
  case lifecycle(String)
  case postcondition(String)
  case rolledBack(String, KeybindingLifecycleAction)

  var description: String {
    switch self {
    case .blocked(let reason):
      "keybinding apply is blocked: \(reason)"
    case .lifecycle(let reason):
      "keybinding lifecycle failed: \(reason)"
    case .postcondition(let reason):
      "keybinding postcondition failed: \(reason)"
    case .rolledBack(let reason, _):
      "keybinding apply failed and was rolled back: \(reason)"
    }
  }
}

struct KeybindingsRecoveryRequiredError: Error, CustomStringConvertible, Sendable {
  let cause: String
  let rollbackCause: String

  var description: String {
    "keybinding recovery is required after '\(cause)'; rollback also failed: \(rollbackCause)"
  }
}
