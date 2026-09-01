import Darwin
import Foundation
import ThemeCore

struct DesktopApplyCommandRunner: Sendable {
  let lifecycle: YabaiLifecycleController
  let faultInjector: @Sendable (YabaiTransactionCheckpoint) throws -> Void

  static let live = DesktopApplyCommandRunner(lifecycle: .live)

  init(
    lifecycle: YabaiLifecycleController,
    faultInjector: @escaping @Sendable (YabaiTransactionCheckpoint) throws -> Void = { _ in }
  ) {
    self.lifecycle = lifecycle
    self.faultInjector = faultInjector
  }

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let desired: DesktopDesiredYabaiState
    do {
      desired = try DesktopDesiredYabaiState.load(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired
      )
    } catch {
      return try result(
        outcome: "blocked",
        mutated: false,
        generationID: nil,
        lifecycle: "none",
        message: String(describing: error),
        json: json,
        succeeded: false
      )
    }
    do {
      let result = try ActivationLock(root: stateRoot).withLock {
        if let composition = desired.composition {
          try applyLocked(
            composition: composition,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            adopt: adopt
          )
        } else {
          try DesktopTeardownCommandRunner(
            lifecycle: lifecycle,
            faultInjector: faultInjector
          ).teardownLocked(
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            dryRun: false
          )
        }
      }
      return try self.result(
        outcome: result.changed ? "applied" : "no_change",
        mutated: result.changed,
        generationID: result.generationID,
        lifecycle: result.lifecycle,
        message: result.message,
        json: json,
        succeeded: true
      )
    } catch is YabaiInterruptionError {
      throw YabaiInterruptionError.injected
    } catch {
      return try result(
        outcome: "failed",
        mutated: YabaiTransactionStore(stateRoot: stateRoot).exists,
        generationID: nil,
        lifecycle: "failed",
        message: String(describing: error),
        json: json,
        succeeded: false
      )
    }
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
    generationID: String?,
    lifecycle: String,
    message: String,
    json: Bool,
    succeeded: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report = DesktopMutationReport(
      operation: "desktop_apply",
      outcome: outcome,
      mutated: mutated,
      generationID: generationID,
      lifecycle: lifecycle,
      message: message
    )
    return (try report.render(json: json), succeeded)
  }
}

struct DesktopTeardownCommandRunner: Sendable {
  let lifecycle: YabaiLifecycleController
  let faultInjector: @Sendable (YabaiTransactionCheckpoint) throws -> Void

  static let live = DesktopTeardownCommandRunner(lifecycle: .live)

  init(
    lifecycle: YabaiLifecycleController,
    faultInjector: @escaping @Sendable (YabaiTransactionCheckpoint) throws -> Void = { _ in }
  ) {
    self.lifecycle = lifecycle
    self.faultInjector = faultInjector
  }

  func execute(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    do {
      let outcome = try ActivationLock(root: stateRoot).withLock {
        try teardownLocked(
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          dryRun: dryRun
        )
      }
      let report = DesktopMutationReport(
        operation: "desktop_teardown",
        outcome: outcome.changed ? (dryRun ? "planned" : "removed") : "no_change",
        mutated: outcome.changed && !dryRun,
        generationID: outcome.generationID,
        lifecycle: outcome.lifecycle,
        message: outcome.message
      )
      return (try report.render(json: json), true)
    } catch is YabaiInterruptionError {
      throw YabaiInterruptionError.injected
    } catch {
      let report = DesktopMutationReport(
        operation: "desktop_teardown",
        outcome: "failed",
        mutated: YabaiTransactionStore(stateRoot: stateRoot).exists,
        generationID: nil,
        lifecycle: "failed",
        message: String(describing: error)
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

struct DesktopDesiredYabaiState: Sendable {
  let profile: PortableProfile
  let composition: YabaiComposition?

  static func load(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool
  ) throws -> Self {
    let profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
    let composition: YabaiComposition? =
      if profile.desktop.provider == .yabaiSkhd {
        try YabaiConfigurationComposer().compose(
          defaultsURL: resourcesRoot.appending(path: "yabai/defaults.toml"),
          profile: profile
        )
      } else {
        nil
      }
    return Self(profile: profile, composition: composition)
  }
}

private struct ApplyResult {
  let changed: Bool
  let generationID: String?
  let lifecycle: String
  let message: String
}

private struct DesktopMutationReport: Encodable {
  let schemaVersion = 1
  let operation: String
  let outcome: String
  let mutated: Bool
  let generationID: String?
  let lifecycle: String
  let message: String

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    return [
      "Macarchy \(operation.replacingOccurrences(of: "_", with: " ")) [\(outcome)]:",
      "- generation: \(generationID ?? "none")",
      "- lifecycle: \(lifecycle)",
      "- mutated: \(mutated ? "yes" : "no")",
      "- \(message)",
    ].joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, mutated
    case generationID = "generation_id"
    case lifecycle, message
  }
}
