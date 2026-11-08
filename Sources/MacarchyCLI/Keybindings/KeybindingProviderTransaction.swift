import Darwin
import Foundation
import ThemeCore

enum KeybindingProviderCheckpoint: Equatable, Sendable {
  case manifestPrepared
  case regularPathInspected
  case regularCaptureReady
  case backupPublicationAuthenticated
  case backupPublicationReady
  case backupWritten
  case directoryClaimCreated
  case directoryClaimPopulated
  case directoryClaimEntryRemoved
  case regularRestorationClaimCreated
  case regularRestorationClaimWritten
  case regularRestorationClaimMetadataCopied
  case providerClaimReady
  case providerClaimSwapped
  case sourceSwapCompleted
  case regularOriginalPinned
  case providerPublicationAuthenticated
  case restoredOriginalPublished
  case restoredIdentityRecorded
  case backupRemoved
  case managedEntryClaimedForRemoval
  case deletionSourcePinned
  case deletionCandidatePublished
  case deletionCandidateAuthenticated
  case legacyRestorationPublicationCreated
  case providerReplaced
  case originalRestored
}

/// Works on the canonical per-user state root under `homeDirectory`. Keybinding apply refuses any
/// other `--state-root` before it gets here (`KeybindingsApplyCommandRunner.isCanonicalStateRoot`).
struct KeybindingProviderTransaction: Sendable {
  static let unsupportedRestorationFlags =
    UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(UF_DATAVAULT)
    | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND) | UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK)

  let layout: SkhdLayout
  let faultInjector: @Sendable (KeybindingProviderCheckpoint) throws -> Void

  init(
    homeDirectory: URL,
    faultInjector: @escaping @Sendable (KeybindingProviderCheckpoint) throws -> Void = { _ in }
  ) {
    layout = SkhdLayout(home: homeDirectory)
    self.faultInjector = faultInjector
  }

  var homeDirectory: URL { layout.home }
  var configurationDirectory: URL { layout.configurationDirectory }
  var directory: URL { layout.directory }
  var entry: URL { layout.entry }
  var backup: URL { layout.backup }

  func preflightInstall(
    expectedEvidence: KeybindingAdoptionEvidence,
    approvedEvidenceDigest: String?
  ) throws {
    if expectedEvidence.kind == .absent, approvedEvidenceDigest == nil {
      let stateRoot = StateLayout.defaultRoot(in: homeDirectory)
      let inspection = KeybindingProviderInspector().inspect(
        homeDirectory: homeDirectory, stateRoot: stateRoot,
        generation: KeybindingGenerationInspector().inspect(stateRoot: stateRoot))
      if inspection.status == .installRequired, inspection.ownership == .absent,
        inspection.adoptionEvidence == expectedEvidence
      {
        guard try !backupExists() else { throw SetupOwnershipError.orphanedBackup(backup) }
        return
      }
    }
    let original = try captureApprovedOriginal(
      expectedEvidence: expectedEvidence,
      approvedEvidenceDigest: approvedEvidenceDigest
    )
    original.closePinnedDescriptor()
  }

  func installEntry(
    expectedEvidence: KeybindingAdoptionEvidence,
    approvedEvidenceDigest: String?
  ) throws {
    if expectedEvidence.kind == .absent {
      try preflightInstall(
        expectedEvidence: expectedEvidence, approvedEvidenceDigest: approvedEvidenceDigest)
      let configuration = try PinnedFilesystem.openDirectory(at: configurationDirectory)
      defer { Darwin.close(configuration) }
      // Empty native configuration parents are retained, like other setup-created
      // directories. Only the provider entry is owned and removed on teardown.
      let native = try PinnedFilesystem.openOrCreateChildDirectory(
        parentDescriptor: configuration, name: SkhdLayout.directoryName, url: directory)
      Darwin.close(native)
    }
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
    defer { original.closePinnedDescriptor() }
    let record = try original.record(layout: layout, manager: manager, context: context)
    do {
      try faultInjector(.regularCaptureReady)
      try revalidateCapturedRegularOriginal(original, manager: manager)
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
    if KeybindingProviderInspector.isLegacyCleanInstallRecord(record) {
      try removeLegacyManagedEntry(record)
      try faultInjector(.originalRestored)
      return
    }
    try restoreOriginal(record, context: context)
    try faultInjector(.originalRestored)
  }

  func restoreManagedEntry() throws {
    let (record, _, _) = try ownershipRecord()
    if KeybindingProviderInspector.isLegacyCleanInstallRecord(record) {
      try restoreLegacyManagedEntry(record)
      return
    }
    try replaceOriginalWithManaged(record)
  }

  func preflightOriginalRestoration() throws {
    let (record, _, _) = try ownershipRecord()
    if KeybindingProviderInspector.isLegacyCleanInstallRecord(record) {
      try preflightLegacyCleanInstall(record)
      return
    }
    let manager = SetupOwnershipManager()
    let level = claimLevel(record)
    try requireLegacyClaimAbsent(level)
    let liveName = SkhdLayout.liveName(level)
    let live = layout.live(level)
    let descriptor = try PinnedFilesystem.openDirectory(at: layout.parent(level))
    defer { Darwin.close(descriptor) }
    let state = try itemState(level, descriptor: descriptor, name: liveName, record: record)
    let claim = try itemState(
      level,
      descriptor: descriptor,
      name: claimName(record, level),
      record: record,
      recognizeIncompleteClaim: true
    )
    let stateIsRecoverable =
      state == .managed || state == .original
      || (state == .missing && originalKind(record) == .absent)
    let retainedStateIsRecoverable =
      !retainsOriginalSymlink(record)
      || (state == .managed && claim == .original)
      || (state == .original && claim == .managed)
    guard stateIsRecoverable, claim != .other, retainedStateIsRecoverable else {
      throw SetupOwnershipError.ownershipDrift(live)
    }
    if retainsOriginalSymlink(record) {
      if state == .managed {
        try preflightRetainedOriginalClaim(record)
      } else {
        try authenticateOriginalSymlinkAtPath(
          record,
          parentDescriptor: descriptor,
          name: liveName,
          url: live
        )
      }
    }
    if originalKind(record) == .regularFile {
      _ = try validateBackupPublicationResidue(record, manager: manager)
      if try backupExists() {
        _ = try readOriginalBackup(record, manager: manager)
      } else {
        guard
          [.prepared, .teardownPrepared].contains(record.phase),
          state == .original,
          claim == .missing
        else {
          throw SetupOwnershipError.corruptBackup(backup)
        }
        try verifyPinnedUntouchedOriginal(record, manager: manager)
      }
    }
  }

  func preflightOriginalRestorationFinalization() throws {
    let (record, _, context) = try ownershipRecord()
    guard retainsOriginalSymlink(record) else {
      try preflightOriginalRestoration()
      return
    }
    let level = claimLevel(record)
    try requireLegacyClaimAbsent(level)
    try verifyOriginal(record, context: context)
    let parentURL = layout.parent(level)
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    let claim = claimName(record, level)
    let claimState = try itemState(level, descriptor: parent, name: claim, record: record)
    let deletionResidueExists = try preflightProviderDeletionResidue(
      parentDescriptor: parent,
      name: claim,
      record: record,
      url: parentURL.appending(path: claim),
      directory: level == .directory
    )
    guard
      (claimState == .managed && !deletionResidueExists)
        || (claimState == .missing)
    else {
      throw SetupOwnershipError.ownershipDrift(parentURL.appending(path: claim))
    }
  }

  func preflightRetainedOriginalClaim(_ record: SetupOwnershipRecord) throws {
    guard retainsOriginalSymlink(record) else { return }
    let level = claimLevel(record)
    let parentURL = layout.parent(level)
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    let name = claimName(record, level)
    let url = parentURL.appending(path: name)
    guard record.retainedOriginalPath == url.path else {
      throw SetupOwnershipError.invalidManifest(
        "retained keybinding original is not bound to its authenticated claim path"
      )
    }
    try authenticateOriginalSymlinkAtPath(
      record,
      parentDescriptor: parent,
      name: name,
      url: url
    )
  }

  func finalizeOriginalRestoration() throws {
    var (record, existingRecords, context) = try ownershipRecord()
    var records = existingRecords
    if KeybindingProviderInspector.isLegacyCleanInstallRecord(record) {
      let descriptor = try PinnedFilesystem.openDirectory(at: directory)
      defer { Darwin.close(descriptor) }
      try removeLegacyRestorationResidue(parentDescriptor: descriptor, record: record)
      try requireLegacyEntryAbsent()
      records.removeAll { $0.id == KeybindingProviderInspector.ownershipID }
      try SetupOwnershipManager().persist(records: records, context: context)
      return
    }
    try verifyOriginal(record, context: context)
    let manager = SetupOwnershipManager()
    if originalKind(record) == .regularFile {
      let backupPublicationExists =
        try validateBackupPublicationResidue(record, manager: manager) != nil
      if try backupExists() || backupDeletionResidueExists(record) || backupPublicationExists {
        record.phase = .teardownPrepared
        try manager.save(record: record, records: &records, context: context)
        if try backupExists() || backupDeletionResidueExists(record) {
          try removeAuthenticatedBackup(record, manager: manager)
        }
      } else {
        guard record.phase == .prepared || record.phase == .teardownPrepared else {
          throw SetupOwnershipError.corruptBackup(backup)
        }
        if record.phase == .prepared {
          try verifyPinnedUntouchedOriginal(record, manager: manager)
        }
      }
      try removeBackupPublicationResidue(record)
    }
    try removeAuthenticatedProviderResidues(record)
    try faultInjector(.backupRemoved)
    records.removeAll { $0.id == KeybindingProviderInspector.ownershipID }
    try manager.persist(records: records, context: context)
  }

  func finalizeCompletedTeardownResidue() throws {
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let records = try manager.readRecords(context: context)
    guard !records.contains(where: { $0.id == KeybindingProviderInspector.ownershipID }) else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    try preflightCompletedRestorationResidue()
    guard try backupExists() == false else {
      throw SetupOwnershipError.orphanedBackup(backup)
    }
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
      guard metadata.st_nlink == 1 else { throw SetupOwnershipError.corruptBackup(backup) }
    }
    let configuration = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(configuration) }
    try requireAbsent(
      parentDescriptor: configuration,
      name: SkhdLayout.claimPrefix(.directory),
      url: configurationDirectory.appending(path: SkhdLayout.claimPrefix(.directory))
    )
    let directoryMetadata = try PinnedFilesystem.metadata(
      parentDescriptor: configuration,
      name: SkhdLayout.directoryName,
      url: directory
    )
    if directoryMetadata.st_mode & S_IFMT == S_IFDIR {
      let directoryDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: configuration,
        name: SkhdLayout.directoryName,
        url: directory
      )
      defer { Darwin.close(directoryDescriptor) }
      try requireAbsent(
        parentDescriptor: directoryDescriptor,
        name: SkhdLayout.claimPrefix(.leaf),
        url: directory.appending(path: SkhdLayout.claimPrefix(.leaf))
      )
      try requireAbsent(
        parentDescriptor: directoryDescriptor,
        name: SkhdLayout.legacyRestorationName,
        url: directory.appending(path: SkhdLayout.legacyRestorationName)
      )
    }
  }

  func ownershipRecord() throws -> (
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
      name: SkhdLayout.directoryName,
      url: directory
    )
    if directoryMetadata.st_mode & S_IFMT == S_IFLNK {
      try KeybindingProviderInspector.requireAdoptableSymlink(
        directoryMetadata,
        parentDescriptor: configurationDescriptor,
        name: SkhdLayout.directoryName,
        url: directory
      )
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: configurationDescriptor,
        name: SkhdLayout.directoryName,
        url: directory
      )
      let target = KeybindingProviderPrimitives.resolveSymlink(
        destination,
        relativeTo: configurationDirectory
      )
      let targetDescriptor = try PinnedFilesystem.openDirectory(at: target)
      defer { Darwin.close(targetDescriptor) }
      let inventory = try PinnedFilesystem.directoryEntries(
        descriptor: targetDescriptor,
        url: target,
        limit: 2
      )
      guard inventory.entries == [SkhdLayout.configurationName], !inventory.truncated else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
      let source = try PinnedFilesystem.readRegularFile(
        parentDescriptor: targetDescriptor,
        name: SkhdLayout.configurationName,
        url: target.appending(path: SkhdLayout.configurationName),
        maximumSize: SetupOwnershipManager.maximumConfigurationSize
      )
      let sourceMetadata = try PinnedFilesystem.metadata(
        parentDescriptor: targetDescriptor,
        name: SkhdLayout.configurationName,
        url: target.appending(path: SkhdLayout.configurationName)
      )
      guard sourceMetadata.st_mode & S_IFMT == S_IFREG, sourceMetadata.st_nlink == 1 else {
        throw SetupOwnershipError.ownershipDrift(
          target.appending(path: SkhdLayout.configurationName))
      }
      return OriginalEntry(
        kind: .directorySymbolicLink,
        data: nil,
        linkDestination: destination,
        fileMode: nil,
        metadataDigest: nil,
        fileDevice: UInt64(directoryMetadata.st_dev),
        fileInode: UInt64(directoryMetadata.st_ino),
        sourceDigest: sha256Digest(source.data),
        inventory: inventory.entries,
        pinnedRegularDescriptor: nil
      )
    }
    guard directoryMetadata.st_mode & S_IFMT == S_IFDIR else {
      throw SetupOwnershipError.ownershipDrift(directory)
    }

    let directoryDescriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: configurationDescriptor,
      name: SkhdLayout.directoryName,
      url: directory
    )
    defer { Darwin.close(directoryDescriptor) }
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: directoryDescriptor,
        name: SkhdLayout.configurationName,
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
        inventory: [],
        pinnedRegularDescriptor: nil
      )
    }
    switch metadata.st_mode & S_IFMT {
    case S_IFREG:
      guard metadata.st_nlink == 1 else { throw SetupOwnershipError.ownershipDrift(entry) }
      try faultInjector(.regularPathInspected)
      let descriptor = try manager.openPinnedRegularFile(
        parentDescriptor: directoryDescriptor,
        name: SkhdLayout.configurationName,
        url: entry,
        label: "skhd entry"
      )
      var descriptorTransferred = false
      defer {
        if !descriptorTransferred { Darwin.close(descriptor) }
      }
      let (file, snapshot) = try manager.readPinnedRegularFileSnapshot(
        descriptor: descriptor,
        url: entry,
        label: "skhd entry"
      )
      let boundMetadata = try PinnedFilesystem.metadata(
        parentDescriptor: directoryDescriptor,
        name: SkhdLayout.configurationName,
        url: entry
      )
      guard
        snapshot.mode & UInt32(S_IFMT) == UInt32(S_IFREG),
        snapshot.linkCount == 1,
        UInt64(boundMetadata.st_dev) == snapshot.device,
        UInt64(boundMetadata.st_ino) == snapshot.inode,
        boundMetadata.st_mode & S_IFMT == S_IFREG,
        boundMetadata.st_nlink == 1
      else { throw SetupOwnershipError.ownershipDrift(entry) }
      guard snapshot.extendedAttributes[KeybindingProviderPrimitives.claimMarkerAttribute] == nil
      else {
        throw KeybindingsApplyError.blocked(
          "regular skhd entry uses Macarchy's reserved claim-marker extended attribute"
        )
      }
      guard snapshot.flags & Self.unsupportedRestorationFlags == 0 else {
        throw KeybindingsApplyError.blocked(
          "regular skhd entry uses immutable, append-only, or another unsupported restrictive flag"
        )
      }
      descriptorTransferred = true
      return OriginalEntry(
        kind: .regularFile,
        data: file.data,
        linkDestination: nil,
        fileMode: UInt16(snapshot.mode & 0o7777),
        metadataDigest: snapshot.restorableMetadataDigest(),
        fileDevice: snapshot.device,
        fileInode: snapshot.inode,
        sourceDigest: sha256Digest(file.data),
        inventory: [],
        pinnedRegularDescriptor: descriptor
      )
    case S_IFLNK:
      try KeybindingProviderInspector.requireAdoptableSymlink(
        metadata,
        parentDescriptor: directoryDescriptor,
        name: SkhdLayout.configurationName,
        url: entry
      )
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: directoryDescriptor,
        name: SkhdLayout.configurationName,
        url: entry
      )
      let resolved = KeybindingProviderPrimitives.resolveSymlink(
        destination,
        relativeTo: directory
      )
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
        fileDevice: UInt64(metadata.st_dev),
        fileInode: UInt64(metadata.st_ino),
        sourceDigest: sha256Digest(source.data),
        inventory: [],
        pinnedRegularDescriptor: nil
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
    if expectedEvidence.kind == .legacyFallback {
      let observedFallback = try KeybindingProviderInspector().legacyFallbackEvidence(
        homeDirectory: homeDirectory
      )
      guard observedFallback == expectedEvidence else {
        throw KeybindingsApplyError.blocked(
          "fallback ~/.skhdrc adoption evidence changed after preview; review the new plan"
        )
      }
    }
    let original = try captureOriginal(manager: manager)
    var returned = false
    defer {
      if !returned { original.closePinnedDescriptor() }
    }
    guard
      expectedEvidence.kind == .legacyFallback
        ? original.kind == .absent
        : original.evidence == expectedEvidence
    else {
      throw KeybindingsApplyError.blocked(
        "skhd adoption evidence changed after preview; review the new plan"
      )
    }
    if expectedEvidence.kind == .legacyFallback {
      guard approvedEvidenceDigest == expectedEvidence.digest else {
        throw KeybindingsApplyError.blocked(
          "--adopt must equal the exact fallback adoption evidence digest from the reviewed plan"
        )
      }
    } else if original.kind == .absent {
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
    try requireLegacyClaimAbsent(original.kind == .directorySymbolicLink ? .directory : .leaf)
    returned = true
    return original
  }

  private func revalidateCapturedRegularOriginal(
    _ original: OriginalEntry,
    manager: SetupOwnershipManager
  ) throws {
    guard original.kind == .regularFile,
      let descriptor = original.pinnedRegularDescriptor
    else { return }
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw SetupOwnershipError.posix("rewind pinned skhd entry", entry)
    }
    let (file, snapshot) = try manager.readPinnedRegularFileSnapshot(
      descriptor: descriptor,
      url: entry,
      label: "skhd entry"
    )
    let parent = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(parent) }
    let path = try PinnedFilesystem.metadata(
      parentDescriptor: parent,
      name: SkhdLayout.configurationName,
      url: entry
    )
    guard
      snapshot.mode & UInt32(S_IFMT) == UInt32(S_IFREG),
      snapshot.device == original.fileDevice,
      snapshot.inode == original.fileInode,
      snapshot.linkCount == 1,
      snapshot.mode & 0o7777 == UInt32(original.fileMode ?? 0),
      snapshot.flags & Self.unsupportedRestorationFlags == 0,
      snapshot.restorableMetadataDigest() == original.metadataDigest,
      sha256Digest(file.data) == original.sourceDigest,
      UInt64(path.st_dev) == snapshot.device,
      UInt64(path.st_ino) == snapshot.inode,
      path.st_mode & S_IFMT == S_IFREG,
      path.st_nlink == 1
    else { throw SetupOwnershipError.ownershipDrift(entry) }
  }

  /// Requires the claim name without a nonce to be absent at `level`.
  private func requireLegacyClaimAbsent(_ level: SkhdLayout.Level) throws {
    let parentURL = layout.parent(level)
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    let name = SkhdLayout.claimPrefix(level)
    try requireAbsent(parentDescriptor: parent, name: name, url: parentURL.appending(path: name))
  }

  func requireAbsent(parentDescriptor: Int32, name: String, url: URL) throws {
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
  let pinnedRegularDescriptor: Int32?

  func closePinnedDescriptor() {
    if let pinnedRegularDescriptor { Darwin.close(pinnedRegularDescriptor) }
  }

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
    layout: SkhdLayout,
    manager: SetupOwnershipManager,
    context: SetupOwnershipManager.Context
  ) throws -> SetupOwnershipRecord {
    let entry = layout.entry
    let nonce = UUID().uuidString.lowercased()
    let retainedOriginalPath: String? =
      switch kind {
      case .symbolicLink:
        layout.claim(.leaf, nonce: nonce).path
      case .directorySymbolicLink:
        layout.claim(.directory, nonce: nonce).path
      case .absent, .regularFile:
        nil
      }
    return SetupOwnershipRecord(
      id: KeybindingProviderInspector.ownershipID,
      phase: .prepared,
      kind: .symbolicLink,
      targetPath: entry.path,
      backupPath: kind == .regularFile
        ? manager.relativePath(layout.backup, below: context.stateRoot) : nil,
      originalDigest: data.map(sha256Digest)
        ?? linkDestination.map { sha256Digest(Data($0.utf8)) },
      installedDigest: sha256Digest(Data(SkhdLayout.managedTarget.utf8)),
      linkDestination: SkhdLayout.managedTarget,
      originalKind: kind,
      originalLinkDestination: linkDestination,
      originalFileMode: fileMode,
      originalMetadataDigest: metadataDigest,
      originalVolumeUUID: try retainedOriginalPath.map { _ in
        let path = kind == .directorySymbolicLink ? layout.directory : entry
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0,
          UInt64(metadata.st_dev) == fileDevice, UInt64(metadata.st_ino) == fileInode
        else { throw SetupOwnershipError.ownershipDrift(path) }
        return try RetainedOriginalIdentity.volumeUUID(at: path, matching: metadata)
      },
      originalDevice: fileDevice,
      originalInode: fileInode,
      originalSourceDigest: kind == .absent ? nil : sourceDigest,
      originalInventory: kind == .absent ? nil : inventory,
      retainedOriginalPath: retainedOriginalPath,
      claimNonce: nonce
    )
  }
}

enum ProviderItemState: Equatable {
  case incomplete
  case managed
  case missing
  case original
  case other
}
