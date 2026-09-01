import Darwin
import Foundation
import ThemeCore

extension KeybindingProviderTransaction {
  func originalKind(_ record: SetupOwnershipRecord) -> SetupOwnershipRecord.OriginalKind {
    record.originalKind ?? .absent
  }

  func retainsOriginalSymlink(_ record: SetupOwnershipRecord) -> Bool {
    record.retainedOriginalPath != nil
      && [.symbolicLink, .directorySymbolicLink].contains(originalKind(record))
  }

  func originalLink(_ record: SetupOwnershipRecord) throws -> String {
    guard let destination = record.originalLinkDestination else {
      throw SetupOwnershipError.invalidManifest("keybinding adoption link text is missing")
    }
    return destination
  }

  func originalMode(_ record: SetupOwnershipRecord) throws -> UInt16 {
    guard let mode = record.originalFileMode else {
      throw SetupOwnershipError.invalidManifest("keybinding adoption file mode is missing")
    }
    return mode
  }

  func claimName(_ record: SetupOwnershipRecord, directory: Bool) -> String {
    let prefix = directory ? ".skhd.macarchy-keybindings" : ".skhdrc.macarchy-keybindings"
    return "\(prefix)-\(record.claimNonce ?? "invalid")"
  }

  func verifyPinnedUntouchedOriginal(
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

  func backupExists() throws -> Bool {
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

  func backupDeletionResidueExists(_ record: SetupOwnershipRecord) throws -> Bool {
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

  func removeAuthenticatedProviderResidues(_ record: SetupOwnershipRecord) throws {
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

  func removeAuthenticatedBackup(
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

  func removeBackupPublicationResidue(_ record: SetupOwnershipRecord) throws {
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

  func openBackupDirectory(create: Bool) throws -> Int32 {
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
      if create {
        next = try PinnedFilesystem.openOrCreateChildDirectory(
          parentDescriptor: parent,
          name: component,
          url: currentURL,
          mode: 0o700
        )
      } else {
        next = try PinnedFilesystem.openDirectory(
          parentDescriptor: parent,
          name: component,
          url: currentURL
        )
      }
      Darwin.close(parent)
      parent = next
    }
    return parent
  }

  func createSymlink(
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

  func publishingName(_ name: String, record: SetupOwnershipRecord) throws -> String {
    "\(name).publishing-\(try residueNonce(record))"
  }

  func authenticatedPublicationExists(
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

  func publish(
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

  func originalIdentityMatches(
    _ metadata: stat,
    record: SetupOwnershipRecord
  ) throws -> Bool {
    guard let device = record.originalDevice, let inode = record.originalInode else {
      throw SetupOwnershipError.invalidManifest("keybinding original identity is missing")
    }
    return UInt64(metadata.st_dev) == device && UInt64(metadata.st_ino) == inode
      && metadata.st_nlink == 1
  }

  func regularOriginalMatches(
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

  func withAuthenticatedOriginalSource(
    _ record: SetupOwnershipRecord,
    parentDescriptor: Int32,
    sourceName: String,
    claimName: String,
    url: URL,
    operation: () throws -> Void,
    emitSwapCheckpoint: Bool = true
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
      let target = KeybindingProviderPrimitives.resolveSymlink(
        try originalLink(record),
        relativeTo: directory
      )
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
        operation: operation,
        emitSwapCheckpoint: emitSwapCheckpoint
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
      let target = KeybindingProviderPrimitives.resolveSymlink(
        try originalLink(record),
        relativeTo: configurationDirectory
      )
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
        operation: operation,
        emitSwapCheckpoint: emitSwapCheckpoint
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
    emitSwapCheckpoint: Bool = true,
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
      if emitSwapCheckpoint { try faultInjector(.sourceSwapCompleted) }
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

  func verifyDisplacedOriginal(
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

  func authenticateOriginalSymlinkAtPath(
    _ record: SetupOwnershipRecord,
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws {
    guard [.symbolicLink, .directorySymbolicLink].contains(originalKind(record)) else {
      throw SetupOwnershipError.invalidManifest(
        "retained keybinding original is not a symbolic link"
      )
    }
    try withAuthenticatedOriginalSource(
      record,
      parentDescriptor: parentDescriptor,
      sourceName: name,
      claimName: name,
      url: url,
      operation: {},
      emitSwapCheckpoint: false
    )
  }

  func finalizeRestoredOriginal(
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
      retainedOriginalPath: record.retainedOriginalPath,
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

  func claimMarkerMatches(
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

  func claimMarkerMatches(
    descriptor: Int32,
    record: SetupOwnershipRecord,
    url: URL
  ) throws -> Bool {
    guard let nonce = record.claimNonce else {
      throw SetupOwnershipError.invalidManifest("keybinding claim nonce is missing")
    }
    do {
      return try KeybindingProviderPrimitives.claimMarkerMatches(
        descriptor: descriptor,
        nonce: nonce
      )
    } catch let failure as KeybindingProviderPrimitives.POSIXFailure {
      throw posixError("read keybinding claim marker", url, code: failure.code)
    }
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

  func markClaim(
    descriptor: Int32,
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    guard let nonce = record.claimNonce else {
      throw SetupOwnershipError.invalidManifest("keybinding claim nonce is missing")
    }
    do {
      try KeybindingProviderPrimitives.createClaimMarker(
        descriptor: descriptor,
        nonce: nonce
      )
    } catch let failure as KeybindingProviderPrimitives.POSIXFailure {
      throw posixError("authenticate keybinding claim", url, code: failure.code)
    }
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
    do {
      try KeybindingProviderPrimitives.removeClaimMarker(descriptor: descriptor)
    } catch let failure as KeybindingProviderPrimitives.POSIXFailure {
      throw posixError("remove keybinding claim marker", url, code: failure.code)
    }
    guard fsync(descriptor) == 0 else { throw posixError("sync keybinding claim", url) }
    try sync(parentDescriptor, url: url.deletingLastPathComponent())
  }

  func openClaim(parentDescriptor: Int32, name: String, url: URL) throws -> Int32 {
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

  func sync(_ descriptor: Int32, url: URL) throws {
    guard fsync(descriptor) == 0 else { throw posixError("sync keybinding provider", url) }
  }

  func posixError(_ operation: String, _ url: URL) -> SetupOwnershipError {
    .system(operation, url, String(cString: strerror(errno)))
  }

  func posixError(
    _ operation: String,
    _ url: URL,
    code: Int32
  ) -> SetupOwnershipError {
    .system(operation, url, String(cString: strerror(code)))
  }
}
