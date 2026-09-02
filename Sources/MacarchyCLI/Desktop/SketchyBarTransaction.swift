import Darwin
import Foundation
import ThemeCore

enum SketchyBarTransactionOperation: String, Codable, Sendable {
  case apply
  case teardown
}

enum SketchyBarTransactionPhase: String, Codable, Sendable {
  case prepared
  case generationPublished = "generation_published"
  case generationSelected = "generation_selected"
  case providerChanging = "provider_changing"
  case providerChanged = "provider_changed"
  case serviceChanging = "service_changing"
  case serviceChanged = "service_changed"
}

struct SketchyBarTransaction: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let operation: SketchyBarTransactionOperation
  var phase: SketchyBarTransactionPhase
  let generationID: String
  let previousGenerationID: String?
  let generationCreated: Bool
  let ownership: SketchyBarOwnershipRecord
  let previousOwnership: SketchyBarOwnershipRecord?
  let previousLifecycle: SketchyBarLifecycleEvidence?
  let serviceWasRunning: Bool
  let teardownGenerationIDs: [String]?

  init(
    operation: SketchyBarTransactionOperation,
    phase: SketchyBarTransactionPhase,
    generationID: String,
    previousGenerationID: String?,
    generationCreated: Bool,
    ownership: SketchyBarOwnershipRecord,
    previousOwnership: SketchyBarOwnershipRecord?,
    previousLifecycle: SketchyBarLifecycleEvidence?,
    serviceWasRunning: Bool,
    teardownGenerationIDs: [String]? = nil
  ) {
    schemaVersion = 3
    self.operation = operation
    self.phase = phase
    self.generationID = generationID
    self.previousGenerationID = previousGenerationID
    self.generationCreated = generationCreated
    self.ownership = ownership
    self.previousOwnership = previousOwnership
    self.previousLifecycle = previousLifecycle
    self.serviceWasRunning = serviceWasRunning
    self.teardownGenerationIDs = teardownGenerationIDs
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, phase
    case generationID = "generation_id"
    case previousGenerationID = "previous_generation_id"
    case generationCreated = "generation_created"
    case ownership
    case previousOwnership = "previous_ownership"
    case previousLifecycle = "previous_lifecycle"
    case serviceWasRunning = "service_was_running"
    case teardownGenerationIDs = "teardown_generation_ids"
  }
}

struct SketchyBarTransactionStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "desktop/sketchybar", directoryHint: .isDirectory)
  }

  private var file: URL { directory.appending(path: "transaction.json") }

  var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

  func read() throws -> SketchyBarTransaction? {
    guard exists else { return nil }
    let data = try BoundedRegularFile.read(at: file, maximumSize: 65_536).data
    let transaction = try JSONDecoder().decode(SketchyBarTransaction.self, from: data)
    try validate(transaction)
    return transaction
  }

  func write(_ transaction: SketchyBarTransaction) throws {
    try validate(transaction)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(transaction).write(to: file, options: .atomic)
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }

  private func validate(_ transaction: SketchyBarTransaction) throws {
    let generationRelationshipIsValid =
      transaction.generationCreated
      ? transaction.generationID != transaction.previousGenerationID
      : transaction.generationID == transaction.previousGenerationID
    let previousOwnershipIsValid =
      transaction.previousOwnership.map {
        SketchyBarOwnershipStore.isValid($0, stateRoot: stateRoot)
          && $0.generationID == transaction.previousGenerationID
      } ?? true
    let previousLifecycleIsValid =
      transaction.previousLifecycle.map {
        $0.isValid
          && $0.generationID == transaction.previousGenerationID
          && transaction.previousOwnership != nil
      } ?? true
    let operationIsValid =
      switch transaction.operation {
      case .apply:
        transaction.teardownGenerationIDs == nil
      case .teardown:
        transaction.teardownGenerationIDs.map {
          !$0.isEmpty
            && $0 == $0.sorted()
            && Set($0).count == $0.count
            && $0.contains(transaction.generationID)
            && $0.allSatisfy(SketchyBarGenerationInspector.isGenerationID)
        } == true
          && !transaction.generationCreated
          && transaction.generationID == transaction.previousGenerationID
          && transaction.previousOwnership == transaction.ownership
          && [.providerChanging, .providerChanged, .serviceChanging, .serviceChanged]
            .contains(transaction.phase)
      }
    guard
      transaction.schemaVersion == 3,
      SketchyBarGenerationInspector.isGenerationID(transaction.generationID),
      transaction.previousGenerationID.map(SketchyBarGenerationInspector.isGenerationID) ?? true,
      SketchyBarOwnershipStore.isValid(transaction.ownership, stateRoot: stateRoot),
      transaction.ownership.generationID == transaction.generationID,
      generationRelationshipIsValid,
      previousOwnershipIsValid,
      previousLifecycleIsValid,
      operationIsValid
    else {
      throw SketchyBarDesktopError.invalidState("SketchyBar transaction record is invalid")
    }
  }
}

