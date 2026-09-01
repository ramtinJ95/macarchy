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

  init(
    operation: YabaiTransactionOperation,
    phase: YabaiTransactionPhase,
    generationID: String,
    previousGenerationID: String?,
    generationCreated: Bool,
    ownership: YabaiOwnershipRecord,
    previousOwnership: YabaiOwnershipRecord?,
    previousLifecycle: YabaiLifecycleEvidence?,
    serviceWasRunning: Bool
  ) {
    schemaVersion = 1
    self.operation = operation
    self.phase = phase
    self.generationID = generationID
    self.previousGenerationID = previousGenerationID
    self.generationCreated = generationCreated
    self.ownership = ownership
    self.previousOwnership = previousOwnership
    self.previousLifecycle = previousLifecycle
    self.serviceWasRunning = serviceWasRunning
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
  }
}

struct YabaiTransactionStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "desktop/yabai", directoryHint: .isDirectory)
  }

  private var file: URL { directory.appending(path: "transaction.json") }

  var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

  func read() throws -> YabaiTransaction? {
    guard exists else { return nil }
    let data = try BoundedRegularFile.read(at: file, maximumSize: 65_536).data
    let transaction = try JSONDecoder().decode(YabaiTransaction.self, from: data)
    guard
      transaction.schemaVersion == 1,
      YabaiGenerationInspector.isGenerationID(transaction.generationID),
      transaction.previousGenerationID.map(YabaiGenerationInspector.isGenerationID) ?? true
    else {
      throw YabaiDesktopError.invalidState("yabai transaction record is invalid")
    }
    return transaction
  }

  func write(_ transaction: YabaiTransaction) throws {
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
    guard restored == original else {
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
    let managed = isManagedEntry(target: transaction.ownership.managedTarget)
    let originalPublic = originalIsPublic(transaction.ownership.original)
    let retainedExists =
      transaction.ownership.retainedOriginalPath.map {
        pathExistsNoFollow($0)
      } ?? false
    if managed || retainedExists {
      try restoreOriginal(transaction.ownership)
    } else if !originalPublic {
      throw YabaiDesktopError.invalidState("interrupted yabai provider state is ambiguous")
    }
    try YabaiGenerationActivator(stateRoot: stateRoot).restoreCurrent(
      transaction.previousGenerationID
    )
    if transaction.phase == .serviceChanging || transaction.phase == .serviceChanged {
      try lifecycle.restoreService(wasRunning: transaction.serviceWasRunning)
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
    lifecycle: YabaiLifecycleController
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
    guard restored == transaction.ownership.original else {
      throw YabaiDesktopError.invalidState("teardown restoration does not match approved evidence")
    }
    try lifecycle.restoreService(wasRunning: transaction.ownership.priorServiceRunning)
    try YabaiLifecycleEvidenceStore(stateRoot: stateRoot).remove()
    try YabaiOwnershipStore(stateRoot: stateRoot).remove()
    try YabaiGenerationActivator(stateRoot: stateRoot).restoreCurrent(nil)
    try YabaiGenerationActivator(stateRoot: stateRoot).removeGeneration(transaction.generationID)
    try YabaiTransactionStore(stateRoot: stateRoot).remove()
  }

  private func isManagedEntry(target: String) -> Bool {
    var metadata = stat()
    guard lstat(entry.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFLNK else {
      return false
    }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(entry.path, &buffer, buffer.count - 1)
    guard count >= 0 else { return false }
    let observed = String(
      decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)),
      as: UTF8.self
    )
    return observed == target
  }

  private func originalIsPublic(_ original: YabaiAdoptionEvidence) -> Bool {
    (try? YabaiProviderPlanInspector().captureUnowned(
      directory: configurationDirectory,
      entry: entry
    )) == original
  }

  static func authenticateRetained(_ ownership: YabaiOwnershipRecord) throws {
    guard let retainedPath = ownership.retainedOriginalPath else { return }
    let retained = URL(filePath: retainedPath)
    let original = ownership.original
    var metadata = stat()
    guard
      lstat(retained.path, &metadata) == 0,
      UInt64(metadata.st_dev) == original.device,
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
        readLink(retained) == original.linkTarget,
        let target = original.linkTarget
      else {
        throw YabaiDesktopError.invalidState("retained yabai symlink has drifted")
      }
      let publicPath = URL(filePath: original.publicPath)
      let source = resolveLink(target, at: publicPath)
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

  private func pathExistsNoFollow(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0
  }
}
