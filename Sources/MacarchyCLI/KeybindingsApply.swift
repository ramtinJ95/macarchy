import Darwin
import Foundation
import Synchronization
import ThemeCore

enum KeybindingLifecycleAction: String, Codable, Sendable {
  case none
  case reload
  case restart
}

struct KeybindingLifecycleController: Sendable {
  let preflight: @Sendable () throws -> Void
  let restart: @Sendable () throws -> Void
  let reload: @Sendable () throws -> Void
  let verifyProcess: @Sendable () throws -> Void
  let inspectProcess: @Sendable () -> KeybindingProcessInspection

  init(
    preflight: @escaping @Sendable () throws -> Void = {},
    restart: @escaping @Sendable () throws -> Void,
    reload: @escaping @Sendable () throws -> Void,
    verifyProcess: @escaping @Sendable () throws -> Void,
    inspectProcess: @escaping @Sendable () -> KeybindingProcessInspection = { .notRunning }
  ) {
    self.preflight = preflight
    self.restart = restart
    self.reload = reload
    self.verifyProcess = verifyProcess
    self.inspectProcess = inspectProcess
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
    inspectProcess: KeybindingProcessInspector.live.inspect
  )

  private static func requireSupportedProcess() throws {
    var last = KeybindingProcessInspection.notRunning
    for _ in 0..<20 {
      last = KeybindingProcessInspector.live.inspect()
      if last.status == .running { return }
      if last.status == .unsupported || last.status == .unavailable { break }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw KeybindingsApplyError.lifecycle(last.message)
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
        )
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

    func withAcceptanceManagedUpdateRollbackCheckpoint() -> Self {
      Self(
        lifecycle: lifecycle,
        planner: planner,
        acceptanceFailure: KeybindingAcceptanceFailureInjector()
      )
    }
  #endif

  func setupIntegration(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    dryRun: Bool
  ) throws -> SetupIntegrationResult {
    let execution =
      if dryRun {
        try preview(
          resourcesRoot: resourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          adopt: adopt,
          json: true,
          preflightLifecycle: false
        )
      } else {
        try execute(
          resourcesRoot: resourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          adopt: adopt,
          json: true
        )
      }
    let report = try JSONDecoder().decode(
      KeybindingsApplySetupPayload.self,
      from: Data(execution.output.utf8)
    )
    return SetupIntegrationResult(
      id: KeybindingProviderInspector.ownershipID,
      status:
        execution.succeeded
        ? (dryRun ? .planned : .owned) : .failed,
      target: homeDirectory.appending(path: ".config/skhd/skhdrc").path,
      message: report.message,
      mutationAttempted: report.mutated,
      lifecycle: report.lifecycle
    )
  }

  func teardownLocked(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool
  ) throws -> SetupIntegrationResult {
    let target = homeDirectory.appending(path: ".config/skhd/skhdrc")
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
      recoveryLifecycle = rollbackLifecycle(for: pending)
      if pending.operation == .teardownEntry,
        [.restorationFinalizing, .restorationFinalized].contains(pending.phase)
      {
        try completeTeardownFinalization(
          pending,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          transactionStore: transactionStore
        )
      } else {
        try preflightRollback(
          pending,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        try rollback(
          pending,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          transactionStore: transactionStore
        )
      }
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
    try KeybindingProviderInspector.validateOwnershipRecord(
      record,
      context: SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    )
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    try provider.preflightOriginalRestoration()
    do {
      try lifecycle.preflight()
    } catch {
      throw KeybindingsApplyError.blocked(String(describing: error))
    }
    if dryRun {
      return SetupIntegrationResult(
        id: KeybindingProviderInspector.ownershipID,
        status: .planned,
        target: target.path,
        message:
          "Would restore the exact prior skhd entry and restart the incumbent service; lifecycle=restart",
        mutationAttempted: false,
        lifecycle: .restart
      )
    }

    var transaction = KeybindingApplyTransaction(
      operation: .teardownEntry,
      phase: .staged,
      generationID: generationID,
      previousGenerationID: generationID,
      generationCreated: false
    )
    do {
      try transactionStore.write(transaction)
      try provider.restoreOriginalEntry()
      transaction = transaction.withPhase(.entryRestored)
      try transactionStore.write(transaction)
      transaction = transaction.withPhase(.activating)
      try transactionStore.write(transaction)
      try perform(.restart)
      try lifecycle.verifyProcess()
      try KeybindingLifecycleEvidenceStore(stateRoot: stateRoot).remove()
      transaction = transaction.withPhase(.restorationFinalizing)
      try transactionStore.write(transaction)
      try provider.finalizeOriginalRestoration()
      transaction = transaction.withPhase(.restorationFinalized)
      try transactionStore.write(transaction)
      try transactionStore.remove()
      return SetupIntegrationResult(
        id: KeybindingProviderInspector.ownershipID,
        status: .removed,
        target: target.path,
        message:
          recovered
          ? "Recovered the interrupted keybinding transaction, then restored the exact prior skhd entry; recovery lifecycle=\(recoveryLifecycle.rawValue); teardown lifecycle=restart"
          : "Restored the exact prior skhd entry; lifecycle=restart",
        mutationAttempted: true,
        lifecycle: combinedLifecycle(recoveryLifecycle, .restart)
      )
    } catch {
      if transaction.phase == .restorationFinalizing
        || transaction.phase == .restorationFinalized
      {
        throw SetupOwnershipTransactionError(
          KeybindingsRecoveryRequiredError(
            cause: String(describing: error),
            rollbackCause:
              "the incumbent service already restarted on the restored entry; teardown finalization must resume"
          ),
          integrationID: KeybindingProviderInspector.ownershipID,
          target: target
        )
      }
      do {
        try preflightRollback(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        try rollback(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          transactionStore: transactionStore
        )
      } catch let rollbackError {
        throw SetupOwnershipTransactionError(
          KeybindingsRecoveryRequiredError(
            cause: String(describing: error),
            rollbackCause: String(describing: rollbackError)
          ),
          integrationID: KeybindingProviderInspector.ownershipID,
          target: target
        )
      }
      throw SetupOwnershipTransactionError(
        KeybindingsApplyError.rolledBack(String(describing: error), .restart),
        integrationID: KeybindingProviderInspector.ownershipID,
        target: target
      )
    }
  }

  func preview(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String? = nil,
    json: Bool,
    preflightLifecycle: Bool = true
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
        homeDirectory: homeDirectory
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
          ? (pending.operation == .updateGeneration ? .reload : .restart)
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
        effectiveBehavior: effectiveBehavior
      )
      guard preparation.outcome != "blocked", preparation.composition != nil else {
        throw KeybindingsApplyError.blocked(
          preparation.blockingMessages.joined(separator: "; ")
        )
      }
      let eligibility = try eligibility(preparation, adopt: adopt)
      if preflightLifecycle { try lifecycle.preflight() }
      if eligibility.operation == .installEntry || eligibility.operation == .adoptEntry {
        guard let evidence = preparation.provider.adoptionEvidence else {
          throw KeybindingsApplyError.blocked("provider mutation evidence is unavailable")
        }
        try KeybindingProviderTransaction(homeDirectory: homeDirectory).preflightInstall(
          expectedEvidence: evidence,
          approvedEvidenceDigest: adopt
        )
      }
      if preparation.outcome == "no_change" {
        if preflightLifecycle { try lifecycle.verifyProcess() }
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
        lifecycle: eligibility.lifecycle,
        generationID: preparation.generation.generationID,
        message:
          eligibility.operation == .adoptEntry
          ? "Would adopt the exact existing skhd entry, publish, and activate managed keybindings."
          : "Would publish and activate managed keybindings."
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
          evidence: evidence
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

  private func applyLocked(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    evidence: borrowing Mutex<KeybindingsApplyEvidence>
  ) throws -> KeybindingsApplyReport {
    let transactionStore = KeybindingApplyTransactionStore(stateRoot: stateRoot)
    do {
      try KeybindingGenerationActivator(stateRoot: stateRoot).recoverResidue()
      if let transaction = try transactionStore.read() {
        evidence.withLock {
          $0.mutated = true
          if transaction.phase == .activating {
            $0.lifecycle =
              transaction.operation == .updateGeneration
              ? KeybindingLifecycleAction.reload
              : KeybindingLifecycleAction.restart
          }
        }
        try preflightRecovery(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        if transaction.operation == .teardownEntry,
          [.restorationFinalizing, .restorationFinalized].contains(transaction.phase)
        {
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
      }
    } catch {
      throw KeybindingsRecoveryRequiredError(
        cause: "interrupted transaction recovery failed",
        rollbackCause: String(describing: error)
      )
    }

    let preparation = try planner.prepare(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory
    )
    guard preparation.outcome != "blocked", let composition = preparation.composition else {
      throw KeybindingsApplyError.blocked(preparation.blockingMessages.joined(separator: "; "))
    }
    let eligibility = try eligibility(preparation, adopt: adopt)
    do {
      try lifecycle.preflight()
    } catch {
      throw KeybindingsApplyError.blocked(String(describing: error))
    }
    let providerEvidence = preparation.provider.adoptionEvidence
    if eligibility.operation == .installEntry || eligibility.operation == .adoptEntry {
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
    if preparation.outcome == "no_change" {
      try lifecycle.verifyProcess()
      let observed = evidence.withLock { $0 }
      return KeybindingsApplyReport(
        outcome: "no_change",
        mutated: observed.mutated,
        lifecycle: observed.lifecycle,
        generationID: preparation.generation.generationID,
        message: "Keybindings are already converged."
      )
    }

    let operation = eligibility.operation
    let lifecycleAction = eligibility.lifecycle

    let activator = KeybindingGenerationActivator(stateRoot: stateRoot)
    let needsGeneration =
      preparation.generation.status == .missing
      || preparation.generation.inputDigest != composition.inputDigest
      || preparation.generation.renderedDigest != composition.renderedDigest
    let selectedGenerationID =
      needsGeneration
      ? "k-\(UUID().uuidString.lowercased())"
      : preparation.generation.generationID
    guard let selectedGenerationID else {
      throw KeybindingsApplyError.blocked("no valid generation is available for provider apply")
    }
    var transaction = KeybindingApplyTransaction(
      operation: operation,
      phase: needsGeneration ? .staging : .staged,
      generationID: selectedGenerationID,
      previousGenerationID: preparation.generation.generationID,
      generationCreated: needsGeneration
    )
    do {
      try transactionStore.write(transaction)
      var stagedGeneration: StagedKeybindingGeneration?
      if needsGeneration {
        stagedGeneration = try activator.stage(
          composition,
          generationID: selectedGenerationID
        )
        transaction = transaction.withPhase(.staged)
        try transactionStore.write(transaction)
      }
      if operation == .installEntry || operation == .adoptEntry {
        guard let providerEvidence else {
          throw KeybindingsApplyError.blocked("provider mutation evidence is unavailable")
        }
        try KeybindingProviderTransaction(homeDirectory: homeDirectory).installEntry(
          expectedEvidence: providerEvidence,
          approvedEvidenceDigest: adopt
        )
        transaction = transaction.withPhase(.entryInstalled)
        try transactionStore.write(transaction)
      }
      if let stagedGeneration { try activator.select(stagedGeneration) }
      transaction = transaction.withPhase(.currentSelected)
      try transactionStore.write(transaction)

      transaction = transaction.withPhase(.activating)
      try transactionStore.write(transaction)
      try perform(lifecycleAction)
      try lifecycle.verifyProcess()

      try persistLifecycleEvidence(
        action: lifecycleAction,
        generationID: selectedGenerationID,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory
      )

      #if MACARCHY_ACCEPTANCE_TESTING
        try acceptanceFailure?.failAfterVerifiedReload()
      #endif

      let verified = try planner.prepare(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        ignoreTransaction: true
      )
      guard verified.effectiveBehavior.status == .converged else {
        throw KeybindingsApplyError.postcondition(
          "effective behavior remained \(verified.effectiveBehavior.status.rawValue): "
            + verified.effectiveBehavior.statusMessage
        )
      }
      var retained = Set([selectedGenerationID])
      if let previous = transaction.previousGenerationID { retained.insert(previous) }
      try activator.retainGenerations(retained)
      try transactionStore.remove()
      return KeybindingsApplyReport(
        outcome: "applied",
        mutated: true,
        lifecycle: lifecycleAction,
        generationID: selectedGenerationID,
        message: "Published and activated managed keybindings."
      )
    } catch {
      do {
        try preflightRollback(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        try rollback(
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
        transaction.phase == .activating ? lifecycleAction : .none
      )
    }
  }

  private func rollback(
    _ originalTransaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    var transaction = originalTransaction
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    var restoredOriginalOwnership = false
    if transaction.operation == .installEntry || transaction.operation == .adoptEntry {
      let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
      let records = try SetupOwnershipManager().readRecords(context: context)
      if records.contains(where: { $0.id == KeybindingProviderInspector.ownershipID }) {
        try provider.restoreOriginalEntry()
        restoredOriginalOwnership = true
      } else if [.restorationFinalizing, .restorationFinalized].contains(transaction.phase) {
        try verifyFinalizedOriginalRestoration(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
        restoredOriginalOwnership = true
      } else if transaction.phase == .entryInstalled || transaction.phase == .activating {
        throw SetupOwnershipError.ownershipDrift(
          homeDirectory.appending(path: ".config/skhd/skhdrc")
        )
      }
    } else if transaction.operation == .teardownEntry {
      try provider.restoreManagedEntry()
    }
    let activator = KeybindingGenerationActivator(stateRoot: stateRoot)
    try activator.restoreCurrent(generationID: transaction.previousGenerationID)
    if transaction.phase == .activating {
      try perform(transaction.operation == .updateGeneration ? .reload : .restart)
      try lifecycle.verifyProcess()
    }
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
    if restoredOriginalOwnership {
      if transaction.phase != .restorationFinalizing
        && transaction.phase != .restorationFinalized
      {
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
    let providerInspection = KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: restored
    )
    if transaction.operation == .installEntry {
      guard
        providerInspection.status == .installRequired,
        providerInspection.ownership == "ordinary_directory"
      else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore the absent provider entry"
        )
      }
    } else if transaction.operation == .adoptEntry {
      guard providerInspection.status == .adoptionRequired else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore the adopted provider entry"
        )
      }
    } else if transaction.operation == .teardownEntry {
      guard providerInspection.status == .managed else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore managed provider ownership"
        )
      }
    } else {
      guard providerInspection.status == .managed else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore managed provider ownership"
        )
      }
    }
    if transaction.phase == .activating {
      if transaction.operation == .installEntry || transaction.operation == .adoptEntry {
        try KeybindingLifecycleEvidenceStore(stateRoot: stateRoot).remove()
      } else if let generationID = restored.generationID {
        try persistLifecycleEvidence(
          action: transaction.operation == .updateGeneration ? .reload : .restart,
          generationID: generationID,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      }
    }
    if transaction.generationCreated {
      guard transaction.generationID != transaction.previousGenerationID else {
        throw KeybindingsApplyError.postcondition(
          "refusing to delete the generation restored by rollback"
        )
      }
      try activator.removeGeneration(transaction.generationID)
    }
    try transactionStore.remove()
  }

  private func perform(_ action: KeybindingLifecycleAction) throws {
    switch action {
    case .none:
      return
    case .reload:
      try lifecycle.reload()
    case .restart:
      try lifecycle.restart()
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
    return try SetupOwnershipManager().readRecords(context: context).first {
      $0.id == KeybindingProviderInspector.ownershipID
    }
  }

  private func preflightRollback(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    let ownershipRecord = try keybindingOwnershipRecord(homeDirectory: homeDirectory)
    switch transaction.operation {
    case .installEntry, .adoptEntry:
      if ownershipRecord != nil {
        try provider.preflightOriginalRestoration()
      } else if [.restorationFinalizing, .restorationFinalized].contains(transaction.phase) {
        try verifyFinalizedOriginalRestoration(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      } else if transaction.phase == .entryInstalled || transaction.phase == .activating {
        throw SetupOwnershipError.ownershipDrift(
          homeDirectory.appending(path: ".config/skhd/skhdrc")
        )
      } else {
        try verifyUnclaimedOriginalProvider(
          transaction,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      }
    case .teardownEntry:
      guard ownershipRecord != nil else {
        throw SetupOwnershipError.ownershipDrift(
          homeDirectory.appending(path: ".config/skhd/skhdrc")
        )
      }
      try provider.preflightManagedRestoration()
    case .updateGeneration:
      guard ownershipRecord != nil else {
        throw SetupOwnershipError.ownershipDrift(
          homeDirectory.appending(path: ".config/skhd/skhdrc")
        )
      }
      let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
      let inspection = KeybindingProviderInspector().inspect(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        generation: generation
      )
      guard inspection.status == .managed else {
        throw SetupOwnershipError.ownershipDrift(URL(filePath: inspection.entryPoint))
      }
    }
    if transaction.phase == .activating {
      try lifecycle.preflight()
    }
  }

  private func preflightRecovery(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    let finalizingTeardown =
      transaction.operation == .teardownEntry
      && [.restorationFinalizing, .restorationFinalized].contains(transaction.phase)
    if finalizingTeardown {
      if try keybindingOwnershipRecord(homeDirectory: homeDirectory) != nil {
        try KeybindingProviderTransaction(homeDirectory: homeDirectory)
          .preflightOriginalRestoration()
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
    let target = homeDirectory.appending(path: ".config/skhd/skhdrc")
    let recoveryLifecycle = rollbackLifecycle(for: transaction)
    let finalizingTeardown =
      transaction.operation == .teardownEntry
      && [.restorationFinalizing, .restorationFinalized].contains(transaction.phase)
    if finalizingTeardown {
      if try keybindingOwnershipRecord(homeDirectory: homeDirectory) != nil {
        try KeybindingProviderTransaction(homeDirectory: homeDirectory)
          .preflightOriginalRestoration()
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

    let teardownFollows =
      !finalizingTeardown
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
    let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    let inspection = KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: generation
    )
    if transaction.operation == .installEntry {
      guard
        inspection.status == .installRequired,
        inspection.ownership == "ordinary_directory"
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
    return transaction.operation == .updateGeneration ? .reload : .restart
  }

  private func combinedLifecycle(
    _ first: KeybindingLifecycleAction,
    _ second: KeybindingLifecycleAction
  ) -> KeybindingLifecycleAction {
    if first == .restart || second == .restart { return .restart }
    if first == .reload || second == .reload { return .reload }
    return .none
  }

  private func verifyFinalizedOriginalRestoration(
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL
  ) throws {
    guard [.restorationFinalizing, .restorationFinalized].contains(transaction.phase) else {
      throw SetupOwnershipError.ownershipDrift(
        homeDirectory.appending(path: ".config/skhd/skhdrc")
      )
    }
    let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    let inspection = KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: generation
    )
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
    guard
      transaction.operation == .teardownEntry,
      [.restorationFinalizing, .restorationFinalized].contains(transaction.phase)
    else {
      throw SetupOwnershipError.ownershipDrift(
        homeDirectory.appending(path: ".config/skhd/skhdrc")
      )
    }
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
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
    if transaction.phase != .restorationFinalized {
      try transactionStore.write(transaction.withPhase(.restorationFinalized))
    }
    try transactionStore.remove()
  }

  private func eligibility(
    _ preparation: KeybindingsPlanPreparation,
    adopt: String?
  ) throws -> (operation: KeybindingApplyOperation, lifecycle: KeybindingLifecycleAction) {
    switch preparation.provider.status {
    case .managed:
      return (.updateGeneration, .reload)
    case .installRequired where preparation.provider.ownership == "ordinary_directory":
      return (.installEntry, .restart)
    case .installRequired:
      throw KeybindingsApplyError.blocked(
        "clean apply requires an existing ordinary ~/.config/skhd directory"
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
      return (.adoptEntry, .restart)
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
      let publishesGeneration =
        preparation.generation.status == .missing
        || preparation.generation.inputDigest != composition.inputDigest
        || preparation.generation.renderedDigest != composition.renderedDigest
      try failure.validate(
        operation: eligibility.operation,
        lifecycle: eligibility.lifecycle,
        publishesGeneration: publishesGeneration,
        outcome: preparation.outcome
      )
    }
  #endif

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

    func validate(
      operation: KeybindingApplyOperation,
      lifecycle: KeybindingLifecycleAction,
      publishesGeneration: Bool,
      outcome: String
    ) throws {
      guard
        operation == .updateGeneration,
        lifecycle == .reload,
        publishesGeneration,
        outcome == "ready"
      else {
        throw KeybindingsApplyError.blocked(
          "the acceptance rollback checkpoint requires one managed generation update with reload"
        )
      }
    }

    func failAfterVerifiedReload() throws {
      let shouldFail = armed.withLock { armed in
        guard armed else { return false }
        armed = false
        return true
      }
      guard shouldFail else { return }
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

private struct KeybindingsApplySetupPayload: Decodable {
  let mutated: Bool
  let lifecycle: KeybindingLifecycleAction
  let message: String
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