enum SketchyBarTransactionCheckpoint: Sendable {
  case generationPublished
  case generationSelected
  case originalRetained
  case configurationDirectoryCreated
  case providerChanged
  case providerRestored
  case serviceChanged
  case generationDeselected
}

enum SketchyBarInterruptionError: Error, Sendable {
  case injected
}

struct SketchyBarFilesystemConvergenceResult: Equatable, Sendable {
  let generationID: String?
  let changed: Bool
}

struct SketchyBarProviderTransaction: Sendable {
  let homeDirectory: URL
  let stateRoot: URL
  let lifecycle: SketchyBarLifecycleController
  let coreRuntime: SketchyBarCoreRuntimeController
  let faultInjector: @Sendable (SketchyBarTransactionCheckpoint) throws -> Void

  init(
    homeDirectory: URL,
    stateRoot: URL,
    lifecycle: SketchyBarLifecycleController,
    coreRuntime: SketchyBarCoreRuntimeController? = nil,
    faultInjector: @escaping @Sendable (SketchyBarTransactionCheckpoint) throws -> Void = { _ in }
  ) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.stateRoot = stateRoot.standardizedFileURL
    self.lifecycle = lifecycle
    self.coreRuntime = coreRuntime ?? .live(stateRoot: stateRoot)
    self.faultInjector = faultInjector
  }

  // The aggregate desktop mutation owns ActivationLock across every provider transaction.
  func convergeLocked(
    composition: SketchyBarComposition,
    adoptionEvidenceDigest: String?,
    deferFinalization: Bool = false
  ) throws -> SketchyBarFilesystemConvergenceResult {
    let transactionStore = SketchyBarTransactionStore(stateRoot: stateRoot)
    _ = try recoverPendingLocked()

    let generationInspector = SketchyBarGenerationInspector(stateRoot: stateRoot)
    let previousGeneration = generationInspector.inspect()
    if previousGeneration.status == .invalid {
      throw SketchyBarDesktopError.invalidState(previousGeneration.message)
    }
    let ownershipStore = SketchyBarOwnershipStore(stateRoot: stateRoot)
    let previousOwnership = try ownershipStore.read()
    let providerInspector = SketchyBarProviderPlanInspector()
    let provider = providerInspector.inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      enabled: true,
      generation: previousGeneration
    )
    guard [.managed, .installRequired, .adoptionRequired].contains(provider.status) else {
      throw SketchyBarDesktopError.invalidState(provider.message)
    }

    let original: SketchyBarAdoptionEvidence
    let retainedOriginalPath: String?
    let createdConfigurationDirectory: Bool
    if let previousOwnership {
      original = previousOwnership.original
      retainedOriginalPath = previousOwnership.retainedOriginalPath
      createdConfigurationDirectory = previousOwnership.createdConfigurationDirectory
    } else {
      original = try providerInspector.captureUnowned(
        directory: configurationDirectory,
        entry: entry
      )
      if provider.status == .adoptionRequired {
        guard adoptionEvidenceDigest == original.digest else {
          throw SketchyBarDesktopError.invalidState(
            "adoption requires --sketchybar-adopt \(original.digest) from the current reviewed plan"
          )
        }
      }
      retainedOriginalPath = original.kind == .absent ? nil : retainedOriginalURL().path
      var metadata = stat()
      createdConfigurationDirectory =
        original.kind == .absent && lstat(configurationDirectory.path, &metadata) != 0
    }

    let generationAgrees =
      previousGeneration.status == .current
      && previousGeneration.manifest?.inputDigest == composition.inputDigest
      && previousGeneration.manifest?.renderedDigest == composition.renderedDigest
    let generationID =
      generationAgrees
      ? previousGeneration.generationID!
      : "s-\(UUID().uuidString.lowercased())"
    let serviceWasRunning = try lifecycle.preflight()
    let previousLifecycle = try SketchyBarLifecycleEvidenceStore(stateRoot: stateRoot).read()
    if serviceWasRunning, previousOwnership == nil, original.kind == .absent {
      throw SketchyBarDesktopError.lifecycle(
        "cannot adopt a running SketchyBar service without a restorable original sketchybarrc"
      )
    }
    let ownership = SketchyBarOwnershipRecord(
      generationID: generationID,
      managedTarget: SketchyBarProviderPlanInspector.managedTarget(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ),
      original: original,
      retainedOriginalPath: retainedOriginalPath,
      createdConfigurationDirectory: createdConfigurationDirectory,
      priorServiceRunning: previousOwnership?.priorServiceRunning ?? serviceWasRunning
    )
    let currentRuntime = serviceWasRunning ? try lifecycle.inspect() : nil
    let currentCoreRuntime = serviceWasRunning ? coreRuntime.inspect(composition) : nil
    if generationAgrees,
      previousOwnership == ownership,
      previousLifecycle?.generationID == generationID,
      previousLifecycle?.runtime == currentRuntime,
      previousLifecycle?.coreRuntime == currentCoreRuntime,
      let currentCoreRuntime,
      Self.isSuccessfulCoreRuntime(currentCoreRuntime, composition: composition),
      serviceWasRunning
    {
      return SketchyBarFilesystemConvergenceResult(
        generationID: generationID,
        changed: false
      )
    }

    var transaction = SketchyBarTransaction(
      operation: .apply,
      phase: .prepared,
      generationID: generationID,
      previousGenerationID: previousGeneration.generationID,
      generationCreated: !generationAgrees,
      ownership: ownership,
      previousOwnership: previousOwnership,
      previousLifecycle: previousLifecycle,
      serviceWasRunning: serviceWasRunning
    )
    try transactionStore.write(transaction)
    let activator = SketchyBarGenerationActivator(stateRoot: stateRoot)
    do {
      if !serviceWasRunning, try lifecycle.preflight() {
        throw SketchyBarDesktopError.lifecycle(
          "SketchyBar started after lifecycle preflight; review the current service state"
        )
      }
      if !generationAgrees {
        try activator.publish(composition, generationID: generationID)
        transaction.phase = .generationPublished
        try transactionStore.write(transaction)
        try faultInjector(.generationPublished)
        try activator.select(generationID)
      }
      transaction.phase = .generationSelected
      try transactionStore.write(transaction)
      try faultInjector(.generationSelected)

      if previousOwnership == nil {
        transaction.phase = .providerChanging
        try transactionStore.write(transaction)
        let recaptured = try providerInspector.captureUnowned(
          directory: configurationDirectory,
          entry: entry
        )
        guard recaptured == original else {
          throw SketchyBarDesktopError.invalidState(
            "SketchyBar provider changed after the approved adoption preview"
          )
        }
        try installManaged(ownership)
      }
      try ownershipStore.write(ownership)
      transaction.phase = .providerChanged
      try transactionStore.write(transaction)
      try faultInjector(.providerChanged)

      transaction.phase = .serviceChanging
      try transactionStore.write(transaction)
      let runtime = try lifecycle.activate(
        wasRunning: serviceWasRunning,
        configurationURL: entry
      )
      guard runtime.status == .running else {
        throw SketchyBarDesktopError.lifecycle(runtime.message)
      }
      let verifiedCoreRuntime = coreRuntime.settle(composition)
      guard Self.isSuccessfulCoreRuntime(verifiedCoreRuntime, composition: composition) else {
        throw SketchyBarDesktopError.lifecycle(verifiedCoreRuntime.message)
      }
      transaction.phase = .serviceChanged
      try transactionStore.write(transaction)
      try faultInjector(.serviceChanged)
      try SketchyBarLifecycleEvidenceStore(stateRoot: stateRoot).write(
        SketchyBarLifecycleEvidence(
          generationID: generationID,
          runtime: runtime,
          coreRuntime: verifiedCoreRuntime
        )
      )
      if !deferFinalization {
        try transactionStore.remove()
      }
      return SketchyBarFilesystemConvergenceResult(generationID: generationID, changed: true)
    } catch is SketchyBarInterruptionError {
      throw SketchyBarInterruptionError.injected
    } catch {
      let convergenceError = error
      if let persisted = try transactionStore.read() {
        do {
          try recoverApply(persisted)
        } catch {
          throw SketchyBarDesktopError.invalidState(
            "SketchyBar convergence failed: \(convergenceError); rollback requires recovery: \(error)"
          )
        }
      }
      throw convergenceError
    }
  }

  private static func isSuccessfulCoreRuntime(
    _ inspection: SketchyBarCoreRuntimeInspection,
    composition: SketchyBarComposition
  ) -> Bool {
    inspection.isValidEvidence
      && (inspection.status == .converged
        || (inspection.status == .partial && composition.hookURL != nil))
  }

  func recoverPendingLocked() throws -> SketchyBarTransaction? {
    let store = SketchyBarTransactionStore(stateRoot: stateRoot)
    guard let pending = try store.read() else { return nil }
    switch pending.operation {
    case .apply: try recoverApply(pending)
    case .teardown: try completeTeardown(pending)
    }
    return pending
  }

  func recoverApply(_ transaction: SketchyBarTransaction) throws {
    guard transaction.operation == .apply else {
      throw SketchyBarDesktopError.invalidState(
        "cannot roll back a SketchyBar teardown as an apply"
      )
    }
    try validateContext(transaction)
    let activator = SketchyBarGenerationActivator(stateRoot: stateRoot)
    try activator.removeCurrentSelectionResidue(transaction.generationID)
    if let previousGenerationID = transaction.previousGenerationID,
      previousGenerationID != transaction.generationID
    {
      try activator.removeCurrentSelectionResidue(previousGenerationID)
    }
    try authenticateCurrentForRecovery(transaction)
    if let previousOwnership = transaction.previousOwnership {
      guard isManagedEntry(target: previousOwnership.managedTarget) else {
        throw SketchyBarDesktopError.invalidState(
          "managed SketchyBar entry drifted during interrupted convergence"
        )
      }
      try Self.authenticateRetained(previousOwnership)
    } else {
      let managed = isManagedEntry(target: transaction.ownership.managedTarget)
      let retained = transaction.ownership.retainedOriginalPath.map(pathExistsNoFollow) ?? false
      let createdDirectoryRemains =
        transaction.ownership.createdConfigurationDirectory
        && pathExistsNoFollow(configurationDirectory.path)
      if managed || retained || createdDirectoryRemains {
        try restoreOriginal(transaction.ownership)
      } else {
        let publicEvidence = try? SketchyBarProviderPlanInspector().captureUnowned(
          directory: configurationDirectory,
          entry: entry
        )
        guard
          publicEvidence == transaction.ownership.original
            || originalInodeIsPublic(transaction.ownership.original)
        else {
          throw SketchyBarDesktopError.invalidState(
            "interrupted SketchyBar provider state is ambiguous"
          )
        }
      }
    }
    try activator.restoreCurrent(transaction.previousGenerationID)
    let ownershipStore = SketchyBarOwnershipStore(stateRoot: stateRoot)
    if let previous = transaction.previousOwnership {
      try ownershipStore.write(previous)
    } else {
      try ownershipStore.remove()
    }
    if transaction.generationCreated {
      try activator.removeTransactionResidue(transaction.generationID)
    }
    if transaction.phase == .serviceChanging || transaction.phase == .serviceChanged {
      try lifecycle.restore(
        wasRunning: transaction.serviceWasRunning,
        configurationURL: entry
      )
    }
    let lifecycleStore = SketchyBarLifecycleEvidenceStore(stateRoot: stateRoot)
    if let previous = transaction.previousLifecycle, transaction.serviceWasRunning {
      guard coreRuntime.settleRestored(previous.coreRuntime) else {
        throw SketchyBarDesktopError.lifecycle(
          "restored SketchyBar did not return to its previous observable runtime state"
        )
      }
      try lifecycleStore.write(previous)
    } else {
      try lifecycleStore.remove()
    }
    try SketchyBarTransactionStore(stateRoot: stateRoot).remove()
  }

  func teardownLocked(
    dryRun: Bool,
    deferFinalization: Bool = false
  ) throws -> SketchyBarFilesystemConvergenceResult {
    let transactionStore = SketchyBarTransactionStore(stateRoot: stateRoot)
    var recoveredGenerationID: String?
    if let pending = try transactionStore.read() {
      if dryRun {
        return SketchyBarFilesystemConvergenceResult(
          generationID: pending.generationID,
          changed: true
        )
      }
      switch pending.operation {
      case .apply: try recoverApply(pending)
      case .teardown: try completeTeardown(pending)
      }
      recoveredGenerationID = pending.generationID
    }

    guard let ownership = try SketchyBarOwnershipStore(stateRoot: stateRoot).read() else {
      return SketchyBarFilesystemConvergenceResult(
        generationID: recoveredGenerationID,
        changed: recoveredGenerationID != nil
      )
    }
    let provider = SketchyBarProviderPlanInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      enabled: true,
      generation: SketchyBarGenerationInspector(stateRoot: stateRoot).inspect()
    )
    guard provider.status == .managed else {
      throw SketchyBarDesktopError.invalidState(provider.message)
    }
    let activator = SketchyBarGenerationActivator(stateRoot: stateRoot)
    let teardownGenerationIDs = try activator.validatedGenerationIDs()
    guard teardownGenerationIDs.contains(ownership.generationID) else {
      throw SketchyBarDesktopError.invalidState(
        "selected SketchyBar generation is absent from the owned inventory"
      )
    }
    if dryRun {
      return SketchyBarFilesystemConvergenceResult(
        generationID: ownership.generationID,
        changed: true
      )
    }

    let serviceWasRunning = try lifecycle.preflight()
    var transaction = SketchyBarTransaction(
      operation: .teardown,
      phase: .providerChanging,
      generationID: ownership.generationID,
      previousGenerationID: ownership.generationID,
      generationCreated: false,
      ownership: ownership,
      previousOwnership: ownership,
      previousLifecycle: try SketchyBarLifecycleEvidenceStore(stateRoot: stateRoot).read(),
      serviceWasRunning: serviceWasRunning,
      teardownGenerationIDs: teardownGenerationIDs
    )
    try transactionStore.write(transaction)
    try restoreOriginal(ownership)
    transaction.phase = .providerChanged
    try transactionStore.write(transaction)
    try faultInjector(.providerRestored)
    transaction.phase = .serviceChanging
    try transactionStore.write(transaction)
    try completeTeardown(transaction, deferFinalization: deferFinalization)
    return SketchyBarFilesystemConvergenceResult(
      generationID: ownership.generationID,
      changed: true
    )
  }

  func completeTeardown(
    _ transaction: SketchyBarTransaction,
    deferFinalization: Bool = false
  ) throws {
    guard transaction.operation == .teardown else {
      throw SketchyBarDesktopError.invalidState(
        "cannot complete a SketchyBar apply as a teardown"
      )
    }
    try validateContext(transaction)
    try authenticateCurrentForRecovery(transaction)

    let managed = isManagedEntry(target: transaction.ownership.managedTarget)
    let retained = transaction.ownership.retainedOriginalPath.map(pathExistsNoFollow) ?? false
    let createdDirectoryRemains =
      transaction.ownership.createdConfigurationDirectory
      && pathExistsNoFollow(configurationDirectory.path)
    if managed || retained || createdDirectoryRemains {
      try restoreOriginal(transaction.ownership)
    }
    let restored = try SketchyBarProviderPlanInspector().captureUnowned(
      directory: configurationDirectory,
      entry: entry
    )
    guard restored == transaction.ownership.original else {
      throw SketchyBarDesktopError.invalidState(
        "SketchyBar teardown restoration does not match approved evidence"
      )
    }

    try lifecycle.restore(
      wasRunning: transaction.ownership.priorServiceRunning,
      configurationURL: entry
    )
    var completing = transaction
    completing.phase = .serviceChanged
    try SketchyBarTransactionStore(stateRoot: stateRoot).write(completing)
    if deferFinalization { return }
    try SketchyBarLifecycleEvidenceStore(stateRoot: stateRoot).remove()
    try SketchyBarOwnershipStore(stateRoot: stateRoot).remove()
    let activator = SketchyBarGenerationActivator(stateRoot: stateRoot)
    try activator.restoreCurrent(nil)
    try faultInjector(.generationDeselected)
    try activator.removeGenerations(transaction.teardownGenerationIDs!)
    try SketchyBarTransactionStore(stateRoot: stateRoot).remove()
  }

  func rollbackDeferredLocked() throws {
    let store = SketchyBarTransactionStore(stateRoot: stateRoot)
    guard let transaction = try store.read() else { return }
    if transaction.operation == .apply {
      try recoverApply(transaction)
      return
    }
    if !isManagedEntry(target: transaction.ownership.managedTarget) {
      let publicEvidence = try SketchyBarProviderPlanInspector().captureUnowned(
        directory: configurationDirectory,
        entry: entry
      )
      guard publicEvidence == transaction.ownership.original else {
        throw SketchyBarDesktopError.invalidState(
          "deferred SketchyBar teardown cannot restore managed ownership"
        )
      }
      try installManaged(transaction.ownership)
    }
    try lifecycle.restore(
      wasRunning: transaction.serviceWasRunning,
      configurationURL: entry
    )
    if let previous = transaction.previousLifecycle {
      guard coreRuntime.settleRestored(previous.coreRuntime) else {
        throw SketchyBarDesktopError.lifecycle(
          "restored SketchyBar did not return to its previous observable runtime state"
        )
      }
      try SketchyBarLifecycleEvidenceStore(stateRoot: stateRoot).write(previous)
    }
    try store.remove()
  }

  func commitDeferredLocked() throws {
    let store = SketchyBarTransactionStore(stateRoot: stateRoot)
    guard let transaction = try store.read() else { return }
    switch transaction.operation {
    case .apply:
      guard transaction.phase == .serviceChanged else {
        throw SketchyBarDesktopError.invalidState(
          "deferred SketchyBar apply is not ready to commit"
        )
      }
      try store.remove()
    case .teardown:
      try completeTeardown(transaction)
    }
  }

  private func authenticateCurrentForRecovery(_ transaction: SketchyBarTransaction) throws {
    let current = SketchyBarGenerationInspector(stateRoot: stateRoot).inspect()
    switch current.status {
    case .missing:
      guard
        transaction.previousGenerationID == nil
          || (transaction.operation == .teardown && transaction.phase == .serviceChanged)
      else {
        throw SketchyBarDesktopError.invalidState(
          "SketchyBar current pointer disappeared during interrupted convergence"
        )
      }
    case .current:
      guard
        current.generationID == transaction.previousGenerationID
          || current.generationID == transaction.generationID
      else {
        throw SketchyBarDesktopError.invalidState(
          "SketchyBar current pointer changed during interrupted convergence"
        )
      }
    case .invalid:
      throw SketchyBarDesktopError.invalidState(current.message)
    }
  }

  private func validateContext(_ transaction: SketchyBarTransaction) throws {
    let expectedTarget = SketchyBarProviderPlanInspector.managedTarget(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    for ownership in [transaction.ownership, transaction.previousOwnership].compactMap({ $0 }) {
      let expectedPublicPath =
        ownership.original.kind == .directorySymlink
        ? configurationDirectory.path : entry.path
      guard
        ownership.managedTarget == expectedTarget,
        ownership.original.publicPath == expectedPublicPath
      else {
        throw SketchyBarDesktopError.invalidState(
          "SketchyBar transaction ownership does not match this provider"
        )
      }
    }
  }

  func retainedOriginalURL(nonce: UUID = UUID()) -> URL {
    stateRoot.appending(
      path: "desktop/sketchybar/retained-\(nonce.uuidString.lowercased())"
    )
  }

  func installManaged(_ ownership: SketchyBarOwnershipRecord) throws {
    if let retainedOriginalPath = ownership.retainedOriginalPath {
      guard !pathExistsNoFollow(retainedOriginalPath) else {
        throw SketchyBarDesktopError.invalidState(
          "retained SketchyBar original already exists"
        )
      }
      guard rename(ownership.original.publicPath, retainedOriginalPath) == 0 else {
        throw SketchyBarDesktopError.system(
          "retain original SketchyBar entry",
          URL(filePath: ownership.original.publicPath),
          errno
        )
      }
      do {
        try faultInjector(.originalRetained)
        try Self.authenticateRetained(ownership)
      } catch is SketchyBarInterruptionError {
        throw SketchyBarInterruptionError.injected
      } catch {
        let authenticationError = error
        if !pathExistsNoFollow(ownership.original.publicPath) {
          guard rename(retainedOriginalPath, ownership.original.publicPath) == 0 else {
            throw SketchyBarDesktopError.invalidState(
              "retained SketchyBar authentication failed and immediate restoration also failed: \(authenticationError)"
            )
          }
        }
        throw authenticationError
      }
    }

    do {
      if ownership.original.kind == .directorySymlink
        || ownership.createdConfigurationDirectory
      {
        try FileManager.default.createDirectory(
          at: configurationDirectory,
          withIntermediateDirectories: true
        )
        try faultInjector(.configurationDirectoryCreated)
      }
      try FileManager.default.createSymbolicLink(
        atPath: entry.path,
        withDestinationPath: ownership.managedTarget
      )
    } catch {
      let installationError = error
      do {
        try restoreOriginal(ownership)
      } catch {
        throw SketchyBarDesktopError.invalidState(
          "SketchyBar provider installation failed: \(installationError); rollback failed: \(error)"
        )
      }
      throw installationError
    }
  }

  func restoreOriginal(_ ownership: SketchyBarOwnershipRecord) throws {
    if ownership.retainedOriginalPath != nil {
      try Self.authenticateRetained(ownership)
    }
    if ownership.original.kind == .directorySymlink
      || ownership.createdConfigurationDirectory
    {
      try preflightManagedConfigurationDirectory()
    }
    if isManagedEntry(target: ownership.managedTarget) {
      guard unlink(entry.path) == 0 else {
        throw SketchyBarDesktopError.system("remove managed sketchybarrc", entry, errno)
      }
    } else if pathExistsNoFollow(entry.path) {
      throw SketchyBarDesktopError.invalidState(
        "foreign sketchybarrc blocks restoration"
      )
    }

    if ownership.original.kind == .directorySymlink {
      try removeConfigurationDirectory()
    }
    if let retainedOriginalPath = ownership.retainedOriginalPath {
      guard rename(retainedOriginalPath, ownership.original.publicPath) == 0 else {
        throw SketchyBarDesktopError.system(
          "restore original SketchyBar entry",
          URL(filePath: ownership.original.publicPath),
          errno
        )
      }
    } else if ownership.createdConfigurationDirectory {
      try removeConfigurationDirectory()
    }
    let restored = try SketchyBarProviderPlanInspector().captureUnowned(
      directory: configurationDirectory,
      entry: entry
    )
    guard restored == ownership.original else {
      throw SketchyBarDesktopError.invalidState(
        "restored SketchyBar entry does not match approved evidence"
      )
    }
  }

  static func authenticateRetained(_ ownership: SketchyBarOwnershipRecord) throws {
    guard let retainedOriginalPath = ownership.retainedOriginalPath else { return }
    let retained = URL(filePath: retainedOriginalPath)
    let original = ownership.original
    var metadata = stat()
    guard
      lstat(retained.path, &metadata) == 0,
      UInt64(metadata.st_dev) == original.device,
      UInt64(metadata.st_ino) == original.inode,
      Int(metadata.st_mode & 0o777) == original.permissions,
      metadata.st_nlink == 1
    else {
      throw SketchyBarDesktopError.invalidState(
        "retained SketchyBar original identity has drifted"
      )
    }
    switch original.kind {
    case .regularFile:
      guard
        metadata.st_mode & S_IFMT == S_IFREG,
        sha256Digest(try BoundedRegularFile.read(at: retained).data) == original.contentDigest
      else {
        throw SketchyBarDesktopError.invalidState(
          "retained sketchybarrc bytes have drifted"
        )
      }
    case .entrySymlink, .directorySymlink:
      guard
        metadata.st_mode & S_IFMT == S_IFLNK,
        readLink(retained) == original.linkTarget,
        let target = original.linkTarget
      else {
        throw SketchyBarDesktopError.invalidState(
          "retained SketchyBar symlink has drifted"
        )
      }
      let publicPath = URL(filePath: original.publicPath)
      let source = resolveLink(target, at: publicPath)
      if original.kind == .directorySymlink {
        let descriptor = try PinnedFilesystem.openDirectory(at: source)
        defer { Darwin.close(descriptor) }
        let inventory = try PinnedFilesystem.directoryEntries(
          descriptor: descriptor,
          url: source,
          limit: 1_024
        )
        guard !inventory.truncated, inventory.entries == original.inventory else {
          throw SketchyBarDesktopError.invalidState(
            "retained SketchyBar directory source inventory drifted"
          )
        }
        let digest = sha256Digest(
          try PinnedFilesystem.readRegularFile(
            parentDescriptor: descriptor,
            name: "sketchybarrc",
            url: source.appending(path: "sketchybarrc")
          ).data
        )
        guard digest == original.contentDigest else {
          throw SketchyBarDesktopError.invalidState(
            "retained SketchyBar directory source bytes drifted"
          )
        }
      } else {
        let digest = sha256Digest(try BoundedRegularFile.read(at: source).data)
        guard digest == original.contentDigest else {
          throw SketchyBarDesktopError.invalidState(
            "retained sketchybarrc symlink source bytes drifted"
          )
        }
      }
    case .absent:
      throw SketchyBarDesktopError.invalidState(
        "absent SketchyBar state cannot have a retained original"
      )
    }
  }

  private var configurationDirectory: URL {
    homeDirectory.appending(path: ".config/sketchybar", directoryHint: .isDirectory)
  }

  private var entry: URL { configurationDirectory.appending(path: "sketchybarrc") }

  private func isManagedEntry(target: String) -> Bool {
    guard let observed = Self.readLink(entry) else { return false }
    var metadata = stat()
    return lstat(entry.path, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFLNK
      && metadata.st_nlink == 1
      && observed == target
  }

  private static func readLink(_ url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(url.path, &buffer, buffer.count - 1)
    guard count >= 0 else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  private static func resolveLink(_ target: String, at link: URL) -> URL {
    if target.hasPrefix("/") { return URL(filePath: target).standardizedFileURL }
    return link.deletingLastPathComponent().appending(path: target).standardizedFileURL
  }

  private func originalInodeIsPublic(_ original: SketchyBarAdoptionEvidence) -> Bool {
    guard original.kind != .absent else { return false }
    var metadata = stat()
    guard
      lstat(original.publicPath, &metadata) == 0,
      UInt64(metadata.st_dev) == original.device,
      UInt64(metadata.st_ino) == original.inode,
      Int(metadata.st_mode & 0o777) == original.permissions,
      metadata.st_nlink == 1
    else { return false }
    switch original.kind {
    case .regularFile:
      return metadata.st_mode & S_IFMT == S_IFREG
    case .entrySymlink, .directorySymlink:
      return metadata.st_mode & S_IFMT == S_IFLNK
        && Self.readLink(URL(filePath: original.publicPath)) == original.linkTarget
    case .absent:
      return false
    }
  }

  private func preflightManagedConfigurationDirectory() throws {
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(descriptor) }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor,
      url: configurationDirectory,
      limit: 1
    )
    guard
      !inventory.truncated,
      inventory.entries.isEmpty || inventory.entries == ["sketchybarrc"]
    else {
      throw SketchyBarDesktopError.invalidState(
        "foreign SketchyBar configuration entries block restoration"
      )
    }
  }

  private func removeConfigurationDirectory() throws {
    guard rmdir(configurationDirectory.path) == 0 else {
      if errno == ENOENT { return }
      throw SketchyBarDesktopError.system(
        "remove empty managed SketchyBar directory",
        configurationDirectory,
        errno
      )
    }
  }

  private func pathExistsNoFollow(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0
  }
}
