import Darwin
import Foundation
import ThemeCore

enum KeybindingProviderCheckpoint: Sendable {
  case manifestPrepared
  case backupWritten
  case providerReplaced
  case originalRestored
}

struct KeybindingProviderTransaction: Sendable {
  let homeDirectory: URL
  let faultInjector: @Sendable (KeybindingProviderCheckpoint) throws -> Void

  init(
    homeDirectory: URL,
    faultInjector: @escaping @Sendable (KeybindingProviderCheckpoint) throws -> Void = { _ in }
  ) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.faultInjector = faultInjector
  }

  private var configurationDirectory: URL {
    homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
  }

  private var directory: URL {
    configurationDirectory.appending(path: "skhd", directoryHint: .isDirectory)
  }

  private var entry: URL {
    directory.appending(path: "skhdrc")
  }

  private var backup: URL {
    homeDirectory.appending(path: ".config/macarchy/state/setup/backups/keybindings-skhdrc")
  }

  func installEntry(adopt: Bool = false) throws {
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    var records = try manager.readRecords(context: context)
    if let record = records.first(where: { $0.id == KeybindingProviderInspector.ownershipID }) {
      try KeybindingProviderInspector.validateOwnershipRecord(record, context: context)
      try ensureRegularBackup(record, manager: manager)
      try replaceOriginalWithManaged(record)
      try manager.save(record: record.applied, records: &records, context: context)
      return
    }

    let original = try captureOriginal(manager: manager)
    guard original.kind == .absent || adopt else {
      throw KeybindingsApplyError.blocked(
        "existing skhd configuration requires explicit adoption approval"
      )
    }
    guard try manager.itemExists(backup) == false else {
      throw SetupOwnershipError.orphanedBackup(backup)
    }
    let record = original.record(entry: entry, backup: backup, manager: manager, context: context)
    do {
      try manager.save(record: record, records: &records, context: context)
      try faultInjector(.manifestPrepared)
      if let data = original.data {
        try manager.writeRegularBackup(data, record: record, backupURL: backup)
        try faultInjector(.backupWritten)
      }
      try replaceOriginalWithManaged(record)
      try faultInjector(.providerReplaced)
      try manager.save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(
        error,
        integrationID: KeybindingProviderInspector.ownershipID,
        target: entry
      )
    }
  }

  func restoreOriginalEntry() throws {
    let (record, _, context) = try ownershipRecord()
    switch originalKind(record) {
    case .directorySymbolicLink:
      try restoreOriginalDirectory(record)
    case .absent, .regularFile, .symbolicLink:
      try restoreOriginalLeaf(record, context: context)
    }
    try faultInjector(.originalRestored)
  }

  func restoreManagedEntry() throws {
    let (record, _, _) = try ownershipRecord()
    switch originalKind(record) {
    case .directorySymbolicLink:
      try replaceOriginalDirectoryWithManaged(record)
    case .absent, .regularFile, .symbolicLink:
      try replaceOriginalLeafWithManaged(record)
    }
  }

  func finalizeOriginalRestoration() throws {
    let (record, existingRecords, context) = try ownershipRecord()
    var records = existingRecords
    try verifyOriginal(record, context: context)
    let manager = SetupOwnershipManager()
    records.removeAll { $0.id == KeybindingProviderInspector.ownershipID }
    try manager.persist(records: records, context: context)
    if originalKind(record) == .regularFile {
      try manager.removeRegularFileIfPresent(backup, unsafe: .corruptBackup(backup))
    }
  }

  func finalizeCompletedTeardownResidue() throws {
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let records = try manager.readRecords(context: context)
    guard !records.contains(where: { $0.id == KeybindingProviderInspector.ownershipID }) else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    try manager.removeRegularFileIfPresent(backup, unsafe: .corruptBackup(backup))
  }

  private func ownershipRecord() throws -> (
    SetupOwnershipRecord, [SetupOwnershipRecord], SetupOwnershipManager.Context
  ) {
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let records = try manager.readRecords(context: context)
    guard let record = records.first(where: { $0.id == KeybindingProviderInspector.ownershipID })
    else { throw SetupOwnershipError.ownershipDrift(entry) }
    try KeybindingProviderInspector.validateOwnershipRecord(record, context: context)
    return (record, records, context)
  }

  private func captureOriginal(manager: SetupOwnershipManager) throws -> OriginalEntry {
    let configurationDescriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(configurationDescriptor) }
    let directoryMetadata = try PinnedFilesystem.metadata(
      parentDescriptor: configurationDescriptor,
      name: "skhd",
      url: directory
    )
    if directoryMetadata.st_mode & S_IFMT == S_IFLNK {
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: configurationDescriptor,
        name: "skhd",
        url: directory
      )
      let target = Self.resolveSymlink(destination, relativeTo: configurationDirectory)
      let targetDescriptor = try PinnedFilesystem.openDirectory(at: target)
      defer { Darwin.close(targetDescriptor) }
      let inventory = try PinnedFilesystem.directoryEntries(
        descriptor: targetDescriptor,
        url: target,
        limit: 2
      )
      guard inventory.entries == ["skhdrc"], !inventory.truncated else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
      _ = try PinnedFilesystem.readRegularFile(
        parentDescriptor: targetDescriptor,
        name: "skhdrc",
        url: target.appending(path: "skhdrc")
      )
      return OriginalEntry(kind: .directorySymbolicLink, data: nil, linkDestination: destination)
    }
    guard directoryMetadata.st_mode & S_IFMT == S_IFDIR else {
      throw SetupOwnershipError.ownershipDrift(directory)
    }

    let directoryDescriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: configurationDescriptor,
      name: "skhd",
      url: directory
    )
    defer { Darwin.close(directoryDescriptor) }
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
        url: entry
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return OriginalEntry(kind: .absent, data: nil, linkDestination: nil)
    }
    switch metadata.st_mode & S_IFMT {
    case S_IFREG:
      let data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
        url: entry,
        maximumSize: SetupOwnershipManager.maximumConfigurationSize
      ).data
      return OriginalEntry(kind: .regularFile, data: data, linkDestination: nil)
    case S_IFLNK:
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
        url: entry
      )
      let resolved = Self.resolveSymlink(destination, relativeTo: directory)
      _ = try PinnedFilesystem.readRegularFile(
        at: resolved,
        maximumSize: SetupOwnershipManager.maximumConfigurationSize
      )
      _ = try manager.themeLinkState(
        id: KeybindingProviderInspector.ownershipID,
        url: entry,
        target: entry
      )
      return OriginalEntry(kind: .symbolicLink, data: nil, linkDestination: destination)
    default:
      throw SetupOwnershipError.ownershipDrift(entry)
    }
  }

  private func ensureRegularBackup(
    _ record: SetupOwnershipRecord,
    manager: SetupOwnershipManager
  ) throws {
    guard originalKind(record) == .regularFile else { return }
    if try manager.itemExists(backup) {
      _ = try manager.readRegularBackup(record: record, backupURL: backup)
      return
    }
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    try verifyOriginal(record, context: context)
    let directoryDescriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(directoryDescriptor) }
    let data = try PinnedFilesystem.readRegularFile(
      parentDescriptor: directoryDescriptor,
      name: "skhdrc",
      url: entry,
      maximumSize: SetupOwnershipManager.maximumConfigurationSize
    ).data
    try manager.writeRegularBackup(data, record: record, backupURL: backup)
  }

  private func replaceOriginalWithManaged(_ record: SetupOwnershipRecord) throws {
    switch originalKind(record) {
    case .directorySymbolicLink:
      try replaceOriginalDirectoryWithManaged(record)
    case .absent, .regularFile, .symbolicLink:
      try replaceOriginalLeafWithManaged(record)
    }
  }

  private func replaceOriginalLeafWithManaged(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    let claim = ".skhdrc.macarchy-keybindings"
    let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
    let claimState = try leafState(descriptor: descriptor, name: claim, record: record)
    if state == .managed {
      if claimState == .original { try unlink(descriptor: descriptor, name: claim, url: entry) }
      guard claimState == .missing || claimState == .original else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      return
    }
    if state == .original, claimState == .managed {
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try unlink(descriptor: descriptor, name: claim, url: entry)
      return
    }
    guard state == .original || (state == .missing && originalKind(record) == .absent),
      claimState == .missing
    else { throw SetupOwnershipError.ownershipDrift(entry) }
    try createSymlink(
      descriptor: descriptor,
      name: claim,
      destination: KeybindingProviderInspector.managedTarget,
      url: entry
    )
    if state == .missing {
      try rename(descriptor: descriptor, from: claim, to: "skhdrc", url: entry)
    } else {
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      guard try leafState(descriptor: descriptor, name: claim, record: record) == .original
      else { throw SetupOwnershipError.ownershipDrift(entry) }
      try unlink(descriptor: descriptor, name: claim, url: entry)
    }
  }

  private func restoreOriginalLeaf(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    let claim = ".skhdrc.macarchy-keybindings"
    let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
    let claimState = try leafState(descriptor: descriptor, name: claim, record: record)
    if state == .original || (state == .missing && originalKind(record) == .absent) {
      if claimState == .managed { try unlink(descriptor: descriptor, name: claim, url: entry) }
      guard claimState == .missing || claimState == .managed else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      return
    }
    if state == .managed, claimState == .original {
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try unlink(descriptor: descriptor, name: claim, url: entry)
      return
    }
    guard state == .managed, claimState == .missing else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    switch originalKind(record) {
    case .absent:
      try rename(descriptor: descriptor, from: "skhdrc", to: claim, url: entry)
      try unlink(descriptor: descriptor, name: claim, url: entry)
    case .regularFile:
      let data = try SetupOwnershipManager().readRegularBackup(record: record, backupURL: backup)
      try PinnedFilesystem.writeNewRegularFile(
        parentDescriptor: descriptor,
        name: claim,
        url: entry.deletingLastPathComponent().appending(path: claim),
        data: data,
        mode: 0o600
      )
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try unlink(descriptor: descriptor, name: claim, url: entry)
    case .symbolicLink:
      try createSymlink(
        descriptor: descriptor,
        name: claim,
        destination: try originalLink(record),
        url: entry
      )
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try unlink(descriptor: descriptor, name: claim, url: entry)
    case .directorySymbolicLink:
      throw SetupOwnershipError.invalidManifest("directory adoption cannot restore a leaf")
    }
    try verifyOriginal(record, context: context)
  }

  private func replaceOriginalDirectoryWithManaged(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(descriptor) }
    let claim = ".skhd.macarchy-keybindings"
    let state = try directoryState(descriptor: descriptor, name: "skhd", record: record)
    let claimState = try directoryState(descriptor: descriptor, name: claim, record: record)
    if state == .managed {
      if claimState == .original { try unlink(descriptor: descriptor, name: claim, url: directory) }
      guard claimState == .missing || claimState == .original else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
      return
    }
    if state == .original, claimState == .managed {
      try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
      try removeManagedDirectory(parentDescriptor: descriptor, name: claim)
      return
    }
    guard state == .original, claimState == .missing else {
      throw SetupOwnershipError.ownershipDrift(directory)
    }
    try createManagedDirectory(parentDescriptor: descriptor, name: claim)
    try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
    guard try directoryState(descriptor: descriptor, name: claim, record: record) == .original
    else { throw SetupOwnershipError.ownershipDrift(directory) }
    try unlink(descriptor: descriptor, name: claim, url: directory)
  }

  private func restoreOriginalDirectory(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(descriptor) }
    let claim = ".skhd.macarchy-keybindings"
    let state = try directoryState(descriptor: descriptor, name: "skhd", record: record)
    let claimState = try directoryState(descriptor: descriptor, name: claim, record: record)
    if state == .original {
      if claimState == .managed {
        try removeManagedDirectory(parentDescriptor: descriptor, name: claim)
      }
      guard claimState == .missing || claimState == .managed else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
      return
    }
    if state == .managed, claimState == .original {
      try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
      try removeManagedDirectory(parentDescriptor: descriptor, name: claim)
      return
    }
    guard state == .managed, claimState == .missing else {
      throw SetupOwnershipError.ownershipDrift(directory)
    }
    try createSymlink(
      descriptor: descriptor,
      name: claim,
      destination: try originalLink(record),
      url: directory
    )
    try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
    try removeManagedDirectory(parentDescriptor: descriptor, name: claim)
  }

  private func verifyOriginal(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    switch originalKind(record) {
    case .directorySymbolicLink:
      let descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
      defer { Darwin.close(descriptor) }
      guard try directoryState(descriptor: descriptor, name: "skhd", record: record) == .original
      else { throw SetupOwnershipError.ownershipDrift(directory) }
    case .absent, .regularFile, .symbolicLink:
      let descriptor = try PinnedFilesystem.openDirectory(at: directory)
      defer { Darwin.close(descriptor) }
      let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
      guard state == .original || (state == .missing && originalKind(record) == .absent) else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
    }
  }

  private func leafState(
    descriptor: Int32,
    name: String,
    record: SetupOwnershipRecord
  ) throws -> ProviderItemState {
    let url = directory.appending(path: name)
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(parentDescriptor: descriptor, name: name, url: url)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .missing
    }
    switch metadata.st_mode & S_IFMT {
    case S_IFLNK:
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: descriptor,
        name: name,
        url: url
      )
      if destination == KeybindingProviderInspector.managedTarget { return .managed }
      if originalKind(record) == .symbolicLink, destination == record.originalLinkDestination {
        return .original
      }
      return .other
    case S_IFREG where originalKind(record) == .regularFile:
      let data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: descriptor,
        name: name,
        url: url,
        maximumSize: SetupOwnershipManager.maximumConfigurationSize
      ).data
      return sha256Digest(data) == record.originalDigest ? .original : .other
    default:
      return .other
    }
  }

  private func directoryState(
    descriptor: Int32,
    name: String,
    record: SetupOwnershipRecord
  ) throws -> ProviderItemState {
    let url = configurationDirectory.appending(path: name)
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(parentDescriptor: descriptor, name: name, url: url)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .missing
    }
    if metadata.st_mode & S_IFMT == S_IFLNK {
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: descriptor,
        name: name,
        url: url
      )
      return destination == record.originalLinkDestination ? .original : .other
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR else { return .other }
    let directoryDescriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: descriptor,
      name: name,
      url: url
    )
    defer { Darwin.close(directoryDescriptor) }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: directoryDescriptor,
      url: url,
      limit: 2
    )
    guard inventory.entries == ["skhdrc"], !inventory.truncated else { return .other }
    let target = try PinnedFilesystem.symlinkDestination(
      parentDescriptor: directoryDescriptor,
      name: "skhdrc",
      url: url.appending(path: "skhdrc")
    )
    return target == KeybindingProviderInspector.managedTarget ? .managed : .other
  }

  private func createManagedDirectory(parentDescriptor: Int32, name: String) throws {
    let url = configurationDirectory.appending(path: name, directoryHint: .isDirectory)
    let descriptor = try PinnedFilesystem.createDirectory(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    defer { Darwin.close(descriptor) }
    try createSymlink(
      descriptor: descriptor,
      name: "skhdrc",
      destination: KeybindingProviderInspector.managedTarget,
      url: url.appending(path: "skhdrc")
    )
  }

  private func removeManagedDirectory(parentDescriptor: Int32, name: String) throws {
    let url = configurationDirectory.appending(path: name, directoryHint: .isDirectory)
    let descriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor, url: url, limit: 2)
    guard inventory.entries == ["skhdrc"], !inventory.truncated,
      try leafState(descriptor: descriptor, name: "skhdrc", record: absentRecord()) == .managed
    else {
      Darwin.close(descriptor)
      throw SetupOwnershipError.ownershipDrift(url)
    }
    try unlink(descriptor: descriptor, name: "skhdrc", url: url)
    Darwin.close(descriptor)
    guard name.withCString({ Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
      throw posixError("remove managed skhd directory", url)
    }
    try sync(parentDescriptor, url: configurationDirectory)
  }

  private func absentRecord() -> SetupOwnershipRecord {
    SetupOwnershipRecord(
      id: KeybindingProviderInspector.ownershipID,
      phase: .applied,
      kind: .symbolicLink,
      targetPath: entry.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(KeybindingProviderInspector.managedTarget.utf8)),
      linkDestination: KeybindingProviderInspector.managedTarget,
      originalKind: .absent
    )
  }

  private func originalKind(_ record: SetupOwnershipRecord) -> SetupOwnershipRecord.OriginalKind {
    record.originalKind ?? .absent
  }

  private func originalLink(_ record: SetupOwnershipRecord) throws -> String {
    guard let destination = record.originalLinkDestination else {
      throw SetupOwnershipError.invalidManifest("keybinding adoption link text is missing")
    }
    return destination
  }

  private func createSymlink(
    descriptor: Int32,
    name: String,
    destination: String,
    url: URL
  ) throws {
    let result = destination.withCString { target in
      name.withCString { Darwin.symlinkat(target, descriptor, $0) }
    }
    guard result == 0 else { throw posixError("create keybinding provider link", url) }
    try sync(descriptor, url: url.deletingLastPathComponent())
  }

  private func unlink(descriptor: Int32, name: String, url: URL) throws {
    guard name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
      throw posixError("remove keybinding provider item", url)
    }
    try sync(descriptor, url: url.deletingLastPathComponent())
  }

  private func rename(descriptor: Int32, from: String, to: String, url: URL) throws {
    let result = from.withCString { source in
      to.withCString { destination in Darwin.renameat(descriptor, source, descriptor, destination) }
    }
    guard result == 0 else { throw posixError("rename keybinding provider item", url) }
    try sync(descriptor, url: url.deletingLastPathComponent())
  }

  private func swap(descriptor: Int32, first: String, second: String, url: URL) throws {
    let result = first.withCString { firstPath in
      second.withCString { secondPath in
        Darwin.renameatx_np(
          descriptor,
          firstPath,
          descriptor,
          secondPath,
          UInt32(RENAME_SWAP)
        )
      }
    }
    guard result == 0 else { throw posixError("swap keybinding provider item", url) }
    try sync(descriptor, url: url.deletingLastPathComponent())
  }

  private func sync(_ descriptor: Int32, url: URL) throws {
    guard fsync(descriptor) == 0 else { throw posixError("sync keybinding provider", url) }
  }

  private func posixError(_ operation: String, _ url: URL) -> SetupOwnershipError {
    .system(operation, url, String(cString: strerror(errno)))
  }

  private static func resolveSymlink(_ destination: String, relativeTo parent: URL) -> URL {
    if NSString(string: destination).isAbsolutePath {
      return URL(filePath: destination).standardizedFileURL
    }
    return parent.appending(path: destination).standardizedFileURL
  }
}

private struct OriginalEntry {
  let kind: SetupOwnershipRecord.OriginalKind
  let data: Data?
  let linkDestination: String?

  func record(
    entry: URL,
    backup: URL,
    manager: SetupOwnershipManager,
    context: SetupOwnershipManager.Context
  ) -> SetupOwnershipRecord {
    SetupOwnershipRecord(
      id: KeybindingProviderInspector.ownershipID,
      phase: .prepared,
      kind: .symbolicLink,
      targetPath: entry.path,
      backupPath: kind == .regularFile
        ? manager.relativePath(backup, below: context.stateRoot) : nil,
      originalDigest: data.map(sha256Digest)
        ?? linkDestination.map { sha256Digest(Data($0.utf8)) },
      installedDigest: sha256Digest(Data(KeybindingProviderInspector.managedTarget.utf8)),
      linkDestination: KeybindingProviderInspector.managedTarget,
      originalKind: kind,
      originalLinkDestination: linkDestination
    )
  }
}

private enum ProviderItemState: Equatable {
  case managed
  case missing
  case original
  case other
}
