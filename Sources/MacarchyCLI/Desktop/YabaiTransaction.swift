import Darwin
import Foundation
import ThemeCore

enum YabaiTransactionOperation: String, Codable, Sendable {
  case apply
  case teardown
}

enum YabaiTransactionPhase: String, Codable, Sendable {
  case prepared
  case providerChanging = "provider_changing"
  case providerChanged = "provider_changed"
  case serviceChanging = "service_changing"
  case serviceChanged = "service_changed"
}

struct YabaiTransaction: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let operation: YabaiTransactionOperation
  var phase: YabaiTransactionPhase
  let generationID: String
  let previousGenerationID: String?
  let generationCreated: Bool
  let ownership: YabaiOwnershipRecord
  let previousOwnership: YabaiOwnershipRecord?
  let previousLifecycle: YabaiLifecycleEvidence?
  let serviceWasRunning: Bool
  var service: YabaiServiceChange?

  init(
    operation: YabaiTransactionOperation,
    phase: YabaiTransactionPhase,
    generationID: String,
    previousGenerationID: String?,
    generationCreated: Bool,
    ownership: YabaiOwnershipRecord,
    previousOwnership: YabaiOwnershipRecord?,
    previousLifecycle: YabaiLifecycleEvidence?,
    serviceWasRunning: Bool,
    service: YabaiServiceChange? = nil
  ) {
    schemaVersion = service == nil ? 1 : 2
    self.operation = operation
    self.phase = phase
    self.generationID = generationID
    self.previousGenerationID = previousGenerationID
    self.generationCreated = generationCreated
    self.ownership = ownership
    self.previousOwnership = previousOwnership
    self.previousLifecycle = previousLifecycle
    self.serviceWasRunning = serviceWasRunning
    self.service = service
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, phase, service
    case generationID = "generation_id"
    case previousGenerationID = "previous_generation_id"
    case generationCreated = "generation_created"
    case ownership
    case previousOwnership = "previous_ownership"
    case previousLifecycle = "previous_lifecycle"
    case serviceWasRunning = "service_was_running"
  }
}

struct YabaiTransactionStore: Sendable {
  let stateRoot: URL

  private var file: DesktopStateFile {
    DesktopStateFile(
      stateRoot: stateRoot, directory: "desktop/yabai", name: "transaction.json",
      maximumSize: 65_536)
  }

  var exists: Bool { file.exists }

  func read() throws -> YabaiTransaction? {
    guard let transaction = try file.read(YabaiTransaction.self) else { return nil }
    guard
      transaction.schemaVersion == (transaction.service == nil ? 1 : 2),
      transaction.service?.isValid ?? true,
      transaction.service.map({ $0.previous.running == transaction.serviceWasRunning }) ?? true,
      YabaiGenerationInspector.isGenerationID(transaction.generationID),
      transaction.previousGenerationID.map(YabaiGenerationInspector.isGenerationID) ?? true
    else {
      throw YabaiDesktopError.invalidState("yabai transaction record is invalid")
    }
    return transaction
  }

  func write(_ transaction: YabaiTransaction) throws {
    try file.write(transaction)
  }

  func remove() throws { try file.remove() }
}

enum YabaiTransactionCheckpoint: Sendable {
  case providerChanged
  case providerRestored
}

enum YabaiInterruptionError: Error, Sendable {
  case injected
}

struct YabaiProviderTransaction: Sendable {
  let homeDirectory: URL
  let stateRoot: URL

  private var configurationDirectory: URL {
    homeDirectory.appending(path: ".config/yabai", directoryHint: .isDirectory)
  }

  private var entry: URL { configurationDirectory.appending(path: "yabairc") }

  func retainedOriginalURL(nonce: UUID = UUID()) -> URL {
    stateRoot.appending(path: "desktop/yabai/retained-\(nonce.uuidString.lowercased())")
  }

  /// Settles an interrupted transaction: rolls back an apply or completes a teardown.
  func recoverPending(_ pending: YabaiTransaction, lifecycle: YabaiLifecycleController) throws {
    switch pending.operation {
    case .apply:
      try recoverApply(pending, lifecycle: lifecycle)
    case .teardown:
      try completeTeardown(pending, lifecycle: lifecycle)
    }
  }

