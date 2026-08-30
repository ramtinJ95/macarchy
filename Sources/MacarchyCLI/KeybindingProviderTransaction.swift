import Darwin
import Foundation
import ThemeCore

enum KeybindingProviderCheckpoint: Equatable, Sendable {
  case manifestPrepared
  case backupWritten
  case directoryClaimCreated
  case directoryClaimPopulated
  case directoryClaimEntryRemoved
  case regularRestorationClaimCreated
  case regularRestorationClaimWritten
  case regularRestorationClaimMetadataCopied
  case providerReplaced
  case originalRestored
}

struct KeybindingProviderTransaction: Sendable {
  private static let claimMarkerAttribute = "io.github.ramtinj95.macarchy.keybinding-claim"
  private static let unsupportedRestorationFlags =
    UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(UF_DATAVAULT)
    | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND) | UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK)

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

  func preflightInstall(
    expectedEvidence: KeybindingAdoptionEvidence,
    approvedEvidenceDigest: String?
  ) throws {
    _ = try captureApprovedOriginal(
      expectedEvidence: expectedEvidence,
      approvedEvidenceDigest: approvedEvidenceDigest
    )
  }

  func installEntry(
    expectedEvidence: KeybindingAdoptionEvidence,
    approvedEvidenceDigest: String?
  ) throws {
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

    let original = try captureApprovedOriginal(
      expectedEvidence: expectedEvidence,
      approvedEvidenceDigest: approvedEvidenceDigest
    )
    let record = original.record(entry: entry, backup: backup, manager: manager, context: context)
    do {
      try manager.save(record: record, records: &records, context: context)
      try faultInjector(.manifestPrepared)
      if let data = original.data {
        try writeOriginalBackup(data, record: record, manager: manager)
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

  func preflightOriginalRestoration() throws {
    let (record, _, _) = try ownershipRecord()
    let manager = SetupOwnershipManager()
    try requireLegacyClaimAbsent(for: record)
    switch originalKind(record) {
    case .directorySymbolicLink:
      let descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
      defer { Darwin.close(descriptor) }
      let state = try directoryState(descriptor: descriptor, name: "skhd", record: record)
      let claim = try directoryState(
        descriptor: descriptor,
        name: claimName(record, directory: true),
        record: record,
        recognizeIncompleteClaim: true,
        authenticateClaim: true
      )
      guard [.managed, .original].contains(state), claim != .other else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
    case .absent, .regularFile, .symbolicLink:
      let descriptor = try PinnedFilesystem.openDirectory(at: directory)
      defer { Darwin.close(descriptor) }
      let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
      let claim = try leafState(
        descriptor: descriptor,
        name: claimName(record, directory: false),
        record: record,
        recognizeIncompleteClaim: true,
        authenticateClaim: true
      )
      let stateIsRecoverable =
        state == .managed || state == .original
        || (state == .missing && originalKind(record) == .absent)
      guard stateIsRecoverable, claim != .other else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      if originalKind(record) == .regularFile {
        if try backupExists() {
          _ = try readOriginalBackup(record, manager: manager)
        } else {
          guard record.phase == .prepared, state == .original, claim == .missing else {
            throw SetupOwnershipError.corruptBackup(backup)
          }
          try verifyPinnedUntouchedOriginal(record, manager: manager)
        }
      }
    }
  }

  func preflightManagedRestoration() throws {
    try preflightOriginalRestoration()
  }

  func finalizeOriginalRestoration() throws {
    let (record, existingRecords, context) = try ownershipRecord()
    var records = existingRecords
    try verifyOriginal(record, context: context)
    let manager = SetupOwnershipManager()
    records.removeAll { $0.id == KeybindingProviderInspector.ownershipID }
    try manager.persist(records: records, context: context)
    if originalKind(record) == .regularFile {
      try removeBackupIfPresent(unsafe: .corruptBackup(backup))
    }
  }

  func finalizeCompletedTeardownResidue() throws {
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let records = try manager.readRecords(context: context)
    guard !records.contains(where: { $0.id == KeybindingProviderInspector.ownershipID }) else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    try preflightCompletedRestorationResidue()
    try removeBackupIfPresent(unsafe: .corruptBackup(backup))
  }

  func preflightCompletedRestorationResidue() throws {
    if try backupExists() {
      let parent = try openBackupDirectory(create: false)
      defer { Darwin.close(parent) }
      let metadata = try PinnedFilesystem.metadata(
        parentDescriptor: parent,
        name: backup.lastPathComponent,
        url: backup
      )
      guard metadata.st_mode & S_IFMT == S_IFREG else {
        throw SetupOwnershipError.corruptBackup(backup)
      }
    }
    let configuration = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(configuration) }
    try requireAbsent(
      parentDescriptor: configuration,
      name: ".skhd.macarchy-keybindings",
      url: configurationDirectory.appending(path: ".skhd.macarchy-keybindings")
    )
    let directoryMetadata = try PinnedFilesystem.metadata(
      parentDescriptor: configuration,
      name: "skhd",
      url: directory
    )
    if directoryMetadata.st_mode & S_IFMT == S_IFDIR {
      let directoryDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: configuration,
        name: "skhd",
        url: directory
      )
      defer { Darwin.close(directoryDescriptor) }
      try requireAbsent(
        parentDescriptor: directoryDescriptor,
        name: ".skhdrc.macarchy-keybindings",
        url: directory.appending(path: ".skhdrc.macarchy-keybindings")
      )
    }
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
      let source = try PinnedFilesystem.readRegularFile(
        parentDescriptor: targetDescriptor,
        name: "skhdrc",
        url: target.appending(path: "skhdrc"),
        maximumSize: SetupOwnershipManager.maximumConfigurationSize
      )
      let sourceMetadata = try PinnedFilesystem.metadata(
        parentDescriptor: targetDescriptor,
        name: "skhdrc",
        url: target.appending(path: "skhdrc")
      )
      guard sourceMetadata.st_mode & S_IFMT == S_IFREG, sourceMetadata.st_nlink == 1 else {
        throw SetupOwnershipError.ownershipDrift(target.appending(path: "skhdrc"))
      }
      return OriginalEntry(
        kind: .directorySymbolicLink,
        data: nil,
        linkDestination: destination,
        fileMode: nil,
        metadataDigest: nil,
        fileDevice: nil,
        fileInode: nil,
        sourceDigest: sha256Digest(source.data),
        inventory: inventory.entries
      )
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
      return OriginalEntry(
        kind: .absent,
        data: nil,
        linkDestination: nil,
        fileMode: nil,
        metadataDigest: nil,
        fileDevice: nil,
        fileInode: nil,
        sourceDigest: nil,
        inventory: []
      )
    }
    switch metadata.st_mode & S_IFMT {
    case S_IFREG:
      guard metadata.st_nlink == 1 else { throw SetupOwnershipError.ownershipDrift(entry) }
      let descriptor = try manager.openPinnedRegularFile(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
        url: entry,
        label: "skhd entry"
      )
      defer { Darwin.close(descriptor) }
      let data = try manager.readPinnedRegularFile(
        descriptor: descriptor,
        url: entry,
        label: "skhd entry"
      ).data
      let snapshot = try manager.regularFileSnapshot(
        descriptor: descriptor,
        url: entry,
        label: "skhd entry"
      )
      guard snapshot.linkCount == 1 else { throw SetupOwnershipError.ownershipDrift(entry) }
      guard snapshot.flags & Self.unsupportedRestorationFlags == 0 else {
        throw KeybindingsApplyError.blocked(
          "regular skhd entry uses immutable, append-only, or another unsupported restrictive flag"
        )
      }
      return OriginalEntry(
        kind: .regularFile,
        data: data,
        linkDestination: nil,
        fileMode: UInt16(metadata.st_mode & mode_t(0o7777)),
        metadataDigest: snapshot.restorableMetadataDigest(),
        fileDevice: snapshot.device,
        fileInode: snapshot.inode,
        sourceDigest: sha256Digest(data),
        inventory: []
      )
    case S_IFLNK:
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
        url: entry
      )
      let resolved = Self.resolveSymlink(destination, relativeTo: directory)
      var resolvedMetadata = stat()
      guard
        lstat(resolved.path, &resolvedMetadata) == 0,
        resolvedMetadata.st_mode & S_IFMT == S_IFREG,
        resolvedMetadata.st_nlink == 1
      else { throw SetupOwnershipError.ownershipDrift(resolved) }
      let source = try PinnedFilesystem.readRegularFile(
        at: resolved,
        maximumSize: SetupOwnershipManager.maximumConfigurationSize
      )
      _ = try manager.themeLinkState(
        id: KeybindingProviderInspector.ownershipID,
        url: entry,
        target: entry
      )
      return OriginalEntry(
        kind: .symbolicLink,
        data: nil,
        linkDestination: destination,
        fileMode: nil,
        metadataDigest: nil,
        fileDevice: nil,
        fileInode: nil,
        sourceDigest: sha256Digest(source.data),
        inventory: []
      )
    default:
      throw SetupOwnershipError.ownershipDrift(entry)
    }
  }

  private func captureApprovedOriginal(
    expectedEvidence: KeybindingAdoptionEvidence,
    approvedEvidenceDigest: String?
  ) throws -> OriginalEntry {
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let records = try manager.readRecords(context: context)
    guard !records.contains(where: { $0.id == KeybindingProviderInspector.ownershipID }) else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    let original = try captureOriginal(manager: manager)
    guard original.evidence == expectedEvidence else {
      throw KeybindingsApplyError.blocked(
        "skhd adoption evidence changed after preview; review the new plan"
      )
    }
    if original.kind == .absent {
      guard approvedEvidenceDigest == nil else {
        throw KeybindingsApplyError.blocked("clean installation does not accept adoption evidence")
      }
    } else {
      guard approvedEvidenceDigest == expectedEvidence.digest else {
        throw KeybindingsApplyError.blocked(
          "--adopt must equal the exact adoption evidence digest from the reviewed plan"
        )
      }
    }
    guard try backupExists() == false else {
      throw SetupOwnershipError.orphanedBackup(backup)
    }
    try requireInstallClaimAbsent(for: original)
    return original
  }

  private func requireInstallClaimAbsent(for original: OriginalEntry) throws {
    let parent: Int32
    let name: String
    let url: URL
    if original.kind == .directorySymbolicLink {
      parent = try PinnedFilesystem.openDirectory(at: configurationDirectory)
      name = ".skhd.macarchy-keybindings"
      url = configurationDirectory.appending(path: name)
    } else {
      parent = try PinnedFilesystem.openDirectory(at: directory)
      name = ".skhdrc.macarchy-keybindings"
      url = directory.appending(path: name)
    }
    defer { Darwin.close(parent) }
    try requireAbsent(parentDescriptor: parent, name: name, url: url)
  }

  private func requireLegacyClaimAbsent(for record: SetupOwnershipRecord) throws {
    let parent: Int32
    let name: String
    let url: URL
    if originalKind(record) == .directorySymbolicLink {
      parent = try PinnedFilesystem.openDirectory(at: configurationDirectory)
      name = ".skhd.macarchy-keybindings"
      url = configurationDirectory.appending(path: name)
    } else {
      parent = try PinnedFilesystem.openDirectory(at: directory)
      name = ".skhdrc.macarchy-keybindings"
      url = directory.appending(path: name)
    }
    defer { Darwin.close(parent) }
    try requireAbsent(parentDescriptor: parent, name: name, url: url)
  }

  private func requireAbsent(parentDescriptor: Int32, name: String, url: URL) throws {
    do {
      _ = try PinnedFilesystem.metadata(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
      throw SetupOwnershipError.ownershipDrift(url)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
  }

  private func ensureRegularBackup(
    _ record: SetupOwnershipRecord,
    manager: SetupOwnershipManager
  ) throws {
    guard originalKind(record) == .regularFile else { return }
    if try backupExists() {
      _ = try readOriginalBackup(record, manager: manager)
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
    try writeOriginalBackup(data, record: record, manager: manager)
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
    let claim = claimName(record, directory: false)
    let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
    var claimState = try leafState(
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true,
      authenticateClaim: true
    )
    if claimState == .incomplete {
      try unlink(descriptor: descriptor, name: claim, url: entry)
      claimState = .missing
    }
    if state == .managed {
      if claimState == .original { try unlink(descriptor: descriptor, name: claim, url: entry) }
      guard claimState == .missing || claimState == .original else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      return
    }
    if state == .original, claimState == .managed {
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try markClaim(parentDescriptor: descriptor, name: claim, record: record, url: entry)
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
      url: entry,
      record: record
    )
    if state == .missing {
      try rename(descriptor: descriptor, from: claim, to: "skhdrc", url: entry)
    } else {
      if originalKind(record) == .regularFile {
        try verifyOriginalMatchesBackup(record, descriptor: descriptor)
      }
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try markClaim(parentDescriptor: descriptor, name: claim, record: record, url: entry)
      guard
        try leafState(
          descriptor: descriptor,
          name: claim,
          record: record,
          authenticateClaim: true
        ) == .original
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
    let claim = claimName(record, directory: false)
    let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
    var claimState = try leafState(
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true,
      authenticateClaim: true
    )
    if claimState == .incomplete {
      try unlink(descriptor: descriptor, name: claim, url: entry)
      claimState = .missing
    }
    if state == .original || (state == .missing && originalKind(record) == .absent) {
      if claimState == .managed { try unlink(descriptor: descriptor, name: claim, url: entry) }
      guard claimState == .missing || claimState == .managed else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      return
    }
    if state == .managed, claimState == .original {
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try removeClaimMarker(
        parentDescriptor: descriptor,
        name: "skhdrc",
        record: record,
        url: entry
      )
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
      try restoreRegularFileClaim(record, descriptor: descriptor, name: claim)
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try unlink(descriptor: descriptor, name: claim, url: entry)
    case .symbolicLink:
      try createSymlink(
        descriptor: descriptor,
        name: claim,
        destination: try originalLink(record),
        url: entry,
        record: record
      )
      try removeClaimMarker(parentDescriptor: descriptor, name: claim, record: record, url: entry)
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
    let claim = claimName(record, directory: true)
    let state = try directoryState(descriptor: descriptor, name: "skhd", record: record)
    var claimState = try directoryState(
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true,
      authenticateClaim: true
    )
    if claimState == .incomplete {
      try createManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
      claimState = try directoryState(
        descriptor: descriptor,
        name: claim,
        record: record,
        authenticateClaim: true
      )
    }
    if state == .managed {
      if claimState == .original {
        try unlink(descriptor: descriptor, name: claim, url: directory)
      }
      guard claimState == .missing || claimState == .original else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
      return
    }
    if state == .original, claimState == .managed {
      try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
      try markClaim(parentDescriptor: descriptor, name: claim, record: record, url: directory)
      try unlink(descriptor: descriptor, name: claim, url: directory)
      return
    }
    guard state == .original, claimState == .missing else {
      throw SetupOwnershipError.ownershipDrift(directory)
    }
    try createManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
    try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
    try markClaim(parentDescriptor: descriptor, name: claim, record: record, url: directory)
    guard
      try directoryState(
        descriptor: descriptor,
        name: claim,
        record: record,
        authenticateClaim: true
      ) == .original
    else { throw SetupOwnershipError.ownershipDrift(directory) }
    try unlink(descriptor: descriptor, name: claim, url: directory)
  }

  private func restoreOriginalDirectory(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(descriptor) }
    let claim = claimName(record, directory: true)
    let state = try directoryState(descriptor: descriptor, name: "skhd", record: record)
    var claimState = try directoryState(
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true,
      authenticateClaim: true
    )
    if claimState == .incomplete {
      try removeManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
      claimState = .missing
    }
    if state == .original {
      if claimState == .managed {
        try removeManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
      }
      guard claimState == .missing || claimState == .managed else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
      return
    }
    if state == .managed, claimState == .original {
      try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
      try removeClaimMarker(
        parentDescriptor: descriptor,
        name: "skhd",
        record: record,
        url: directory
      )
      try removeManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
      return
    }
    guard state == .managed, claimState == .missing else {
      throw SetupOwnershipError.ownershipDrift(directory)
    }
    try createSymlink(
      descriptor: descriptor,
      name: claim,
      destination: try originalLink(record),
      url: directory,
      record: record
    )
    try removeClaimMarker(parentDescriptor: descriptor, name: claim, record: record, url: directory)
    try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
    try removeManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
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
    record: SetupOwnershipRecord,
    recognizeIncompleteClaim: Bool = false,
    authenticateClaim: Bool = false
  ) throws -> ProviderItemState {
    let url = directory.appending(path: name)
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(parentDescriptor: descriptor, name: name, url: url)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .missing
    }
    if authenticateClaim,
      try !claimMarkerMatches(
        parentDescriptor: descriptor,
        name: name,
        record: record,
        url: url
      )
    {
      return .other
    }
    switch metadata.st_mode & S_IFMT {
    case S_IFLNK:
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: descriptor,
        name: name,
        url: url
      )
      if destination == KeybindingProviderInspector.managedTarget {
        return try claimMarkerMatches(
          parentDescriptor: descriptor,
          name: name,
          record: record,
          url: url
        ) ? .managed : .other
      }
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
      if sha256Digest(data) == record.originalDigest { return .original }
      return recognizeIncompleteClaim ? .incomplete : .other
    default:
      return .other
    }
  }

  private func directoryState(
    descriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    recognizeIncompleteClaim: Bool = false,
    authenticateClaim: Bool = false
  ) throws -> ProviderItemState {
    let url = configurationDirectory.appending(path: name)
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(parentDescriptor: descriptor, name: name, url: url)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .missing
    }
    if authenticateClaim,
      try !claimMarkerMatches(
        parentDescriptor: descriptor,
        name: name,
        record: record,
        url: url
      )
    {
      return .other
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
    guard
      try claimMarkerMatches(
        parentDescriptor: descriptor,
        name: name,
        record: record,
        url: url
      )
    else { return .other }
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
    if inventory.entries.isEmpty, !inventory.truncated, recognizeIncompleteClaim {
      return .incomplete
    }
    guard inventory.entries == ["skhdrc"], !inventory.truncated else { return .other }
    let target = try PinnedFilesystem.symlinkDestination(
      parentDescriptor: directoryDescriptor,
      name: "skhdrc",
      url: url.appending(path: "skhdrc")
    )
    return target == KeybindingProviderInspector.managedTarget ? .managed : .other
  }

  private func createManagedDirectory(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord
  ) throws {
    let url = configurationDirectory.appending(path: name, directoryHint: .isDirectory)
    let descriptor: Int32
    let created: Bool
    do {
      descriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
      created = false
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      descriptor = try PinnedFilesystem.createDirectory(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
      created = true
    }
    defer { Darwin.close(descriptor) }
    if created {
      try markClaim(
        descriptor: descriptor,
        parentDescriptor: parentDescriptor,
        name: name,
        record: record,
        url: url
      )
      try faultInjector(.directoryClaimCreated)
    } else {
      guard
        try claimMarkerMatches(
          descriptor: descriptor,
          record: record,
          url: url
        )
      else { throw SetupOwnershipError.ownershipDrift(url) }
    }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor,
      url: url,
      limit: 2
    )
    if inventory.entries == ["skhdrc"], !inventory.truncated {
      guard
        try leafState(
          descriptor: descriptor,
          name: "skhdrc",
          record: record
        ) == .managed
      else { throw SetupOwnershipError.ownershipDrift(url) }
      return
    }
    guard inventory.entries.isEmpty, !inventory.truncated else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    try createSymlink(
      descriptor: descriptor,
      name: "skhdrc",
      destination: KeybindingProviderInspector.managedTarget,
      url: url.appending(path: "skhdrc"),
      record: record
    )
    try faultInjector(.directoryClaimPopulated)
  }

  private func writeOriginalBackup(
    _ data: Data,
    record: SetupOwnershipRecord,
    manager: SetupOwnershipManager
  ) throws {
    guard sha256Digest(data) == record.originalDigest else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    let sourceParent = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(sourceParent) }
    let source = try manager.openPinnedRegularFile(
      parentDescriptor: sourceParent,
      name: "skhdrc",
      url: entry,
      label: "skhd entry"
    )
    defer { Darwin.close(source) }
    let sourceData = try manager.readPinnedRegularFile(
      descriptor: source,
      url: entry,
      label: "skhd entry"
    )
    guard sourceData.data == data else { throw SetupOwnershipError.ownershipDrift(entry) }
    let sourceSnapshot = try manager.regularFileSnapshot(
      descriptor: source,
      url: entry,
      label: "skhd entry"
    )
    guard
      sourceSnapshot.device == record.originalDevice,
      sourceSnapshot.inode == record.originalInode,
      sourceSnapshot.linkCount == 1,
      sourceSnapshot.flags & Self.unsupportedRestorationFlags == 0
    else { throw SetupOwnershipError.ownershipDrift(entry) }

    let backupParent = try openBackupDirectory(create: true)
    defer { Darwin.close(backupParent) }
    let temporaryName = ".keybindings-skhdrc-\(UUID().uuidString.lowercased())"
    let temporaryURL = backup.deletingLastPathComponent().appending(path: temporaryName)
    let temporary = temporaryName.withCString {
      Darwin.openat(
        backupParent,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
    }
    guard temporary >= 0 else { throw posixError("create keybinding backup", temporaryURL) }
    defer { Darwin.close(temporary) }
    var published = false
    defer {
      if !published {
        temporaryName.withCString { _ = Darwin.unlinkat(backupParent, $0, 0) }
      }
    }
    try manager.write(
      data,
      descriptor: temporary,
      url: temporaryURL,
      operation: "write keybinding backup"
    )
    guard fcopyfile(source, temporary, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
      throw posixError("copy keybinding backup metadata", temporaryURL)
    }
    guard fsync(temporary) == 0 else { throw posixError("sync keybinding backup", temporaryURL) }
    let snapshot = try manager.regularFileSnapshot(
      descriptor: temporary,
      url: temporaryURL,
      label: "keybinding backup"
    )
    guard snapshot.hasCopiedMetadata(from: sourceSnapshot) else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    guard fchmod(temporary, mode_t(0o600)) == 0 else {
      throw posixError("secure keybinding backup", temporaryURL)
    }
    guard fsync(temporary) == 0 else { throw posixError("sync keybinding backup", temporaryURL) }
    guard
      snapshot.restorableMetadataDigest() == record.originalMetadataDigest,
      try manager.regularFileSnapshot(
        descriptor: temporary,
        url: temporaryURL,
        label: "keybinding backup"
      ).restorableMetadataDigest(overridingMode: try originalMode(record))
        == record.originalMetadataDigest
    else { throw SetupOwnershipError.ownershipDrift(entry) }
    let publication = temporaryName.withCString { sourceName in
      backup.lastPathComponent.withCString { destination in
        Darwin.renameatx_np(
          backupParent,
          sourceName,
          backupParent,
          destination,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard publication == 0 else { throw posixError("publish keybinding backup", backup) }
    published = true
    try sync(backupParent, url: backup.deletingLastPathComponent())
    _ = try readOriginalBackup(record, manager: manager)
  }

  private func readOriginalBackup(
    _ record: SetupOwnershipRecord,
    manager: SetupOwnershipManager
  ) throws -> (data: Data, snapshot: SetupOwnershipManager.RegularFileSnapshot) {
    let parent = try openBackupDirectory(create: false)
    defer { Darwin.close(parent) }
    let descriptor = try manager.openPinnedRegularFile(
      parentDescriptor: parent,
      name: backup.lastPathComponent,
      url: backup,
      label: "keybinding backup"
    )
    defer { Darwin.close(descriptor) }
    let file = try manager.readPinnedRegularFile(
      descriptor: descriptor,
      url: backup,
      label: "keybinding backup"
    )
    let snapshot = try manager.regularFileSnapshot(
      descriptor: descriptor,
      url: backup,
      label: "keybinding backup"
    )
    guard
      file.permissions == 0o600,
      sha256Digest(file.data) == record.originalDigest,
      snapshot.restorableMetadataDigest(overridingMode: try originalMode(record))
        == record.originalMetadataDigest
    else {
      throw SetupOwnershipError.corruptBackup(backup)
    }
    return (file.data, snapshot)
  }

  private func verifyOriginalMatchesBackup(
    _ record: SetupOwnershipRecord,
    descriptor: Int32
  ) throws {
    let manager = SetupOwnershipManager()
    let current = try manager.openPinnedRegularFile(
      parentDescriptor: descriptor,
      name: "skhdrc",
      url: entry,
      label: "skhd entry"
    )
    defer { Darwin.close(current) }
    let stored = try readOriginalBackup(record, manager: manager)
    let currentData = try manager.readPinnedRegularFile(
      descriptor: current,
      url: entry,
      label: "skhd entry"
    ).data
    let currentSnapshot = try manager.regularFileSnapshot(
      descriptor: current,
      url: entry,
      label: "skhd entry"
    )
    let matchesPinnedPreparedOriginal =
      record.phase != .prepared
      || (currentSnapshot.device == record.originalDevice
        && currentSnapshot.inode == record.originalInode)
    guard
      currentData == stored.data,
      matchesPinnedPreparedOriginal,
      currentSnapshot.linkCount == 1,
      currentSnapshot.flags & Self.unsupportedRestorationFlags == 0,
      currentSnapshot.mode & 0o7777 == UInt32(try originalMode(record)),
      currentSnapshot.hasCopiedMetadataIgnoringMode(from: stored.snapshot),
      currentSnapshot.restorableMetadataDigest() == record.originalMetadataDigest
    else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
  }

  private func restoreRegularFileClaim(
    _ record: SetupOwnershipRecord,
    descriptor: Int32,
    name: String
  ) throws {
    let manager = SetupOwnershipManager()
    let stored = try readOriginalBackup(record, manager: manager)
    let claimURL = directory.appending(path: name)
    let claim = name.withCString {
      Darwin.openat(
        descriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
    }
    guard claim >= 0 else { throw posixError("create restored skhd entry", claimURL) }
    defer { Darwin.close(claim) }
    try markClaim(
      descriptor: claim,
      parentDescriptor: descriptor,
      name: name,
      record: record,
      url: claimURL
    )
    var cleanup = true
    defer {
      if cleanup { name.withCString { _ = Darwin.unlinkat(descriptor, $0, 0) } }
    }
    do {
      try faultInjector(.regularRestorationClaimCreated)
    } catch {
      cleanup = false
      throw error
    }
    try manager.write(
      stored.data,
      descriptor: claim,
      url: claimURL,
      operation: "write restored skhd entry"
    )
    do {
      try faultInjector(.regularRestorationClaimWritten)
    } catch {
      cleanup = false
      throw error
    }
    let backupParent = try openBackupDirectory(create: false)
    defer { Darwin.close(backupParent) }
    let backupDescriptor = try manager.openPinnedRegularFile(
      parentDescriptor: backupParent,
      name: backup.lastPathComponent,
      url: backup,
      label: "keybinding backup"
    )
    defer { Darwin.close(backupDescriptor) }
    guard fcopyfile(backupDescriptor, claim, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
      throw posixError("restore skhd entry metadata", claimURL)
    }
    guard fchmod(claim, mode_t(try originalMode(record))) == 0 else {
      throw posixError("restore skhd entry permissions", claimURL)
    }
    if try !claimMarkerMatches(descriptor: claim, record: record, url: claimURL) {
      try markClaim(
        descriptor: claim,
        parentDescriptor: descriptor,
        name: name,
        record: record,
        url: claimURL
      )
    }
    do {
      try faultInjector(.regularRestorationClaimMetadataCopied)
    } catch {
      cleanup = false
      throw error
    }
    try removeClaimMarker(
      descriptor: claim,
      parentDescriptor: descriptor,
      name: name,
      record: record,
      url: claimURL
    )
    guard fsync(claim) == 0 else { throw posixError("sync restored skhd entry", claimURL) }
    let restoredSnapshot = try manager.regularFileSnapshot(
      descriptor: claim,
      url: claimURL,
      label: "restored skhd entry"
    )
    guard
      restoredSnapshot.mode & 0o7777 == UInt32(try originalMode(record)),
      restoredSnapshot.hasCopiedMetadataIgnoringMode(from: stored.snapshot),
      restoredSnapshot.restorableMetadataDigest() == record.originalMetadataDigest
    else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    cleanup = false
  }

  private func removeManagedDirectory(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord
  ) throws {
    let url = configurationDirectory.appending(path: name, directoryHint: .isDirectory)
    let descriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    defer { Darwin.close(descriptor) }
    guard
      try claimMarkerMatches(descriptor: descriptor, record: record, url: url)
    else { throw SetupOwnershipError.ownershipDrift(url) }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor,
      url: url,
      limit: 2
    )
    guard !inventory.truncated else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    if inventory.entries == ["skhdrc"] {
      guard
        try leafState(
          descriptor: descriptor,
          name: "skhdrc",
          record: record
        ) == .managed
      else {
        throw SetupOwnershipError.ownershipDrift(url)
      }
      try unlink(descriptor: descriptor, name: "skhdrc", url: url)
      try faultInjector(.directoryClaimEntryRemoved)
    } else if !inventory.entries.isEmpty {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    guard name.withCString({ Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
      throw posixError("remove managed skhd directory", url)
    }
    try sync(parentDescriptor, url: configurationDirectory)
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

  private func originalMode(_ record: SetupOwnershipRecord) throws -> UInt16 {
    guard let mode = record.originalFileMode else {
      throw SetupOwnershipError.invalidManifest("keybinding adoption file mode is missing")
    }
    return mode
  }

  private func claimName(_ record: SetupOwnershipRecord, directory: Bool) -> String {
    let prefix = directory ? ".skhd.macarchy-keybindings" : ".skhdrc.macarchy-keybindings"
    return "\(prefix)-\(record.claimNonce ?? "invalid")"
  }

  private func verifyPinnedUntouchedOriginal(
    _ record: SetupOwnershipRecord,
    manager: SetupOwnershipManager
  ) throws {
    let parent = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(parent) }
    let descriptor = try manager.openPinnedRegularFile(
      parentDescriptor: parent,
      name: "skhdrc",
      url: entry,
      label: "skhd entry"
    )
    defer { Darwin.close(descriptor) }
    let data = try manager.readPinnedRegularFile(
      descriptor: descriptor,
      url: entry,
      label: "skhd entry"
    ).data
    let snapshot = try manager.regularFileSnapshot(
      descriptor: descriptor,
      url: entry,
      label: "skhd entry"
    )
    guard
      sha256Digest(data) == record.originalDigest,
      snapshot.device == record.originalDevice,
      snapshot.inode == record.originalInode,
      snapshot.linkCount == 1,
      snapshot.flags & Self.unsupportedRestorationFlags == 0,
      snapshot.restorableMetadataDigest() == record.originalMetadataDigest
    else { throw SetupOwnershipError.ownershipDrift(entry) }
  }

  private func backupExists() throws -> Bool {
    let parent: Int32
    do {
      parent = try openBackupDirectory(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return false
    }
    defer { Darwin.close(parent) }
    do {
      _ = try PinnedFilesystem.metadata(
        parentDescriptor: parent,
        name: backup.lastPathComponent,
        url: backup
      )
      return true
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return false
    }
  }

  private func removeBackupIfPresent(unsafe error: SetupOwnershipError) throws {
    let parent: Int32
    do {
      parent = try openBackupDirectory(create: false)
    } catch let caught as PinnedFilesystemError where caught.code == ENOENT {
      return
    }
    defer { Darwin.close(parent) }
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: parent,
        name: backup.lastPathComponent,
        url: backup
      )
    } catch let caught as PinnedFilesystemError where caught.code == ENOENT {
      return
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else { throw error }
    guard backup.lastPathComponent.withCString({ Darwin.unlinkat(parent, $0, 0) }) == 0 else {
      throw posixError("remove keybinding backup", backup)
    }
    try sync(parent, url: backup.deletingLastPathComponent())
  }

  private func openBackupDirectory(create: Bool) throws -> Int32 {
    let configuration = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(configuration) }
    var parent = try PinnedFilesystem.openDirectory(
      parentDescriptor: configuration,
      name: "macarchy",
      url: homeDirectory.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    )
    let components = ["state", "setup", "backups"]
    var currentURL = homeDirectory.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    for component in components {
      currentURL.append(path: component, directoryHint: .isDirectory)
      let next: Int32
      do {
        next = try PinnedFilesystem.openDirectory(
          parentDescriptor: parent,
          name: component,
          url: currentURL
        )
      } catch let error as PinnedFilesystemError where error.code == ENOENT && create {
        next = try PinnedFilesystem.createDirectory(
          parentDescriptor: parent,
          name: component,
          url: currentURL,
          mode: 0o700
        )
      }
      Darwin.close(parent)
      parent = next
    }
    return parent
  }

  private func createSymlink(
    descriptor: Int32,
    name: String,
    destination: String,
    url: URL,
    record: SetupOwnershipRecord
  ) throws {
    let result = destination.withCString { target in
      name.withCString { Darwin.symlinkat(target, descriptor, $0) }
    }
    guard result == 0 else { throw posixError("create keybinding provider link", url) }
    try markClaim(parentDescriptor: descriptor, name: name, record: record, url: url)
    try sync(descriptor, url: url.deletingLastPathComponent())
  }

  private func claimMarkerMatches(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws -> Bool {
    let descriptor = try openClaim(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    defer { Darwin.close(descriptor) }
    return try claimMarkerMatches(descriptor: descriptor, record: record, url: url)
  }

  private func claimMarkerMatches(
    descriptor: Int32,
    record: SetupOwnershipRecord,
    url: URL
  ) throws -> Bool {
    guard let nonce = record.claimNonce else {
      throw SetupOwnershipError.invalidManifest("keybinding claim nonce is missing")
    }
    var value = [UInt8](repeating: 0, count: 64)
    let count = Self.claimMarkerAttribute.withCString {
      Darwin.fgetxattr(descriptor, $0, &value, value.count, 0, 0)
    }
    if count < 0, errno == ENOATTR { return false }
    guard count >= 0 else { throw posixError("read keybinding claim marker", url) }
    return Data(value.prefix(count)) == Data(nonce.utf8)
  }

  private func markClaim(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    let descriptor = try openClaim(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    defer { Darwin.close(descriptor) }
    try markClaim(
      descriptor: descriptor,
      parentDescriptor: parentDescriptor,
      name: name,
      record: record,
      url: url
    )
  }

  private func markClaim(
    descriptor: Int32,
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    guard let nonce = record.claimNonce else {
      throw SetupOwnershipError.invalidManifest("keybinding claim nonce is missing")
    }
    let result = Data(nonce.utf8).withUnsafeBytes { value in
      Self.claimMarkerAttribute.withCString {
        Darwin.fsetxattr(descriptor, $0, value.baseAddress, value.count, 0, XATTR_CREATE)
      }
    }
    guard result == 0 else { throw posixError("authenticate keybinding claim", url) }
    guard fsync(descriptor) == 0 else { throw posixError("sync keybinding claim", url) }
    try sync(parentDescriptor, url: url.deletingLastPathComponent())
  }

  private func removeClaimMarker(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    let descriptor = try openClaim(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    defer { Darwin.close(descriptor) }
    try removeClaimMarker(
      descriptor: descriptor,
      parentDescriptor: parentDescriptor,
      name: name,
      record: record,
      url: url
    )
  }

  private func removeClaimMarker(
    descriptor: Int32,
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    guard try claimMarkerMatches(descriptor: descriptor, record: record, url: url) else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    let result = Self.claimMarkerAttribute.withCString {
      Darwin.fremovexattr(descriptor, $0, 0)
    }
    guard result == 0 else { throw posixError("remove keybinding claim marker", url) }
    guard fsync(descriptor) == 0 else { throw posixError("sync keybinding claim", url) }
    try sync(parentDescriptor, url: url.deletingLastPathComponent())
  }

  private func openClaim(parentDescriptor: Int32, name: String, url: URL) throws -> Int32 {
    let metadata = try PinnedFilesystem.metadata(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    let flags: Int32
    switch metadata.st_mode & S_IFMT {
    case S_IFDIR:
      flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    case S_IFLNK:
      flags = O_RDONLY | O_SYMLINK | O_CLOEXEC
    default:
      flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    }
    let descriptor = name.withCString { Darwin.openat(parentDescriptor, $0, flags) }
    guard descriptor >= 0 else { throw posixError("open pinned keybinding claim", url) }
    var pinned = stat()
    guard
      fstat(descriptor, &pinned) == 0,
      pinned.st_dev == metadata.st_dev,
      pinned.st_ino == metadata.st_ino,
      pinned.st_mode & S_IFMT == metadata.st_mode & S_IFMT
    else {
      Darwin.close(descriptor)
      throw SetupOwnershipError.ownershipDrift(url)
    }
    return descriptor
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
  let fileMode: UInt16?
  let metadataDigest: String?
  let fileDevice: UInt64?
  let fileInode: UInt64?
  let sourceDigest: String?
  let inventory: [String]

  var evidence: KeybindingAdoptionEvidence {
    let evidenceKind: KeybindingAdoptionEvidence.Kind =
      switch kind {
      case .absent: .absent
      case .directorySymbolicLink: .directorySymbolicLink
      case .regularFile: .regularFile
      case .symbolicLink: .symbolicLink
      }
    return KeybindingAdoptionEvidence(
      kind: evidenceKind,
      linkDestination: linkDestination,
      contentDigest: sourceDigest,
      inventory: inventory
    )
  }

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
      originalLinkDestination: linkDestination,
      originalFileMode: fileMode,
      originalMetadataDigest: metadataDigest,
      originalDevice: fileDevice,
      originalInode: fileInode,
      claimNonce: UUID().uuidString.lowercased()
    )
  }
}

private enum ProviderItemState: Equatable {
  case incomplete
  case managed
  case missing
  case original
  case other
}
