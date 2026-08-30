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

struct KeybindingProviderTransaction: Sendable {
  private static let claimMarkerAttribute = KeybindingProviderInspector.claimMarkerAttribute
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
    let record = original.record(entry: entry, backup: backup, manager: manager, context: context)
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
    if KeybindingProviderInspector.isLegacyCleanInstallRecord(record) {
      try restoreLegacyManagedEntry(record)
      return
    }
    switch originalKind(record) {
    case .directorySymbolicLink:
      try replaceOriginalDirectoryWithManaged(record)
    case .absent, .regularFile, .symbolicLink:
      try replaceOriginalLeafWithManaged(record)
    }
  }

  func preflightOriginalRestoration() throws {
    let (record, _, _) = try ownershipRecord()
    if KeybindingProviderInspector.isLegacyCleanInstallRecord(record) {
      try preflightLegacyCleanInstall(record)
      return
    }
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
        recognizeIncompleteClaim: true
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
        recognizeIncompleteClaim: true
      )
      let stateIsRecoverable =
        state == .managed || state == .original
        || (state == .missing && originalKind(record) == .absent)
      guard stateIsRecoverable, claim != .other else {
        throw SetupOwnershipError.ownershipDrift(entry)
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
  }

  func preflightManagedRestoration() throws {
    try preflightOriginalRestoration()
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
        record = record.withPhase(.teardownPrepared)
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
      try requireAbsent(
        parentDescriptor: directoryDescriptor,
        name: legacyRestorationName,
        url: directory.appending(path: legacyRestorationName)
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
        name: "skhdrc",
        url: entry,
        label: "skhd entry"
      )
      var descriptorTransferred = false
      defer {
        if !descriptorTransferred { Darwin.close(descriptor) }
      }
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
      let boundMetadata = try PinnedFilesystem.metadata(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
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
      guard snapshot.extendedAttributes[Self.claimMarkerAttribute] == nil else {
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
        data: data,
        linkDestination: nil,
        fileMode: UInt16(snapshot.mode & 0o7777),
        metadataDigest: snapshot.restorableMetadataDigest(),
        fileDevice: snapshot.device,
        fileInode: snapshot.inode,
        sourceDigest: sha256Digest(data),
        inventory: [],
        pinnedRegularDescriptor: descriptor
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
    try requireInstallClaimAbsent(for: original)
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
      throw posixError("rewind pinned skhd entry", entry)
    }
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
    let parent = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(parent) }
    let path = try PinnedFilesystem.metadata(
      parentDescriptor: parent,
      name: "skhdrc",
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
      sha256Digest(data) == original.sourceDigest,
      UInt64(path.st_dev) == snapshot.device,
      UInt64(path.st_ino) == snapshot.inode,
      path.st_mode & S_IFMT == S_IFREG,
      path.st_nlink == 1
    else { throw SetupOwnershipError.ownershipDrift(entry) }
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
    try recoverBackupPublication(record, manager: manager)
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
    try resumeProviderDeletionResidue(
      parentDescriptor: descriptor,
      name: claim,
      record: record,
      url: directory.appending(path: claim)
    )
    let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
    var claimState = try leafState(
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true
    )
    if claimState == .incomplete {
      try removeMarkedItem(
        parentDescriptor: descriptor, name: claim, record: record, url: entry)
      claimState = .missing
    }
    if state == .managed {
      if claimState == .original {
        try removeOriginalItem(
          parentDescriptor: descriptor, name: claim, record: record, url: entry)
      }
      guard claimState == .missing || claimState == .original else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      return
    }
    if state == .original, claimState == .managed {
      try faultInjector(.providerClaimReady)
      if originalKind(record) == .regularFile {
        try displacePinnedRegularOriginal(record, descriptor: descriptor, claim: claim)
      } else {
        try withAuthenticatedOriginalSource(
          record,
          parentDescriptor: descriptor,
          sourceName: "skhdrc",
          claimName: claim,
          url: entry
        ) {
          try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
        }
        try faultInjector(.providerClaimSwapped)
      }
      try removeOriginalItem(
        parentDescriptor: descriptor, name: claim, record: record, url: entry)
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
      try faultInjector(.providerClaimReady)
      if originalKind(record) == .regularFile {
        try displacePinnedRegularOriginal(record, descriptor: descriptor, claim: claim)
      } else {
        try withAuthenticatedOriginalSource(
          record,
          parentDescriptor: descriptor,
          sourceName: "skhdrc",
          claimName: claim,
          url: entry
        ) {
          try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
        }
        try faultInjector(.providerClaimSwapped)
      }
      guard
        try leafState(
          descriptor: descriptor,
          name: claim,
          record: record
        ) == .original
      else { throw SetupOwnershipError.ownershipDrift(entry) }
      try removeOriginalItem(
        parentDescriptor: descriptor, name: claim, record: record, url: entry)
    }
  }

  private func restoreOriginalLeaf(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    let claim = claimName(record, directory: false)
    try resumeProviderDeletionResidue(
      parentDescriptor: descriptor,
      name: claim,
      record: record,
      url: directory.appending(path: claim)
    )
    let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
    var claimState = try leafState(
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true
    )
    if claimState == .incomplete {
      try removeMarkedItem(
        parentDescriptor: descriptor, name: claim, record: record, url: entry)
      claimState = .missing
    }
    if state == .original || (state == .missing && originalKind(record) == .absent) {
      if claimState == .managed {
        try removeMarkedItem(
          parentDescriptor: descriptor, name: claim, record: record, url: entry)
      }
      guard claimState == .missing || claimState == .managed else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      if state == .original,
        try claimMarkerMatches(
          parentDescriptor: descriptor,
          name: "skhdrc",
          record: record,
          url: entry
        )
      {
        try finalizeRestoredOriginal(
          record,
          parentDescriptor: descriptor,
          name: "skhdrc",
          url: entry
        )
      }
      return
    }
    if state == .managed, claimState == .original {
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try faultInjector(.restoredOriginalPublished)
      try finalizeRestoredOriginal(record, parentDescriptor: descriptor, name: "skhdrc", url: entry)
      try removeMarkedItem(
        parentDescriptor: descriptor, name: claim, record: record, url: entry)
      return
    }
    guard state == .managed, claimState == .missing else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    switch originalKind(record) {
    case .absent:
      try rename(descriptor: descriptor, from: "skhdrc", to: claim, url: entry)
      try faultInjector(.managedEntryClaimedForRemoval)
      try removeMarkedItem(
        parentDescriptor: descriptor, name: claim, record: record, url: entry)
    case .regularFile:
      try restoreRegularFileClaim(record, descriptor: descriptor, name: claim)
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try faultInjector(.restoredOriginalPublished)
      try finalizeRestoredOriginal(record, parentDescriptor: descriptor, name: "skhdrc", url: entry)
      try removeMarkedItem(
        parentDescriptor: descriptor, name: claim, record: record, url: entry)
    case .symbolicLink:
      try createSymlink(
        descriptor: descriptor,
        name: claim,
        destination: try originalLink(record),
        url: entry,
        record: record
      )
      try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      try faultInjector(.restoredOriginalPublished)
      try finalizeRestoredOriginal(record, parentDescriptor: descriptor, name: "skhdrc", url: entry)
      try removeMarkedItem(
        parentDescriptor: descriptor, name: claim, record: record, url: entry)
    case .directorySymbolicLink:
      throw SetupOwnershipError.invalidManifest("directory adoption cannot restore a leaf")
    }
    try verifyOriginal(try ownershipRecord().0, context: context)
  }

  private func replaceOriginalDirectoryWithManaged(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(descriptor) }
    let claim = claimName(record, directory: true)
    try resumeProviderDeletionResidue(
      parentDescriptor: descriptor,
      name: claim,
      record: record,
      url: configurationDirectory.appending(path: claim),
      directory: true
    )
    let state = try directoryState(descriptor: descriptor, name: "skhd", record: record)
    var claimState = try directoryState(
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true
    )
    if claimState == .incomplete {
      try createManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
      claimState = try directoryState(
        descriptor: descriptor,
        name: claim,
        record: record
      )
    }
    if state == .managed {
      if claimState == .original {
        try removeOriginalItem(
          parentDescriptor: descriptor, name: claim, record: record, url: directory)
      }
      guard claimState == .missing || claimState == .original else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
      return
    }
    if state == .original, claimState == .managed {
      try faultInjector(.providerClaimReady)
      try withAuthenticatedOriginalSource(
        record,
        parentDescriptor: descriptor,
        sourceName: "skhd",
        claimName: claim,
        url: directory
      ) {
        try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
      }
      try faultInjector(.providerClaimSwapped)
      try removeOriginalItem(
        parentDescriptor: descriptor, name: claim, record: record, url: directory)
      return
    }
    guard state == .original, claimState == .missing else {
      throw SetupOwnershipError.ownershipDrift(directory)
    }
    try createManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
    try faultInjector(.providerClaimReady)
    try withAuthenticatedOriginalSource(
      record,
      parentDescriptor: descriptor,
      sourceName: "skhd",
      claimName: claim,
      url: directory
    ) {
      try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
    }
    try faultInjector(.providerClaimSwapped)
    guard
      try directoryState(
        descriptor: descriptor,
        name: claim,
        record: record
      ) == .original
    else { throw SetupOwnershipError.ownershipDrift(directory) }
    try removeOriginalItem(
      parentDescriptor: descriptor, name: claim, record: record, url: directory)
  }

  private func restoreOriginalDirectory(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
    defer { Darwin.close(descriptor) }
    let claim = claimName(record, directory: true)
    try resumeProviderDeletionResidue(
      parentDescriptor: descriptor,
      name: claim,
      record: record,
      url: configurationDirectory.appending(path: claim),
      directory: true
    )
    let state = try directoryState(descriptor: descriptor, name: "skhd", record: record)
    var claimState = try directoryState(
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true
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
      if try claimMarkerMatches(
        parentDescriptor: descriptor,
        name: "skhd",
        record: record,
        url: directory
      ) {
        try finalizeRestoredOriginal(
          record,
          parentDescriptor: descriptor,
          name: "skhd",
          url: directory
        )
      }
      return
    }
    if state == .managed, claimState == .original {
      try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
      try faultInjector(.restoredOriginalPublished)
      try finalizeRestoredOriginal(
        record, parentDescriptor: descriptor, name: "skhd", url: directory)
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
    try swap(descriptor: descriptor, first: "skhd", second: claim, url: directory)
    try faultInjector(.restoredOriginalPublished)
    try finalizeRestoredOriginal(record, parentDescriptor: descriptor, name: "skhd", url: directory)
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
    recognizeIncompleteClaim: Bool = false
  ) throws -> ProviderItemState {
    let url = directory.appending(path: name)
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(parentDescriptor: descriptor, name: name, url: url)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .missing
    }
    let markerMatches = try claimMarkerMatches(
      parentDescriptor: descriptor,
      name: name,
      record: record,
      url: url
    )
    switch metadata.st_mode & S_IFMT {
    case S_IFLNK:
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: descriptor,
        name: name,
        url: url
      )
      if destination == KeybindingProviderInspector.managedTarget {
        return markerMatches ? .managed : .other
      }
      if originalKind(record) == .symbolicLink,
        destination == record.originalLinkDestination
      {
        if try markerMatches || originalIdentityMatches(metadata, record: record) {
          return .original
        }
      }
      return .other
    case S_IFREG where originalKind(record) == .regularFile:
      if try regularOriginalMatches(
        record,
        parentDescriptor: descriptor,
        name: name,
        url: url,
        allowMarker: markerMatches
      ) {
        return .original
      }
      return recognizeIncompleteClaim && markerMatches ? .incomplete : .other
    default:
      return .other
    }
  }

  private func directoryState(
    descriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    recognizeIncompleteClaim: Bool = false
  ) throws -> ProviderItemState {
    let url = configurationDirectory.appending(path: name)
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(parentDescriptor: descriptor, name: name, url: url)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .missing
    }
    let markerMatches = try claimMarkerMatches(
      parentDescriptor: descriptor,
      name: name,
      record: record,
      url: url
    )
    if metadata.st_mode & S_IFMT == S_IFLNK {
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: descriptor,
        name: name,
        url: url
      )
      guard destination == record.originalLinkDestination else { return .other }
      return try markerMatches || originalIdentityMatches(metadata, record: record)
        ? .original : .other
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR else { return .other }
    guard markerMatches else { return .other }
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
    let publicationName = try publishingName(name, record: record)
    let publicationURL = configurationDirectory.appending(
      path: publicationName,
      directoryHint: .isDirectory
    )
    let descriptor: Int32
    let needsPublication: Bool
    let created: Bool
    do {
      descriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
      needsPublication = false
      created = false
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      needsPublication = true
      do {
        descriptor = try PinnedFilesystem.openDirectory(
          parentDescriptor: parentDescriptor,
          name: publicationName,
          url: publicationURL
        )
        created = false
      } catch let publicationError as PinnedFilesystemError where publicationError.code == ENOENT {
        descriptor = try PinnedFilesystem.createDirectory(
          parentDescriptor: parentDescriptor,
          name: publicationName,
          url: publicationURL
        )
        created = true
      }
    }
    defer { Darwin.close(descriptor) }
    if created {
      try markClaim(
        descriptor: descriptor,
        parentDescriptor: parentDescriptor,
        name: publicationName,
        record: record,
        url: publicationURL
      )
      try faultInjector(.providerPublicationAuthenticated)
    } else {
      guard
        try claimMarkerMatches(
          descriptor: descriptor,
          record: record,
          url: needsPublication ? publicationURL : url
        )
      else { throw SetupOwnershipError.ownershipDrift(url) }
    }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor,
      url: needsPublication ? publicationURL : url,
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
      if needsPublication {
        try publish(parentDescriptor: parentDescriptor, from: publicationName, to: name, url: url)
        try faultInjector(.directoryClaimCreated)
      }
      return
    }
    guard inventory.entries.isEmpty, !inventory.truncated else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    try createSymlink(
      descriptor: descriptor,
      name: "skhdrc",
      destination: KeybindingProviderInspector.managedTarget,
      url: (needsPublication ? publicationURL : url).appending(path: "skhdrc"),
      record: record
    )
    try faultInjector(.directoryClaimPopulated)
    if needsPublication {
      try publish(parentDescriptor: parentDescriptor, from: publicationName, to: name, url: url)
      try faultInjector(.directoryClaimCreated)
    }
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
    let temporaryName = try publishingName(backup.lastPathComponent, record: record)
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
    guard fcopyfile(source, temporary, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
      throw posixError("copy keybinding backup metadata", temporaryURL)
    }
    let copiedSnapshot = try manager.regularFileSnapshot(
      descriptor: temporary,
      url: temporaryURL,
      label: "keybinding backup",
      excludingExtendedAttribute: Self.claimMarkerAttribute
    )
    guard copiedSnapshot.hasCopiedMetadata(from: sourceSnapshot) else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    guard fchmod(temporary, mode_t(0o600)) == 0 else {
      throw posixError("secure keybinding backup", temporaryURL)
    }
    try markClaim(
      descriptor: temporary,
      parentDescriptor: backupParent,
      name: temporaryName,
      record: record,
      url: temporaryURL
    )
    try faultInjector(.backupPublicationAuthenticated)
    try manager.write(
      data,
      descriptor: temporary,
      url: temporaryURL,
      operation: "write keybinding backup"
    )
    var timestamps = [
      timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
      timespec(
        tv_sec: time_t(sourceSnapshot.modifiedSeconds),
        tv_nsec: Int(sourceSnapshot.modifiedNanoseconds)
      ),
    ]
    guard futimens(temporary, &timestamps) == 0 else {
      throw posixError("restore keybinding backup modification time", temporaryURL)
    }
    guard fsync(temporary) == 0 else { throw posixError("sync keybinding backup", temporaryURL) }
    let snapshot = try manager.regularFileSnapshot(
      descriptor: temporary,
      url: temporaryURL,
      label: "keybinding backup",
      excludingExtendedAttribute: Self.claimMarkerAttribute
    )
    guard
      snapshot.linkCount == 1,
      snapshot.restorableMetadataDigest(overridingMode: try originalMode(record))
        == record.originalMetadataDigest
    else { throw SetupOwnershipError.ownershipDrift(entry) }
    try faultInjector(.backupPublicationReady)
    var pinnedIdentity = stat()
    let pathIdentity = try PinnedFilesystem.metadata(
      parentDescriptor: backupParent,
      name: temporaryName,
      url: temporaryURL
    )
    guard
      fstat(temporary, &pinnedIdentity) == 0,
      pathIdentity.st_dev == pinnedIdentity.st_dev,
      pathIdentity.st_ino == pinnedIdentity.st_ino,
      pathIdentity.st_mode & S_IFMT == S_IFREG,
      pathIdentity.st_nlink == 1,
      try claimMarkerMatches(descriptor: temporary, record: record, url: temporaryURL)
    else { throw SetupOwnershipError.ownershipDrift(temporaryURL) }
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
    try sync(backupParent, url: backup.deletingLastPathComponent())
    _ = try readOriginalBackup(record, manager: manager)
  }

  private func recoverBackupPublication(
    _ record: SetupOwnershipRecord,
    manager: SetupOwnershipManager
  ) throws {
    guard
      let complete = try validateBackupPublicationResidue(record, manager: manager)
    else { return }
    let parent = try openBackupDirectory(create: false)
    defer { Darwin.close(parent) }
    let name = try publishingName(backup.lastPathComponent, record: record)
    let url = backup.deletingLastPathComponent().appending(path: name)
    if try backupExists() {
      _ = try readOriginalBackup(record, manager: manager)
      try removeMarkedItem(
        parentDescriptor: parent,
        name: name,
        record: record,
        url: url
      )
    } else if complete {
      try publish(
        parentDescriptor: parent,
        from: name,
        to: backup.lastPathComponent,
        url: backup
      )
      _ = try readOriginalBackup(record, manager: manager)
    } else {
      try removeMarkedItem(
        parentDescriptor: parent,
        name: name,
        record: record,
        url: url
      )
    }
  }

  private func validateBackupPublicationResidue(
    _ record: SetupOwnershipRecord,
    manager: SetupOwnershipManager
  ) throws -> Bool? {
    let parent: Int32
    do {
      parent = try openBackupDirectory(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    defer { Darwin.close(parent) }
    let name = try publishingName(backup.lastPathComponent, record: record)
    let url = backup.deletingLastPathComponent().appending(path: name)
    guard try itemExists(parentDescriptor: parent, name: name, url: url) else { return nil }
    let descriptor = try manager.openPinnedRegularFile(
      parentDescriptor: parent,
      name: name,
      url: url,
      label: "keybinding backup publication"
    )
    defer { Darwin.close(descriptor) }
    guard
      try claimMarkerMatches(descriptor: descriptor, record: record, url: url)
    else { throw SetupOwnershipError.ownershipDrift(url) }
    let file = try manager.readPinnedRegularFile(
      descriptor: descriptor,
      url: url,
      label: "keybinding backup publication"
    )
    let snapshot = try manager.regularFileSnapshot(
      descriptor: descriptor,
      url: url,
      label: "keybinding backup publication",
      excludingExtendedAttribute: Self.claimMarkerAttribute
    )
    guard snapshot.linkCount == 1 else { throw SetupOwnershipError.ownershipDrift(url) }
    let mode = try originalMode(record)
    return file.permissions == 0o600
      && sha256Digest(file.data) == record.originalDigest
      && snapshot.restorableMetadataDigest(overridingMode: mode)
        == record.originalMetadataDigest
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
      label: "keybinding backup",
      excludingExtendedAttribute: Self.claimMarkerAttribute
    )
    guard
      try claimMarkerMatches(descriptor: descriptor, record: record, url: backup),
      file.permissions == 0o600,
      snapshot.linkCount == 1,
      sha256Digest(file.data) == record.originalDigest,
      snapshot.restorableMetadataDigest(overridingMode: try originalMode(record))
        == record.originalMetadataDigest
    else {
      throw SetupOwnershipError.corruptBackup(backup)
    }
    return (file.data, snapshot)
  }

  private func displacePinnedRegularOriginal(
    _ record: SetupOwnershipRecord,
    descriptor: Int32,
    claim: String
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
    let data = try manager.readPinnedRegularFile(
      descriptor: current,
      url: entry,
      label: "skhd entry"
    ).data
    let before = try manager.regularFileSnapshot(
      descriptor: current,
      url: entry,
      label: "skhd entry"
    )
    guard
      data == stored.data,
      before.device == record.originalDevice,
      before.inode == record.originalInode,
      before.linkCount == 1,
      before.flags & Self.unsupportedRestorationFlags == 0,
      before.mode & 0o7777 == UInt32(try originalMode(record)),
      before.hasCopiedMetadataIgnoringMode(from: stored.snapshot),
      before.restorableMetadataDigest() == record.originalMetadataDigest
    else { throw SetupOwnershipError.ownershipDrift(entry) }

    try faultInjector(.regularOriginalPinned)
    try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
    try faultInjector(.providerClaimSwapped)
    do {
      let pathMetadata = try PinnedFilesystem.metadata(
        parentDescriptor: descriptor,
        name: claim,
        url: directory.appending(path: claim)
      )
      let after = try manager.regularFileSnapshot(
        descriptor: current,
        url: directory.appending(path: claim),
        label: "displaced skhd entry"
      )
      guard
        UInt64(pathMetadata.st_dev) == before.device,
        UInt64(pathMetadata.st_ino) == before.inode,
        after.matchesDisplaced(before),
        after.linkCount == 1
      else { throw SetupOwnershipError.ownershipDrift(entry) }
    } catch {
      do {
        try swap(descriptor: descriptor, first: "skhdrc", second: claim, url: entry)
      } catch let rollbackError {
        throw SetupOwnershipError.system(
          "restore skhd entry after displacement authentication failed",
          entry,
          "\(error); swap-back also failed: \(rollbackError)"
        )
      }
      throw error
    }
  }

  private func restoreRegularFileClaim(
    _ record: SetupOwnershipRecord,
    descriptor: Int32,
    name: String
  ) throws {
    let manager = SetupOwnershipManager()
    let stored = try readOriginalBackup(record, manager: manager)
    let publicationName = try publishingName(name, record: record)
    let claimURL = directory.appending(path: name)
    let publicationURL = directory.appending(path: publicationName)
    if try authenticatedPublicationExists(
      parentDescriptor: descriptor,
      name: publicationName,
      record: record,
      url: publicationURL
    ) {
      if try regularOriginalMatches(
        record,
        parentDescriptor: descriptor,
        name: publicationName,
        url: publicationURL,
        allowMarker: true
      ) {
        try publish(parentDescriptor: descriptor, from: publicationName, to: name, url: claimURL)
        return
      }
      try removeMarkedItem(
        parentDescriptor: descriptor,
        name: publicationName,
        record: record,
        url: publicationURL
      )
    }
    let claim = publicationName.withCString {
      Darwin.openat(
        descriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
    }
    guard claim >= 0 else { throw posixError("create restored skhd entry", publicationURL) }
    defer { Darwin.close(claim) }
    try markClaim(
      descriptor: claim,
      parentDescriptor: descriptor,
      name: publicationName,
      record: record,
      url: publicationURL
    )
    var cleanup = true
    defer {
      if cleanup { publicationName.withCString { _ = Darwin.unlinkat(descriptor, $0, 0) } }
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
      url: publicationURL,
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
      throw posixError("restore skhd entry metadata", publicationURL)
    }
    guard fchmod(claim, mode_t(try originalMode(record))) == 0 else {
      throw posixError("restore skhd entry permissions", publicationURL)
    }
    if try !claimMarkerMatches(descriptor: claim, record: record, url: publicationURL) {
      try markClaim(
        descriptor: claim,
        parentDescriptor: descriptor,
        name: publicationName,
        record: record,
        url: publicationURL
      )
    }
    do {
      try faultInjector(.regularRestorationClaimMetadataCopied)
    } catch {
      cleanup = false
      throw error
    }
    guard fsync(claim) == 0 else { throw posixError("sync restored skhd entry", publicationURL) }
    let restoredSnapshot = try manager.regularFileSnapshot(
      descriptor: claim,
      url: publicationURL,
      label: "restored skhd entry",
      excludingExtendedAttribute: Self.claimMarkerAttribute
    )
    guard
      restoredSnapshot.mode & 0o7777 == UInt32(try originalMode(record)),
      restoredSnapshot.linkCount == 1,
      restoredSnapshot.restorableMetadataDigest() == record.originalMetadataDigest
    else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    try publish(parentDescriptor: descriptor, from: publicationName, to: name, url: claimURL)
    cleanup = false
  }

  private func removeManagedDirectory(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord
  ) throws {
    let url = configurationDirectory.appending(path: name, directoryHint: .isDirectory)
    if try itemExists(parentDescriptor: parentDescriptor, name: name, url: url) {
      let descriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
      defer { Darwin.close(descriptor) }
      guard
        try claimMarkerMatches(descriptor: descriptor, record: record, url: url)
      else { throw SetupOwnershipError.ownershipDrift(url) }
      let nestedPublication = try publishingName("skhdrc", record: record)
      try removeMarkedItem(
        parentDescriptor: descriptor,
        name: nestedPublication,
        record: record,
        url: url.appending(path: nestedPublication)
      )
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
        try removeMarkedItem(
          parentDescriptor: descriptor,
          name: "skhdrc",
          record: record,
          url: url.appending(path: "skhdrc")
        )
        try faultInjector(.directoryClaimEntryRemoved)
      } else if !inventory.entries.isEmpty {
        throw SetupOwnershipError.ownershipDrift(url)
      }
    }
    try removePinnedItem(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      directory: true,
      record: record
    ) { deletionName, deletionURL in
      let deletionDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: deletionName,
        url: deletionURL
      )
      defer { Darwin.close(deletionDescriptor) }
      guard
        try claimMarkerMatches(
          descriptor: deletionDescriptor,
          record: record,
          url: deletionURL
        )
      else { throw SetupOwnershipError.ownershipDrift(deletionURL) }
      let deletionInventory = try PinnedFilesystem.directoryEntries(
        descriptor: deletionDescriptor,
        url: deletionURL,
        limit: 1
      )
      guard deletionInventory.entries.isEmpty, !deletionInventory.truncated else {
        throw SetupOwnershipError.ownershipDrift(deletionURL)
      }
    }
  }

  private func preflightLegacyCleanInstall(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    try requireAbsent(
      parentDescriptor: descriptor,
      name: ".skhdrc.macarchy-keybindings",
      url: directory.appending(path: ".skhdrc.macarchy-keybindings")
    )
    _ = try legacyRestorationResidueExists(parentDescriptor: descriptor, record: record)
    do {
      try verifyLegacyManagedLink(
        parentDescriptor: descriptor,
        name: "skhdrc",
        record: record,
        url: entry
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
  }

  private func removeLegacyManagedEntry(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    try removeLegacyRestorationResidue(parentDescriptor: descriptor, record: record)
    do {
      try removePinnedItem(
        parentDescriptor: descriptor,
        name: "skhdrc",
        url: entry,
        record: record
      ) { name, url in
        try verifyLegacyManagedLink(
          parentDescriptor: descriptor,
          name: name,
          record: record,
          url: url
        )
      }
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
  }

  private func restoreLegacyManagedEntry(_ record: SetupOwnershipRecord) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    let publicationName = legacyRestorationName
    let publicationURL = directory.appending(path: publicationName)
    let residueExists = try legacyRestorationResidueExists(
      parentDescriptor: descriptor,
      record: record
    )
    do {
      try verifyLegacyManagedLink(
        parentDescriptor: descriptor,
        name: "skhdrc",
        record: record,
        url: entry
      )
      if residueExists {
        try removeLegacyRestorationResidue(parentDescriptor: descriptor, record: record)
      }
      return
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      if !residueExists {
        let created = KeybindingProviderInspector.managedTarget.withCString { destination in
          publicationName.withCString { Darwin.symlinkat(destination, descriptor, $0) }
        }
        guard created == 0 else {
          throw posixError("create legacy keybinding provider link", publicationURL)
        }
        try faultInjector(.legacyRestorationPublicationCreated)
        try verifyLegacyManagedLink(
          parentDescriptor: descriptor,
          name: publicationName,
          record: record,
          url: publicationURL
        )
      }
      try publish(
        parentDescriptor: descriptor,
        from: publicationName,
        to: "skhdrc",
        url: entry
      )
    }
  }

  private var legacyRestorationName: String {
    ".skhdrc.macarchy-legacy-restoration"
  }

  private func legacyRestorationResidueExists(
    parentDescriptor: Int32,
    record: SetupOwnershipRecord
  ) throws -> Bool {
    let url = directory.appending(path: legacyRestorationName)
    guard
      try itemExists(
        parentDescriptor: parentDescriptor,
        name: legacyRestorationName,
        url: url
      )
    else { return false }
    try verifyLegacyManagedLink(
      parentDescriptor: parentDescriptor,
      name: legacyRestorationName,
      record: record,
      url: url
    )
    return true
  }

  private func removeLegacyRestorationResidue(
    parentDescriptor: Int32,
    record: SetupOwnershipRecord
  ) throws {
    let url = directory.appending(path: legacyRestorationName)
    try removePinnedItem(
      parentDescriptor: parentDescriptor,
      name: legacyRestorationName,
      url: url,
      record: record
    ) { name, candidate in
      try verifyLegacyManagedLink(
        parentDescriptor: parentDescriptor,
        name: name,
        record: record,
        url: candidate
      )
    }
  }

  private func verifyLegacyManagedLink(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    guard KeybindingProviderInspector.isLegacyCleanInstallRecord(record) else {
      throw SetupOwnershipError.invalidManifest("legacy keybinding ownership shape changed")
    }
    let metadata = try PinnedFilesystem.metadata(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    guard metadata.st_mode & S_IFMT == S_IFLNK, metadata.st_nlink == 1 else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    let destination = try PinnedFilesystem.symlinkDestination(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    guard destination == KeybindingProviderInspector.managedTarget else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    let pinned = try openClaim(parentDescriptor: parentDescriptor, name: name, url: url)
    defer { Darwin.close(pinned) }
    let markerSize = Self.claimMarkerAttribute.withCString {
      Darwin.fgetxattr(pinned, $0, nil, 0, 0, 0)
    }
    if markerSize < 0, errno == ENOATTR { return }
    guard markerSize < 0 else { throw SetupOwnershipError.ownershipDrift(url) }
    throw posixError("inspect legacy keybinding ownership marker", url)
  }

  private func requireLegacyEntryAbsent() throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    try requireAbsent(parentDescriptor: descriptor, name: "skhdrc", url: entry)
    try requireAbsent(
      parentDescriptor: descriptor,
      name: legacyRestorationName,
      url: directory.appending(path: legacyRestorationName)
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

  private func backupDeletionResidueExists(_ record: SetupOwnershipRecord) throws -> Bool {
    let parent: Int32
    do {
      parent = try openBackupDirectory(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return false
    }
    defer { Darwin.close(parent) }
    let name = try deletionName(backup.lastPathComponent, record: record)
    return try itemExists(
      parentDescriptor: parent,
      name: name,
      url: backup.deletingLastPathComponent().appending(path: name)
    )
  }

  private func removeAuthenticatedProviderResidues(_ record: SetupOwnershipRecord) throws {
    let isDirectory = originalKind(record) == .directorySymbolicLink
    let claim = claimName(record, directory: isDirectory)
    let publication = try publishingName(claim, record: record)
    if isDirectory {
      let parent = try PinnedFilesystem.openDirectory(at: configurationDirectory)
      defer { Darwin.close(parent) }
      try resumeProviderDeletionResidue(
        parentDescriptor: parent,
        name: claim,
        record: record,
        url: configurationDirectory.appending(path: claim),
        directory: true
      )
      try removeManagedDirectory(parentDescriptor: parent, name: publication, record: record)
      try removeManagedDirectory(parentDescriptor: parent, name: claim, record: record)
    } else {
      let parent = try PinnedFilesystem.openDirectory(at: directory)
      defer { Darwin.close(parent) }
      try resumeProviderDeletionResidue(
        parentDescriptor: parent,
        name: claim,
        record: record,
        url: directory.appending(path: claim)
      )
      try removeMarkedItem(
        parentDescriptor: parent,
        name: publication,
        record: record,
        url: directory.appending(path: publication)
      )
      try removeMarkedItem(
        parentDescriptor: parent,
        name: claim,
        record: record,
        url: directory.appending(path: claim)
      )
    }
  }

  private func removeAuthenticatedBackup(
    _ record: SetupOwnershipRecord,
    manager: SetupOwnershipManager
  ) throws {
    let parent = try openBackupDirectory(create: false)
    defer { Darwin.close(parent) }
    try removePinnedItem(
      parentDescriptor: parent,
      name: backup.lastPathComponent,
      url: backup,
      record: record
    ) { deletionName, deletionURL in
      let descriptor = try manager.openPinnedRegularFile(
        parentDescriptor: parent,
        name: deletionName,
        url: deletionURL,
        label: "keybinding backup"
      )
      defer { Darwin.close(descriptor) }
      let file = try manager.readPinnedRegularFile(
        descriptor: descriptor,
        url: deletionURL,
        label: "keybinding backup"
      )
      let snapshot = try manager.regularFileSnapshot(
        descriptor: descriptor,
        url: deletionURL,
        label: "keybinding backup",
        excludingExtendedAttribute: Self.claimMarkerAttribute
      )
      guard
        try claimMarkerMatches(descriptor: descriptor, record: record, url: deletionURL),
        file.permissions == 0o600,
        sha256Digest(file.data) == record.originalDigest,
        snapshot.linkCount == 1,
        snapshot.restorableMetadataDigest(overridingMode: try originalMode(record))
          == record.originalMetadataDigest
      else { throw SetupOwnershipError.corruptBackup(backup) }
    }
  }

  private func removeBackupPublicationResidue(_ record: SetupOwnershipRecord) throws {
    let parent: Int32
    do {
      parent = try openBackupDirectory(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(parent) }
    let name = try publishingName(backup.lastPathComponent, record: record)
    try removeMarkedItem(
      parentDescriptor: parent,
      name: name,
      record: record,
      url: backup.deletingLastPathComponent().appending(path: name)
    )
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
    let publicationName = try publishingName(name, record: record)
    let publicationURL = url.deletingLastPathComponent().appending(path: publicationName)
    if try authenticatedPublicationExists(
      parentDescriptor: descriptor,
      name: publicationName,
      record: record,
      url: publicationURL
    ) {
      try publish(parentDescriptor: descriptor, from: publicationName, to: name, url: url)
      return
    }
    let result = destination.withCString { target in
      publicationName.withCString { Darwin.symlinkat(target, descriptor, $0) }
    }
    guard result == 0 else { throw posixError("create keybinding provider link", publicationURL) }
    try markClaim(
      parentDescriptor: descriptor,
      name: publicationName,
      record: record,
      url: publicationURL
    )
    try faultInjector(.providerPublicationAuthenticated)
    try publish(parentDescriptor: descriptor, from: publicationName, to: name, url: url)
  }

  private func publishingName(_ name: String, record: SetupOwnershipRecord) throws -> String {
    "\(name).publishing-\(try residueNonce(record))"
  }

  private func authenticatedPublicationExists(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws -> Bool {
    do {
      _ = try PinnedFilesystem.metadata(parentDescriptor: parentDescriptor, name: name, url: url)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return false
    }
    guard
      try claimMarkerMatches(
        parentDescriptor: parentDescriptor,
        name: name,
        record: record,
        url: url
      )
    else { throw SetupOwnershipError.ownershipDrift(url) }
    return true
  }

  private func publish(
    parentDescriptor: Int32,
    from source: String,
    to destination: String,
    url: URL
  ) throws {
    let result = source.withCString { sourceName in
      destination.withCString {
        Darwin.renameatx_np(
          parentDescriptor,
          sourceName,
          parentDescriptor,
          $0,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard result == 0 else { throw posixError("publish keybinding claim", url) }
    try sync(parentDescriptor, url: url.deletingLastPathComponent())
  }

  private func originalIdentityMatches(
    _ metadata: stat,
    record: SetupOwnershipRecord
  ) throws -> Bool {
    guard let device = record.originalDevice, let inode = record.originalInode else {
      throw SetupOwnershipError.invalidManifest("keybinding original identity is missing")
    }
    return UInt64(metadata.st_dev) == device && UInt64(metadata.st_ino) == inode
      && metadata.st_nlink == 1
  }

  private func regularOriginalMatches(
    _ record: SetupOwnershipRecord,
    parentDescriptor: Int32,
    name: String,
    url: URL,
    allowMarker: Bool
  ) throws -> Bool {
    let manager = SetupOwnershipManager()
    let descriptor = try manager.openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      label: "skhd original"
    )
    defer { Darwin.close(descriptor) }
    let data = try manager.readPinnedRegularFile(
      descriptor: descriptor,
      url: url,
      label: "skhd original"
    ).data
    let snapshot = try manager.regularFileSnapshot(
      descriptor: descriptor,
      url: url,
      label: "skhd original",
      excludingExtendedAttribute: allowMarker ? Self.claimMarkerAttribute : nil
    )
    let metadataDigest = snapshot.restorableMetadataDigest()
    return sha256Digest(data) == record.originalDigest
      && (allowMarker
        || (snapshot.device == record.originalDevice && snapshot.inode == record.originalInode))
      && snapshot.linkCount == 1
      && snapshot.flags & Self.unsupportedRestorationFlags == 0
      && metadataDigest == record.originalMetadataDigest
  }

  private func withAuthenticatedOriginalSource(
    _ record: SetupOwnershipRecord,
    parentDescriptor: Int32,
    sourceName: String,
    claimName: String,
    url: URL,
    operation: () throws -> Void
  ) throws {
    guard let expectedDigest = record.originalSourceDigest else {
      if originalKind(record) == .absent {
        try operation()
        return
      }
      throw SetupOwnershipError.invalidManifest("keybinding source digest is missing")
    }
    switch originalKind(record) {
    case .absent:
      try operation()
    case .regularFile:
      try operation()
    case .symbolicLink:
      let target = Self.resolveSymlink(try originalLink(record), relativeTo: directory)
      let parent = try PinnedFilesystem.openDirectory(at: target.deletingLastPathComponent())
      defer { Darwin.close(parent) }
      let manager = SetupOwnershipManager()
      let source = try manager.openPinnedRegularFile(
        parentDescriptor: parent,
        name: target.lastPathComponent,
        url: target,
        label: "adopted skhd source"
      )
      defer { Darwin.close(source) }
      var identity = stat()
      guard fstat(source, &identity) == 0 else { throw posixError("pin skhd source", target) }
      try performPinnedOriginalSwap(
        record,
        parentDescriptor: parentDescriptor,
        sourceName: sourceName,
        claimName: claimName,
        url: url,
        operation: operation
      ) {
        let path = try PinnedFilesystem.metadata(
          parentDescriptor: parent,
          name: target.lastPathComponent,
          url: target
        )
        guard lseek(source, 0, SEEK_SET) == 0 else {
          throw posixError("rewind adopted skhd source", target)
        }
        let file = try manager.readPinnedRegularFile(
          descriptor: source,
          url: target,
          label: "adopted skhd source"
        )
        let snapshot = try manager.regularFileSnapshot(
          descriptor: source,
          url: target,
          label: "adopted skhd source"
        )
        guard
          UInt64(path.st_dev) == UInt64(identity.st_dev),
          UInt64(path.st_ino) == UInt64(identity.st_ino),
          snapshot.linkCount == 1,
          sha256Digest(file.data) == expectedDigest
        else { throw SetupOwnershipError.ownershipDrift(target) }
      }
    case .directorySymbolicLink:
      let target = Self.resolveSymlink(try originalLink(record), relativeTo: configurationDirectory)
      let descriptor = try PinnedFilesystem.openDirectory(at: target)
      defer { Darwin.close(descriptor) }
      var directoryIdentity = stat()
      guard fstat(descriptor, &directoryIdentity) == 0 else {
        throw posixError("pin skhd source directory", target)
      }
      let sourceURL = target.appending(path: "skhdrc")
      let manager = SetupOwnershipManager()
      let source = try manager.openPinnedRegularFile(
        parentDescriptor: descriptor,
        name: "skhdrc",
        url: sourceURL,
        label: "adopted directory skhd source"
      )
      defer { Darwin.close(source) }
      var sourceIdentity = stat()
      guard fstat(source, &sourceIdentity) == 0 else {
        throw posixError("pin directory skhd source", sourceURL)
      }
      try performPinnedOriginalSwap(
        record,
        parentDescriptor: parentDescriptor,
        sourceName: sourceName,
        claimName: claimName,
        url: url,
        operation: operation
      ) {
        var targetPathIdentity = stat()
        guard
          lstat(target.path, &targetPathIdentity) == 0,
          targetPathIdentity.st_mode & S_IFMT == S_IFDIR,
          targetPathIdentity.st_dev == directoryIdentity.st_dev,
          targetPathIdentity.st_ino == directoryIdentity.st_ino
        else { throw SetupOwnershipError.ownershipDrift(target) }
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
          throw posixError("rewind adopted skhd source directory", target)
        }
        let inventory = try PinnedFilesystem.directoryEntries(
          descriptor: descriptor,
          url: target,
          limit: 2
        )
        let path = try PinnedFilesystem.metadata(
          parentDescriptor: descriptor,
          name: "skhdrc",
          url: sourceURL
        )
        guard lseek(source, 0, SEEK_SET) == 0 else {
          throw posixError("rewind directory skhd source", sourceURL)
        }
        let file = try manager.readPinnedRegularFile(
          descriptor: source,
          url: sourceURL,
          label: "adopted directory skhd source"
        )
        let snapshot = try manager.regularFileSnapshot(
          descriptor: source,
          url: sourceURL,
          label: "adopted directory skhd source"
        )
        guard inventory.entries == record.originalInventory, !inventory.truncated else {
          throw SetupOwnershipError.ownershipDrift(target)
        }
        guard path.st_dev == sourceIdentity.st_dev, path.st_ino == sourceIdentity.st_ino else {
          throw SetupOwnershipError.ownershipDrift(sourceURL)
        }
        guard snapshot.linkCount == 1 else { throw SetupOwnershipError.ownershipDrift(sourceURL) }
        guard sha256Digest(file.data) == expectedDigest else {
          throw SetupOwnershipError.invalidConfiguration(
            KeybindingProviderInspector.ownershipID,
            sourceURL,
            "source digest changed during displacement"
          )
        }
      }
    }
  }

  private func performPinnedOriginalSwap(
    _ record: SetupOwnershipRecord,
    parentDescriptor: Int32,
    sourceName: String,
    claimName: String,
    url: URL,
    operation: () throws -> Void,
    verifySource: () throws -> Void
  ) throws {
    let pinned = try openClaim(parentDescriptor: parentDescriptor, name: sourceName, url: url)
    defer { Darwin.close(pinned) }
    var identity = stat()
    guard fstat(pinned, &identity) == 0 else { throw posixError("pin provider source", url) }
    func verifyPath(_ name: String) throws {
      let path = try PinnedFilesystem.metadata(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url.deletingLastPathComponent().appending(path: name)
      )
      guard
        path.st_dev == identity.st_dev,
        path.st_ino == identity.st_ino,
        path.st_mode & S_IFMT == identity.st_mode & S_IFMT,
        path.st_nlink == 1
      else { throw SetupOwnershipError.ownershipDrift(url) }
      try verifyDisplacedOriginal(
        record,
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
    }
    try verifySource()
    try verifyPath(sourceName)
    try operation()
    do {
      try faultInjector(.sourceSwapCompleted)
      try verifySource()
      try verifyPath(claimName)
    } catch {
      do {
        try operation()
        try verifyPath(sourceName)
      } catch let rollbackError {
        throw SetupOwnershipError.system(
          "restore provider path after source authentication failed",
          entry,
          "\(error); swap-back also failed: \(rollbackError)"
        )
      }
      throw error
    }
  }

  private func verifyDisplacedOriginal(
    _ record: SetupOwnershipRecord,
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws {
    let metadata = try PinnedFilesystem.metadata(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url.deletingLastPathComponent().appending(path: name)
    )
    guard try originalIdentityMatches(metadata, record: record) else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    switch originalKind(record) {
    case .regularFile:
      guard
        try regularOriginalMatches(
          record,
          parentDescriptor: parentDescriptor,
          name: name,
          url: url.deletingLastPathComponent().appending(path: name),
          allowMarker: false
        )
      else { throw SetupOwnershipError.ownershipDrift(url) }
    case .symbolicLink, .directorySymbolicLink:
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url.deletingLastPathComponent().appending(path: name)
      )
      guard destination == record.originalLinkDestination else {
        throw SetupOwnershipError.ownershipDrift(url)
      }
    case .absent:
      throw SetupOwnershipError.ownershipDrift(url)
    }
  }

  private func finalizeRestoredOriginal(
    _ record: SetupOwnershipRecord,
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws {
    let descriptor = try openClaim(parentDescriptor: parentDescriptor, name: name, url: url)
    defer { Darwin.close(descriptor) }
    guard try claimMarkerMatches(descriptor: descriptor, record: record, url: url) else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_nlink == 1 else {
      throw SetupOwnershipError.ownershipDrift(url)
    }
    if originalKind(record) == .regularFile {
      let manager = SetupOwnershipManager()
      let data = try manager.readPinnedRegularFile(
        descriptor: descriptor,
        url: url,
        label: "restored skhd entry"
      ).data
      let snapshot = try manager.regularFileSnapshot(
        descriptor: descriptor,
        url: url,
        label: "restored skhd entry",
        excludingExtendedAttribute: Self.claimMarkerAttribute
      )
      guard
        sha256Digest(data) == record.originalDigest,
        snapshot.linkCount == 1,
        snapshot.restorableMetadataDigest() == record.originalMetadataDigest
      else { throw SetupOwnershipError.ownershipDrift(url) }
    } else {
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
      guard destination == record.originalLinkDestination else {
        throw SetupOwnershipError.ownershipDrift(url)
      }
    }

    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    var records = try manager.readRecords(context: context)
    let updated = SetupOwnershipRecord(
      id: record.id,
      phase: record.phase,
      kind: record.kind,
      targetPath: record.targetPath,
      backupPath: record.backupPath,
      originalDigest: record.originalDigest,
      installedDigest: record.installedDigest,
      linkDestination: record.linkDestination,
      replacementDigest: record.replacementDigest,
      originalKind: record.originalKind,
      originalLinkDestination: record.originalLinkDestination,
      originalFileMode: record.originalFileMode,
      originalMetadataDigest: record.originalMetadataDigest,
      originalDevice: UInt64(metadata.st_dev),
      originalInode: UInt64(metadata.st_ino),
      originalSourceDigest: record.originalSourceDigest,
      originalInventory: record.originalInventory,
      claimNonce: record.claimNonce
    )
    try manager.save(record: updated, records: &records, context: context)
    try faultInjector(.restoredIdentityRecorded)
    try removeClaimMarker(
      descriptor: descriptor,
      parentDescriptor: parentDescriptor,
      name: name,
      record: updated,
      url: url
    )
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

  private func removeMarkedItem(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    try removePinnedItem(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      record: record
    ) {
      deletionName, deletionURL in
      guard
        try claimMarkerMatches(
          parentDescriptor: parentDescriptor,
          name: deletionName,
          record: record,
          url: deletionURL
        )
      else { throw SetupOwnershipError.ownershipDrift(deletionURL) }
    }
  }

  private func removeOriginalItem(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    try removePinnedItem(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      record: record
    ) {
      deletionName, deletionURL in
      try verifyDisplacedOriginal(
        record,
        parentDescriptor: parentDescriptor,
        name: deletionName,
        url: deletionURL
      )
    }
  }

  private func resumeProviderDeletionResidue(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL,
    directory: Bool = false
  ) throws {
    try resumeDeterministicDeletion(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      directory: directory,
      record: record
    ) { deletionName, deletionURL in
      // Forward displacement and rollback reuse this deterministic pathname.
      // Managed residue is marked; the displaced user original intentionally is not.
      if try claimMarkerMatches(
        parentDescriptor: parentDescriptor,
        name: deletionName,
        record: record,
        url: deletionURL
      ) {
        if directory {
          let descriptor = try PinnedFilesystem.openDirectory(
            parentDescriptor: parentDescriptor,
            name: deletionName,
            url: deletionURL
          )
          defer { Darwin.close(descriptor) }
          let inventory = try PinnedFilesystem.directoryEntries(
            descriptor: descriptor,
            url: deletionURL,
            limit: 1
          )
          guard inventory.entries.isEmpty, !inventory.truncated else {
            throw SetupOwnershipError.ownershipDrift(deletionURL)
          }
        }
        return
      }
      try verifyDisplacedOriginal(
        record,
        parentDescriptor: parentDescriptor,
        name: deletionName,
        url: deletionURL
      )
    }
  }

  private func removePinnedItem(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    directory: Bool = false,
    record: SetupOwnershipRecord,
    authenticate: (String, URL) throws -> Void
  ) throws {
    try resumeDeterministicDeletion(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      directory: directory,
      record: record,
      authenticate: authenticate
    )
    guard try itemExists(parentDescriptor: parentDescriptor, name: name, url: url) else { return }
    let deletionName = try deletionName(name, record: record)
    let deletionURL = url.deletingLastPathComponent().appending(path: deletionName)
    try authenticate(name, url)
    let pinned = try openClaim(parentDescriptor: parentDescriptor, name: name, url: url)
    defer { Darwin.close(pinned) }
    var identity = stat()
    guard fstat(pinned, &identity) == 0 else { throw posixError("pin deletion source", url) }
    try faultInjector(.deletionSourcePinned)

    let moved = name.withCString { source in
      deletionName.withCString { destination in
        Darwin.renameatx_np(
          parentDescriptor,
          source,
          parentDescriptor,
          destination,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard moved == 0 else { throw posixError("claim keybinding item for deletion", url) }
    try sync(parentDescriptor, url: url.deletingLastPathComponent())
    try faultInjector(.deletionCandidatePublished)
    do {
      let movedMetadata = try PinnedFilesystem.metadata(
        parentDescriptor: parentDescriptor,
        name: deletionName,
        url: deletionURL
      )
      guard
        movedMetadata.st_dev == identity.st_dev,
        movedMetadata.st_ino == identity.st_ino,
        movedMetadata.st_mode & S_IFMT == identity.st_mode & S_IFMT
      else { throw SetupOwnershipError.ownershipDrift(url) }
      try authenticate(deletionName, deletionURL)
      try deletePinnedCandidate(
        parentDescriptor: parentDescriptor,
        name: deletionName,
        url: deletionURL,
        directory: directory,
        expectedIdentity: identity,
        authenticate: authenticate
      )
    } catch {
      let restored = deletionName.withCString { source in
        name.withCString { destination in
          Darwin.renameatx_np(
            parentDescriptor,
            source,
            parentDescriptor,
            destination,
            UInt32(RENAME_EXCL)
          )
        }
      }
      if restored == 0 {
        try sync(parentDescriptor, url: url.deletingLastPathComponent())
        throw error
      }
      throw SetupOwnershipError.system(
        "restore unauthenticated deletion candidate",
        deletionURL,
        "\(error); candidate preserved after restore failed: \(String(cString: strerror(errno)))"
      )
    }
  }

  private func resumeDeterministicDeletion(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    directory: Bool,
    record: SetupOwnershipRecord,
    authenticate: (String, URL) throws -> Void
  ) throws {
    let deletionName = try deletionName(name, record: record)
    let deletionURL = url.deletingLastPathComponent().appending(path: deletionName)
    guard
      try itemExists(
        parentDescriptor: parentDescriptor,
        name: deletionName,
        url: deletionURL
      )
    else { return }
    try deletePinnedCandidate(
      parentDescriptor: parentDescriptor,
      name: deletionName,
      url: deletionURL,
      directory: directory,
      authenticate: authenticate
    )
  }

  private func deletePinnedCandidate(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    directory: Bool,
    expectedIdentity: stat? = nil,
    authenticate: (String, URL) throws -> Void
  ) throws {
    let pinned = try openClaim(parentDescriptor: parentDescriptor, name: name, url: url)
    defer { Darwin.close(pinned) }
    var identity = stat()
    guard fstat(pinned, &identity) == 0 else { throw posixError("pin deletion candidate", url) }
    if let expectedIdentity {
      guard
        identity.st_dev == expectedIdentity.st_dev,
        identity.st_ino == expectedIdentity.st_ino,
        identity.st_mode & S_IFMT == expectedIdentity.st_mode & S_IFMT
      else { throw SetupOwnershipError.ownershipDrift(url) }
    }
    try authenticate(name, url)
    try faultInjector(.deletionCandidateAuthenticated)
    let path = try PinnedFilesystem.metadata(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    guard
      path.st_dev == identity.st_dev,
      path.st_ino == identity.st_ino,
      path.st_mode & S_IFMT == identity.st_mode & S_IFMT
    else { throw SetupOwnershipError.ownershipDrift(url) }
    let flags = directory ? AT_REMOVEDIR : 0
    guard name.withCString({ Darwin.unlinkat(parentDescriptor, $0, flags) }) == 0 else {
      throw posixError("remove authenticated keybinding item", url)
    }
    try sync(parentDescriptor, url: url.deletingLastPathComponent())
  }

  private func deletionName(_ name: String, record: SetupOwnershipRecord) throws -> String {
    ".\(name).deleting-\(try residueNonce(record))"
  }

  private func residueNonce(_ record: SetupOwnershipRecord) throws -> String {
    if let nonce = record.claimNonce { return nonce }
    if KeybindingProviderInspector.isLegacyCleanInstallRecord(record) {
      return "legacy-clean-install"
    }
    throw SetupOwnershipError.invalidManifest("keybinding claim nonce is missing")
  }

  private func itemExists(parentDescriptor: Int32, name: String, url: URL) throws -> Bool {
    do {
      _ = try PinnedFilesystem.metadata(parentDescriptor: parentDescriptor, name: name, url: url)
      return true
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return false
    }
  }

  private func rename(descriptor: Int32, from: String, to: String, url: URL) throws {
    let result = from.withCString { source in
      to.withCString { destination in Darwin.renameat(descriptor, source, descriptor, destination) }
    }
    guard result == 0 else { throw posixError("rename keybinding provider item", url) }
    try sync(descriptor, url: url.deletingLastPathComponent())
  }

  private func swap(descriptor: Int32, first: String, second: String, url: URL) throws {
    for name in [first, second] {
      let metadata = try PinnedFilesystem.metadata(
        parentDescriptor: descriptor,
        name: name,
        url: url.deletingLastPathComponent().appending(path: name)
      )
      if metadata.st_mode & S_IFMT != S_IFDIR, metadata.st_nlink != 1 {
        throw SetupOwnershipError.ownershipDrift(url)
      }
    }
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
    for name in [first, second] {
      let metadata = try PinnedFilesystem.metadata(
        parentDescriptor: descriptor,
        name: name,
        url: url.deletingLastPathComponent().appending(path: name)
      )
      if metadata.st_mode & S_IFMT != S_IFDIR, metadata.st_nlink != 1 {
        throw SetupOwnershipError.ownershipDrift(url)
      }
    }
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

extension SetupOwnershipRecord {
  fileprivate func withPhase(_ phase: Phase) -> Self {
    Self(
      id: id,
      phase: phase,
      kind: kind,
      targetPath: targetPath,
      backupPath: backupPath,
      originalDigest: originalDigest,
      installedDigest: installedDigest,
      linkDestination: linkDestination,
      replacementDigest: replacementDigest,
      originalKind: originalKind,
      originalLinkDestination: originalLinkDestination,
      originalFileMode: originalFileMode,
      originalMetadataDigest: originalMetadataDigest,
      originalDevice: originalDevice,
      originalInode: originalInode,
      originalSourceDigest: originalSourceDigest,
      originalInventory: originalInventory,
      claimNonce: claimNonce
    )
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
      originalSourceDigest: kind == .absent ? nil : sourceDigest,
      originalInventory: kind == .absent ? nil : inventory,
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
