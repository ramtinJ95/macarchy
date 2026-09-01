import Darwin
import Foundation
import ThemeCore

enum SketchyBarTransactionPhase: String, Codable, Sendable {
  case prepared
  case generationPublished = "generation_published"
  case generationSelected = "generation_selected"
  case providerChanging = "provider_changing"
  case providerChanged = "provider_changed"
}

struct SketchyBarTransaction: Codable, Equatable, Sendable {
  let schemaVersion: Int
  var phase: SketchyBarTransactionPhase
  let generationID: String
  let previousGenerationID: String?
  let generationCreated: Bool
  let ownership: SketchyBarOwnershipRecord
  let previousOwnership: SketchyBarOwnershipRecord?

  init(
    phase: SketchyBarTransactionPhase,
    generationID: String,
    previousGenerationID: String?,
    generationCreated: Bool,
    ownership: SketchyBarOwnershipRecord,
    previousOwnership: SketchyBarOwnershipRecord?
  ) {
    schemaVersion = 1
    self.phase = phase
    self.generationID = generationID
    self.previousGenerationID = previousGenerationID
    self.generationCreated = generationCreated
    self.ownership = ownership
    self.previousOwnership = previousOwnership
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case phase
    case generationID = "generation_id"
    case previousGenerationID = "previous_generation_id"
    case generationCreated = "generation_created"
    case ownership
    case previousOwnership = "previous_ownership"
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
    let generationRelationshipIsValid =
      transaction.generationCreated
      ? transaction.generationID != transaction.previousGenerationID
      : transaction.generationID == transaction.previousGenerationID
    let previousOwnershipIsValid =
      transaction.previousOwnership.map {
        SketchyBarOwnershipStore.isValid($0, stateRoot: stateRoot)
          && $0.generationID == transaction.previousGenerationID
      } ?? true
    guard
      transaction.schemaVersion == 1,
      SketchyBarGenerationInspector.isGenerationID(transaction.generationID),
      transaction.previousGenerationID.map(SketchyBarGenerationInspector.isGenerationID) ?? true,
      SketchyBarOwnershipStore.isValid(transaction.ownership, stateRoot: stateRoot),
      transaction.ownership.generationID == transaction.generationID,
      generationRelationshipIsValid,
      previousOwnershipIsValid
    else {
      throw SketchyBarDesktopError.invalidState("SketchyBar transaction record is invalid")
    }
    return transaction
  }

  func write(_ transaction: SketchyBarTransaction) throws {
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
}

enum SketchyBarTransactionCheckpoint: Sendable {
  case generationPublished
  case generationSelected
  case originalRetained
  case configurationDirectoryCreated
  case providerChanged
}

enum SketchyBarInterruptionError: Error, Sendable {
  case injected
}

struct SketchyBarFilesystemConvergenceResult: Equatable, Sendable {
  let generationID: String
  let changed: Bool
}

struct SketchyBarProviderTransaction: Sendable {
  let homeDirectory: URL
  let stateRoot: URL
  let faultInjector: @Sendable (SketchyBarTransactionCheckpoint) throws -> Void

  init(
    homeDirectory: URL,
    stateRoot: URL,
    faultInjector: @escaping @Sendable (SketchyBarTransactionCheckpoint) throws -> Void = { _ in }
  ) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.stateRoot = stateRoot.standardizedFileURL
    self.faultInjector = faultInjector
  }

  // The aggregate desktop mutation owns ActivationLock across every provider transaction.
  func convergeLocked(
    composition: SketchyBarComposition,
    adoptionEvidenceDigest: String?
  ) throws -> SketchyBarFilesystemConvergenceResult {
    let transactionStore = SketchyBarTransactionStore(stateRoot: stateRoot)
    if let pending = try transactionStore.read() {
      try recoverApply(pending)
    }

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
            "adoption requires --adopt \(original.digest) from the current reviewed plan"
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
    let ownership = SketchyBarOwnershipRecord(
      generationID: generationID,
      managedTarget: SketchyBarProviderPlanInspector.managedTarget(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ),
      original: original,
      retainedOriginalPath: retainedOriginalPath,
      createdConfigurationDirectory: createdConfigurationDirectory
    )
    if generationAgrees, previousOwnership == ownership {
      return SketchyBarFilesystemConvergenceResult(generationID: generationID, changed: false)
    }

    var transaction = SketchyBarTransaction(
      phase: .prepared,
      generationID: generationID,
      previousGenerationID: previousGeneration.generationID,
      generationCreated: !generationAgrees,
      ownership: ownership,
      previousOwnership: previousOwnership
    )
    try transactionStore.write(transaction)
    let activator = SketchyBarGenerationActivator(stateRoot: stateRoot)
    do {
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
      try transactionStore.remove()
      return SketchyBarFilesystemConvergenceResult(generationID: generationID, changed: true)
    } catch is SketchyBarInterruptionError {
      throw SketchyBarInterruptionError.injected
    } catch {
      if let persisted = try transactionStore.read() {
        try recoverApply(persisted)
      }
      throw error
    }
  }

  func recoverApply(_ transaction: SketchyBarTransaction) throws {
    try validateContext(transaction)
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
    let activator = SketchyBarGenerationActivator(stateRoot: stateRoot)
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
    try SketchyBarTransactionStore(stateRoot: stateRoot).remove()
  }

  private func authenticateCurrentForRecovery(_ transaction: SketchyBarTransaction) throws {
    let current = SketchyBarGenerationInspector(stateRoot: stateRoot).inspect()
    switch current.status {
    case .missing:
      guard transaction.previousGenerationID == nil else {
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
