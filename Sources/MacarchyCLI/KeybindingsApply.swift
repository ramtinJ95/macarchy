import Darwin
import Foundation
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
      let pending = try KeybindingApplyTransactionStore(stateRoot: stateRoot).read()
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
      if preparation.outcome == "no_change", pending == nil {
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
      let recovery =
        pending.map {
          " Would first recover \($0.operation.rawValue) phase \($0.phase.rawValue)."
        } ?? ""
      let report = KeybindingsApplyReport.success(
        outcome: "planned",
        mutated: false,
        lifecycle: eligibility.lifecycle,
        generationID: preparation.generation.generationID,
        message: "Would publish and activate managed keybindings.\(recovery)"
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
    let canonicalStateRoot = homeDirectory.appending(
      path: ".config/macarchy",
      directoryHint: .isDirectory
    ).standardizedFileURL
    guard stateRoot.standardizedFileURL == canonicalStateRoot else {
      let report = KeybindingsApplyReport.failure(
        outcome: "blocked",
        message: "keybinding apply requires the canonical per-user state root"
      )
      return (try report.render(json: json), false)
    }

    do {
      let result = try ActivationLock(root: stateRoot).withLock {
        try applyLocked(
          resourcesRoot: resourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory
        )
      }
      return (try result.render(json: json), result.succeeded)
    } catch {
      let outcome: String
      let mutated: Bool
      let lifecycleAction: KeybindingLifecycleAction
      if error is KeybindingsRecoveryRequiredError {
        outcome = "recovery_required"
        mutated = true
        lifecycleAction = .none
      } else if case .blocked = error as? KeybindingsApplyError {
        outcome = "blocked"
        mutated = false
        lifecycleAction = .none
      } else if let applyError = error as? KeybindingsApplyError,
        case .rolledBack(_, let action) = applyError
      {
        outcome = "failed"
        mutated = true
        lifecycleAction = action
      } else {
        outcome = "failed"
        mutated = false
        lifecycleAction = .none
      }
      let report = KeybindingsApplyReport.failure(
        outcome: outcome,
        mutated: mutated,
        lifecycle: lifecycleAction,
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
    homeDirectory: URL
  ) throws -> KeybindingsApplyReport {
    let transactionStore = KeybindingApplyTransactionStore(stateRoot: stateRoot)
    do {
      try KeybindingGenerationActivator(stateRoot: stateRoot).recoverResidue()
      if let transaction = try transactionStore.read() {
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
      return .success(
        outcome: "no_change",
        mutated: false,
        lifecycle: .none,
        generationID: preparation.generation.generationID,
        message: "Keybindings are already converged."
      )
    }

    let operation = eligibility.operation
    let lifecycleAction = eligibility.lifecycle

    let activator = KeybindingGenerationActivator(stateRoot: stateRoot)
    var staged: StagedKeybindingGeneration?
    let needsGeneration =
      preparation.generation.status == .missing
      || preparation.generation.inputDigest != composition.inputDigest
      || preparation.generation.renderedDigest != composition.renderedDigest
    if needsGeneration {
      staged = try activator.stage(composition)
    }
    guard
      let selectedGenerationID = staged?.manifest.generationID
        ?? preparation.generation.generationID
    else {
      throw KeybindingsApplyError.blocked("no valid generation is available for provider apply")
    }
    var transaction = KeybindingApplyTransaction(
      operation: operation,
      phase: .staged,
      generationID: selectedGenerationID,
      previousGenerationID: preparation.generation.generationID,
      generationCreated: staged != nil
    )
    do {
      try transactionStore.write(transaction)
      try checkpoint(.staged)
      if let staged { try activator.select(staged) }
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
        lifecycleAction
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
