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
  static let claimMarkerAttribute = KeybindingProviderPrimitives.claimMarkerAttribute
  static let unsupportedRestorationFlags =
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

  var configurationDirectory: URL {
    homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
  }

  var directory: URL {
    configurationDirectory.appending(path: "skhd", directoryHint: .isDirectory)
  }

  var entry: URL {
    directory.appending(path: "skhdrc")
  }

  var backup: URL {
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
      let retainedStateIsRecoverable =
        !retainsOriginalSymlink(record)
        || (state == .managed && claim == .original)
        || (state == .original && claim == .managed)
      guard
        [.managed, .original].contains(state), claim != .other,
        retainedStateIsRecoverable
      else {
        throw SetupOwnershipError.ownershipDrift(directory)
      }
      if retainsOriginalSymlink(record) {
        if state == .managed {
          try preflightRetainedOriginalClaim(record)
        } else {
          try authenticateOriginalSymlinkAtPath(
            record,
            parentDescriptor: descriptor,
            name: "skhd",
            url: directory
          )
        }
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
      let retainedStateIsRecoverable =
        !retainsOriginalSymlink(record)
        || (state == .managed && claim == .original)
        || (state == .original && claim == .managed)
      guard stateIsRecoverable, claim != .other, retainedStateIsRecoverable else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      if retainsOriginalSymlink(record) {
        if state == .managed {
          try preflightRetainedOriginalClaim(record)
        } else {
          try authenticateOriginalSymlinkAtPath(
            record,
            parentDescriptor: descriptor,
            name: "skhdrc",
            url: entry
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
  }

  func preflightOriginalRestorationFinalization() throws {
    let (record, _, context) = try ownershipRecord()
    guard retainsOriginalSymlink(record) else {
      try preflightOriginalRestoration()
      return
    }
    try requireLegacyClaimAbsent(for: record)
    try verifyOriginal(record, context: context)
    let isDirectory = originalKind(record) == .directorySymbolicLink
    let parentURL = isDirectory ? configurationDirectory : directory
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    let claim = claimName(record, directory: isDirectory)
    let claimState =
      if isDirectory {
        try directoryState(descriptor: parent, name: claim, record: record)
      } else {
        try leafState(descriptor: parent, name: claim, record: record)
      }
    let deletionResidueExists = try preflightProviderDeletionResidue(
      parentDescriptor: parent,
      name: claim,
      record: record,
      url: parentURL.appending(path: claim),
      directory: isDirectory
    )
    guard
      (claimState == .managed && !deletionResidueExists)
        || (claimState == .missing)
    else {
      throw SetupOwnershipError.ownershipDrift(parentURL.appending(path: claim))
    }
  }

  func preflightManagedRestoration() throws {
    try preflightOriginalRestoration()
  }

  func preflightRetainedOriginalClaim(_ record: SetupOwnershipRecord) throws {
    guard retainsOriginalSymlink(record) else { return }
    let isDirectory = originalKind(record) == .directorySymbolicLink
    let parentURL = isDirectory ? configurationDirectory : directory
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    let name = claimName(record, directory: isDirectory)
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
      name: "skhd",
      url: directory
    )
    if directoryMetadata.st_mode & S_IFMT == S_IFLNK {
      try KeybindingProviderInspector.requireAdoptableSymlink(
        directoryMetadata,
        parentDescriptor: configurationDescriptor,
        name: "skhd",
        url: directory
      )
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: configurationDescriptor,
        name: "skhd",
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
      try KeybindingProviderInspector.requireAdoptableSymlink(
        metadata,
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
        url: entry
      )
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
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

  var legacyRestorationName: String {
    ".skhdrc.macarchy-legacy-restoration"
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
    let nonce = UUID().uuidString.lowercased()
    let retainedOriginalPath: String? =
      switch kind {
      case .symbolicLink:
        entry.deletingLastPathComponent().appending(
          path: ".skhdrc.macarchy-keybindings-\(nonce)"
        ).path
      case .directorySymbolicLink:
        entry.deletingLastPathComponent().deletingLastPathComponent().appending(
          path: ".skhd.macarchy-keybindings-\(nonce)"
        ).path
      case .absent, .regularFile:
        nil
      }
    return SetupOwnershipRecord(
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
