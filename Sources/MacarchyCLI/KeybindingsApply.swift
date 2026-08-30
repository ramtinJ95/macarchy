import Darwin
import Foundation
import Synchronization
import ThemeCore

enum KeybindingLifecycleAction: String, Encodable, Sendable {
  case none
  case reload
  case restart
}

struct KeybindingLifecycleController: Sendable {
  let preflight: @Sendable () throws -> Void
  let restart: @Sendable () throws -> Void
  let reload: @Sendable () throws -> Void
  let verifyProcess: @Sendable () throws -> Void

  init(
    preflight: @escaping @Sendable () throws -> Void = {},
    restart: @escaping @Sendable () throws -> Void,
    reload: @escaping @Sendable () throws -> Void,
    verifyProcess: @escaping @Sendable () throws -> Void
  ) {
    self.preflight = preflight
    self.restart = restart
    self.reload = reload
    self.verifyProcess = verifyProcess
  }

  static let live = KeybindingLifecycleController(
    preflight: {
      let executable = "/opt/homebrew/bin/skhd"
      guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw KeybindingsApplyError.lifecycle("supported skhd is unavailable at \(executable)")
      }
      try verifyCurrentUserProcess()
    },
    restart: { try runSkhd(["--restart-service"]) },
    reload: { try runSkhd(["--reload"]) },
    verifyProcess: { try verifyCurrentUserProcess() }
  )

  private static func verifyCurrentUserProcess() throws {
    var last = ProcessResult(terminationStatus: -1, output: "")
    for _ in 0..<20 {
      last = try ProcessRunner.live.run(
        ProcessRequest(
          executableURL: URL(filePath: "/usr/bin/pgrep"),
          arguments: ["-u", String(getuid()), "-x", "skhd"],
          timeout: 1
        )
      )
      if last.terminationStatus == 0 { return }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw KeybindingsApplyError.lifecycle(
      "skhd process did not become available (status \(last.terminationStatus))"
    )
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
  let planner: KeybindingsPlanCommandRunner
  let lifecycle: KeybindingLifecycleController
  let checkpoint: @Sendable (KeybindingApplyPhase) throws -> Void

  static let live = KeybindingsApplyCommandRunner(
    planner: .live,
    lifecycle: .live,
    checkpoint: { _ in }
  )

  func preview(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    do {
      guard isCanonicalStateRoot(stateRoot, homeDirectory: homeDirectory) else {
        throw KeybindingsApplyError.blocked(
          "keybinding apply requires the canonical per-user state root"
        )
      }
      let pending = try KeybindingApplyTransactionStore(stateRoot: stateRoot).read()
      if let pending {
        let lifecycleAction: KeybindingLifecycleAction =
          pending.phase == .activating
          ? (pending.operation == .installEntry ? .restart : .reload)
          : .none
        let report = KeybindingsApplyReport.success(
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
        ignoreTransaction: true
      )
      guard preparation.outcome != "blocked", preparation.composition != nil else {
        throw KeybindingsApplyError.blocked(
          preparation.blockingMessages.joined(separator: "; ")
        )
      }
      let eligibility = try eligibility(preparation)
      try lifecycle.preflight()
      if preparation.outcome == "no_change" {
        try lifecycle.verifyProcess()
        let report = KeybindingsApplyReport.success(
          outcome: "no_change",
          mutated: false,
          lifecycle: .none,
          generationID: preparation.generation.generationID,
          message: "Keybindings are already converged."
        )
        return (try report.render(json: json), true)
      }
      let report = KeybindingsApplyReport.success(
        outcome: "planned",
        mutated: false,
        lifecycle: eligibility.lifecycle,
        generationID: preparation.generation.generationID,
        message: "Would publish and activate managed keybindings."
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
        try applyLocked(
          resourcesRoot: resourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          evidence: evidence
        )
      }
      return (try result.render(json: json), result.succeeded)
    } catch {
      let outcome: String
      var observed = evidence.withLock { $0 }
      if error is KeybindingsRecoveryRequiredError {
        outcome = "recovery_required"
        observed.mutated = true
      } else if case .blocked = error as? KeybindingsApplyError {
        outcome = "blocked"
      } else if let applyError = error as? KeybindingsApplyError,
        case .rolledBack(_, let action) = applyError
      {
        outcome = "failed"
        observed.mutated = true
        observed.lifecycle = action
      } else {
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
              transaction.operation == .installEntry
              ? KeybindingLifecycleAction.restart
              : KeybindingLifecycleAction.reload
          }
        }
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
    let eligibility = try eligibility(preparation)
    do {
      try lifecycle.preflight()
    } catch {
      throw KeybindingsApplyError.blocked(String(describing: error))
    }
    if preparation.outcome == "no_change" {
      try lifecycle.verifyProcess()
      let observed = evidence.withLock { $0 }
      return .success(
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
      if needsGeneration {
        try checkpoint(.staging)
        let staged = try activator.stage(
          composition,
          generationID: selectedGenerationID
        )
        transaction = transaction.withPhase(.staged)
        try transactionStore.write(transaction)
        try checkpoint(.staged)
        try activator.select(staged)
      } else {
        try checkpoint(.staged)
      }
      transaction = transaction.withPhase(.currentSelected)
      try transactionStore.write(transaction)
      try checkpoint(.currentSelected)

      if operation == .installEntry {
        try KeybindingProviderTransaction(homeDirectory: homeDirectory).installEntry()
        transaction = transaction.withPhase(.entryInstalled)
        try transactionStore.write(transaction)
        try checkpoint(.entryInstalled)
      }

      transaction = transaction.withPhase(.activating)
      try transactionStore.write(transaction)
      try checkpoint(.activating)
      try perform(lifecycleAction)
      try lifecycle.verifyProcess()

      let verified = try planner.prepare(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        ignoreTransaction: true
      )
      guard verified.outcome == "no_change" else {
        throw KeybindingsApplyError.postcondition(
          "postcondition remained \(verified.outcome): \(verified.provider.message)"
        )
      }
      var retained = Set([selectedGenerationID])
      if let previous = transaction.previousGenerationID { retained.insert(previous) }
      try activator.retainGenerations(retained)
      try transactionStore.remove()
      return .success(
        outcome: "applied",
        mutated: true,
        lifecycle: lifecycleAction,
        generationID: selectedGenerationID,
        message: "Published and activated managed keybindings."
      )
    } catch {
      do {
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
    _ transaction: KeybindingApplyTransaction,
    stateRoot: URL,
    homeDirectory: URL,
    transactionStore: KeybindingApplyTransactionStore
  ) throws {
    let provider = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    if transaction.operation == .installEntry {
      try provider.removeInstalledEntry()
    }
    let activator = KeybindingGenerationActivator(stateRoot: stateRoot)
    try activator.restoreCurrent(generationID: transaction.previousGenerationID)
    if transaction.phase == .activating {
      try perform(transaction.operation == .installEntry ? .restart : .reload)
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
    let providerInspection = KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: restored
    )
    if transaction.operation == .installEntry {
      guard providerInspection.status == .installRequired,
        providerInspection.ownership == "ordinary_directory"
      else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore the absent provider entry"
        )
      }
    } else {
      guard providerInspection.status == .managed else {
        throw KeybindingsApplyError.postcondition(
          "rollback did not restore managed provider ownership"
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

  private func eligibility(
    _ preparation: KeybindingsPlanPreparation
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
      throw KeybindingsApplyError.blocked(
        "existing skhd configuration requires the later explicit adoption path"
      )
    case .blocked:
      throw KeybindingsApplyError.blocked(preparation.provider.message)
    }
  }

  private func isCanonicalStateRoot(_ stateRoot: URL, homeDirectory: URL) -> Bool {
    stateRoot.standardizedFileURL
      == homeDirectory.appending(
        path: ".config/macarchy",
        directoryHint: .isDirectory
      ).standardizedFileURL
  }
}

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

  static func success(
    outcome: String,
    mutated: Bool,
    lifecycle: KeybindingLifecycleAction,
    generationID: String?,
    message: String
  ) -> Self {
    Self(
      outcome: outcome,
      mutated: mutated,
      lifecycle: lifecycle,
      generationID: generationID,
      message: message
    )
  }

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