  func teardownLocked(
    lifecycle: YabaiLifecycleController,
    faultInjector: @Sendable (YabaiTransactionCheckpoint) throws -> Void,
    dryRun: Bool,
    deferFinalization: Bool = false
  ) throws -> ApplyResult {
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
      try recoverPending(pending, lifecycle: lifecycle)
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
    let service = try lifecycle.service?.prepare(home: homeDirectory, stateRoot: stateRoot)
    let serviceWasRunning = try lifecycle.preflight()
    if let service, service.previous.running != serviceWasRunning {
      throw YabaiDesktopError.lifecycle("yabai service changed during preflight; review again")
    }
    var transaction = YabaiTransaction(
      operation: .teardown,
      phase: .providerChanging,
      generationID: ownership.generationID,
      previousGenerationID: ownership.generationID,
      generationCreated: false,
      ownership: ownership,
      previousOwnership: ownership,
      previousLifecycle: try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).read(),
      serviceWasRunning: serviceWasRunning,
      service: service
    )
    try transactionStore.write(transaction)
    try restoreOriginal(ownership)
    transaction.phase = .providerChanged
    try transactionStore.write(transaction)
    try faultInjector(.providerRestored)
    transaction.phase = .serviceChanging
    try transactionStore.write(transaction)
    try completeTeardown(
      transaction,
      lifecycle: lifecycle,
      deferFinalization: deferFinalization
    )
    return ApplyResult(
      changed: true,
      generationID: ownership.generationID,
      lifecycle: ownership.priorServiceRunning ? "restart" : "stop",
      message:
        "restored exact \(ownership.original.kind.rawValue) evidence \(ownership.original.digest)"
    )
  }

  func installManaged(_ ownership: YabaiOwnershipRecord) throws {
    let original = ownership.original
    if let retainedPath = ownership.retainedOriginalPath {
      let retained = URL(filePath: retainedPath)
      guard !pathExistsNoFollow(retained.path) else {
        throw YabaiDesktopError.invalidState("retained yabai original already exists")
      }
      guard rename(original.publicPath, retained.path) == 0 else {
        throw YabaiDesktopError.system(
          "retain original yabai entry",
          URL(filePath: original.publicPath),
          errno
        )
      }
      try Self.authenticateRetained(ownership)
    }

    do {
      if original.kind == .directorySymlink || ownership.createdConfigurationDirectory {
        try FileManager.default.createDirectory(
          at: configurationDirectory,
          withIntermediateDirectories: true
        )
      }
      try FileManager.default.createSymbolicLink(
        atPath: entry.path,
        withDestinationPath: ownership.managedTarget
      )
    } catch {
      try? restoreOriginal(ownership)
      throw error
    }
  }

  func restoreOriginal(_ ownership: YabaiOwnershipRecord) throws {
    let original = ownership.original
    if ownership.retainedOriginalPath != nil {
      try Self.authenticateRetained(ownership)
    }
    if isManagedEntry(target: ownership.managedTarget) {
      guard unlink(entry.path) == 0 else {
        throw YabaiDesktopError.system("remove managed yabairc", entry, errno)
      }
    } else if FileManager.default.fileExists(atPath: entry.path) {
      throw YabaiDesktopError.invalidState("foreign yabairc blocks restoration")
    }

    if original.kind == .directorySymlink {
      do {
        try FileManager.default.removeItem(at: configurationDirectory)
      } catch {
        throw YabaiDesktopError.invalidState(
          "managed yabai directory is not empty during restoration: \(error)"
        )
      }
    }
    if let retainedPath = ownership.retainedOriginalPath {
      guard rename(retainedPath, original.publicPath) == 0 else {
        throw YabaiDesktopError.system(
          "restore original yabai entry",
          URL(filePath: original.publicPath),
          errno
        )
      }
    } else if ownership.createdConfigurationDirectory {
      do {
        try FileManager.default.removeItem(at: configurationDirectory)
      } catch {
        throw YabaiDesktopError.invalidState(
          "created yabai directory could not be removed during restoration: \(error)"
        )
      }
    }
    let restored = try YabaiProviderPlanInspector().captureUnowned(
      directory: configurationDirectory,
      entry: entry
    )
    guard original.matchesObserved(restored) else {
      throw YabaiDesktopError.invalidState("restored yabai entry does not match approved evidence")
    }
  }

  func recoverApply(
    _ transaction: YabaiTransaction,
    lifecycle: YabaiLifecycleController
  ) throws {
    guard transaction.operation == .apply else {
      throw YabaiDesktopError.invalidState("cannot roll back a teardown as an apply")
    }
    if let change = transaction.service {
      guard let service = lifecycle.service else {
        throw YabaiDesktopError.invalidState("yabai service recovery controller is unavailable")
      }
      try service.validateRecovery(change, home: homeDirectory)
    }
    let managed = isManagedEntry(target: transaction.ownership.managedTarget)
    let originalPublic = originalIsPublic(transaction.ownership.original)
    let retainedExists =
      transaction.ownership.retainedOriginalPath.map {
        pathExistsNoFollow($0)
      } ?? false
    if let previousOwnership = transaction.previousOwnership {
      guard managed else {
        throw YabaiDesktopError.invalidState(
          "managed yabai entry drifted during interrupted update"
        )
      }
      try Self.authenticateRetained(previousOwnership)
    } else {
      if managed || retainedExists {
        try restoreOriginal(transaction.ownership)
      } else if !originalPublic {
        throw YabaiDesktopError.invalidState("interrupted yabai provider state is ambiguous")
      }
    }
    try YabaiGenerationActivator(stateRoot: stateRoot).restoreCurrent(
      transaction.previousGenerationID
    )
    if transaction.phase == .serviceChanging || transaction.phase == .serviceChanged {
      if let change = transaction.service, let service = lifecycle.service {
        try service.rollback(change, home: homeDirectory, stateRoot: stateRoot)
        if transaction.serviceWasRunning { try lifecycle.restart() }
      } else {
        try lifecycle.restoreService(wasRunning: transaction.serviceWasRunning)
      }
    }
    let ownershipStore = YabaiOwnershipStore(stateRoot: stateRoot)
    if let previous = transaction.previousOwnership {
      try ownershipStore.write(previous)
    } else {
      try ownershipStore.remove()
    }
    let lifecycleStore = YabaiLifecycleEvidenceStore(stateRoot: stateRoot)
    if let previous = transaction.previousLifecycle, transaction.serviceWasRunning {
      try lifecycleStore.write(previous)
    } else {
      try lifecycleStore.remove()
    }
    if transaction.generationCreated {
      try YabaiGenerationActivator(stateRoot: stateRoot).removeGeneration(transaction.generationID)
    }
    try YabaiTransactionStore(stateRoot: stateRoot).remove()
  }

  func completeTeardown(
    _ transaction: YabaiTransaction,
    lifecycle: YabaiLifecycleController,
    deferFinalization: Bool = false
  ) throws {
    guard transaction.operation == .teardown else {
      throw YabaiDesktopError.invalidState("cannot complete an apply as a teardown")
    }
    if isManagedEntry(target: transaction.ownership.managedTarget)
      || transaction.ownership.retainedOriginalPath.map({
        pathExistsNoFollow($0)
      }) == true
    {
      try restoreOriginal(transaction.ownership)
    }
    let restored = try YabaiProviderPlanInspector().captureUnowned(
      directory: configurationDirectory,
      entry: entry
    )
    guard transaction.ownership.original.matchesObserved(restored) else {
      throw YabaiDesktopError.invalidState("teardown restoration does not match approved evidence")
    }
    if let ownership = transaction.service?.previousOwnership {
      guard let service = lifecycle.service else {
        throw YabaiDesktopError.invalidState("yabai service recovery controller is unavailable")
      }
      // After the durable serviceChanged boundary, native uninstall may already
      // have completed. Finalization is idempotent; do not try to stop it again.
      if transaction.phase != .serviceChanged {
        try service.restoreOriginal(ownership, home: homeDirectory)
        if ownership.original.running { try lifecycle.restart() }
      }
    } else {
      try lifecycle.restoreService(wasRunning: transaction.ownership.priorServiceRunning)
    }
    var completing = transaction
    completing.phase = .serviceChanged
    try YabaiTransactionStore(stateRoot: stateRoot).write(completing)
    if deferFinalization { return }
    if let ownership = transaction.service?.previousOwnership, let service = lifecycle.service {
      try service.finalizeTeardown(ownership, home: homeDirectory, stateRoot: stateRoot)
    }
    try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).remove()
    try YabaiOwnershipStore(stateRoot: stateRoot).remove()
    try YabaiGenerationActivator(stateRoot: stateRoot).restoreCurrent(nil)
    try YabaiGenerationActivator(stateRoot: stateRoot).removeGeneration(transaction.generationID)
    try YabaiTransactionStore(stateRoot: stateRoot).remove()
  }

  func rollbackDeferred(
    lifecycle: YabaiLifecycleController
  ) throws {
    let store = YabaiTransactionStore(stateRoot: stateRoot)
    guard let transaction = try store.read() else { return }
    if transaction.operation == .apply {
      try recoverApply(transaction, lifecycle: lifecycle)
      return
    }
    if let change = transaction.service {
      guard let service = lifecycle.service else {
        throw YabaiDesktopError.invalidState("yabai service recovery controller is unavailable")
      }
      try service.validateRecovery(change, home: homeDirectory)
    }
    let managed = isManagedEntry(target: transaction.ownership.managedTarget)
    if !managed {
      let originalPublic = originalIsPublic(transaction.ownership.original)
      guard originalPublic else {
        throw YabaiDesktopError.invalidState(
          "deferred yabai teardown cannot restore managed ownership"
        )
      }
      try installManaged(transaction.ownership)
    }
    if let change = transaction.service, let service = lifecycle.service {
      try service.rollback(change, home: homeDirectory, stateRoot: stateRoot)
      if transaction.serviceWasRunning { try lifecycle.restart() }
    } else {
      try lifecycle.restoreService(wasRunning: transaction.serviceWasRunning)
    }
    if let previous = transaction.previousLifecycle {
      try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).write(previous)
    }
    try store.remove()
  }

  func commitDeferred(
    lifecycle: YabaiLifecycleController
  ) throws {
    let store = YabaiTransactionStore(stateRoot: stateRoot)
    guard let transaction = try store.read() else { return }
    switch transaction.operation {
    case .apply:
      guard transaction.phase == .serviceChanged else {
        throw YabaiDesktopError.invalidState(
          "deferred yabai apply is not ready to commit"
        )
      }
      if let change = transaction.service {
        guard let service = lifecycle.service else {
          throw YabaiDesktopError.invalidState("yabai service commit controller is unavailable")
        }
        try service.commit(change, home: homeDirectory, stateRoot: stateRoot)
      }
      try store.remove()
    case .teardown:
      try completeTeardown(transaction, lifecycle: lifecycle)
    }
  }

  private func isManagedEntry(target: String) -> Bool {
    var metadata = stat()
    return lstat(entry.path, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFLNK
      && SymbolicLink.target(of: entry) == target
  }

  private func originalIsPublic(_ original: YabaiAdoptionEvidence) -> Bool {
    original.matchesObserved(
      try? YabaiProviderPlanInspector().captureUnowned(
        directory: configurationDirectory,
        entry: entry
      ))
  }

  static func authenticateRetained(_ ownership: YabaiOwnershipRecord) throws {
    guard let retainedPath = ownership.retainedOriginalPath else { return }
    let retained = URL(filePath: retainedPath)
    let original = ownership.original
    var metadata = stat()
    guard
      lstat(retained.path, &metadata) == 0,
      try RetainedOriginalIdentity.matches(
        at: retained, metadata: metadata,
        volumeUUID: original.volumeUUID, device: original.device),
      UInt64(metadata.st_ino) == original.inode,
      Int(metadata.st_mode & 0o777) == original.permissions,
      metadata.st_nlink == 1
    else {
      throw YabaiDesktopError.invalidState("retained yabai original identity has drifted")
    }
    switch original.kind {
    case .regularFile:
      guard
        metadata.st_mode & S_IFMT == S_IFREG,
        sha256Digest(try BoundedRegularFile.read(at: retained).data) == original.contentDigest
      else {
        throw YabaiDesktopError.invalidState("retained yabairc bytes have drifted")
      }
    case .entrySymlink, .directorySymlink:
      guard
        metadata.st_mode & S_IFMT == S_IFLNK,
        SymbolicLink.target(of: retained) == original.linkTarget,
        let target = original.linkTarget
      else {
        throw YabaiDesktopError.invalidState("retained yabai symlink has drifted")
      }
      let publicPath = URL(filePath: original.publicPath)
      let source = SymbolicLink.resolve(target, at: publicPath)
      if original.kind == .directorySymlink {
        let inventory = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        guard inventory == original.inventory else {
          throw YabaiDesktopError.invalidState("retained yabai directory source inventory drifted")
        }
        let digest = sha256Digest(
          try BoundedRegularFile.read(at: source.appending(path: "yabairc")).data
        )
        guard digest == original.contentDigest else {
          throw YabaiDesktopError.invalidState("retained yabai directory source bytes drifted")
        }
      } else {
        let digest = sha256Digest(try BoundedRegularFile.read(at: source).data)
        guard digest == original.contentDigest else {
          throw YabaiDesktopError.invalidState("retained yabairc symlink source bytes drifted")
        }
      }
    case .absent:
      throw YabaiDesktopError.invalidState("absent yabai state cannot have a retained original")
    }
  }

  private func pathExistsNoFollow(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0
  }
}
