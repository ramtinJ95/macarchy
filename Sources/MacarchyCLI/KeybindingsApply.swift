import Foundation
import ThemeCore

enum KeybindingLifecycleAction: String, Encodable, Sendable {
  case none
  case reload
  case restart
}

struct KeybindingLifecycleController: Sendable {
  let restart: @Sendable () throws -> Void
  let reload: @Sendable () throws -> Void
  let verifyProcess: @Sendable () throws -> Void

  static let live = KeybindingLifecycleController(
    restart: { try runSkhd(["--restart-service"]) },
    reload: { try runSkhd(["--reload"]) },
    verifyProcess: {
      var last = ProcessResult(terminationStatus: -1, output: "")
      for _ in 0..<20 {
        last = try ProcessRunner.live.run(
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/pgrep"),
            arguments: ["-x", "skhd"],
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
  )

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
      if error is KeybindingsRecoveryRequiredError {
        outcome = "recovery_required"
      } else if case .blocked = error as? KeybindingsApplyError {
        outcome = "blocked"
      } else {
        outcome = "failed"
      }
      let report = KeybindingsApplyReport.failure(
        outcome: outcome,
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
    if let transaction = try transactionStore.read() {
      try rollback(
        transaction,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        transactionStore: transactionStore
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
      throw KeybindingsApplyError.blocked(preparation.provider.message)
    }
    if preparation.outcome == "no_change" {
      return .success(
        outcome: "no_change",
        mutated: false,
        lifecycle: .none,
        generationID: preparation.generation.generationID,
        message: "Keybindings are already converged."
      )
    }

    let operation: KeybindingApplyOperation
    let lifecycleAction: KeybindingLifecycleAction
    switch preparation.provider.status {
    case .managed:
      operation = .updateGeneration
      lifecycleAction = .reload
    case .installRequired where preparation.provider.ownership == "ordinary_directory":
      operation = .installEntry
      lifecycleAction = .restart
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
      throw KeybindingsApplyError.rolledBack(String(describing: error))
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

  static func failure(outcome: String, message: String) -> Self {
    Self(
      outcome: outcome,
      mutated: outcome != "blocked",
      lifecycle: .none,
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
  case rolledBack(String)

  var description: String {
    switch self {
    case .blocked(let reason):
      "keybinding apply is blocked: \(reason)"
    case .lifecycle(let reason):
      "keybinding lifecycle failed: \(reason)"
    case .postcondition(let reason):
      "keybinding postcondition failed: \(reason)"
    case .rolledBack(let reason):
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
