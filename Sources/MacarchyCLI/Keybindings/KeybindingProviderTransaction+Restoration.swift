import Darwin
import Foundation
import ThemeCore

extension KeybindingProviderTransaction {
  func ensureRegularBackup(
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
      name: SkhdLayout.configurationName,
      url: entry,
      maximumSize: SetupOwnershipManager.maximumConfigurationSize
    ).data
    try writeOriginalBackup(data, record: record, manager: manager)
  }

  /// Puts the managed claim at the live name and settles the displaced original. Leaf and
  /// directory claims follow the same steps; they differ only in how an item is inspected,
  /// created and removed, and in how an incomplete claim is resumed.
  func replaceOriginalWithManaged(_ record: SetupOwnershipRecord) throws {
    let level = claimLevel(record)
    let liveName = SkhdLayout.liveName(level)
    let live = layout.live(level)
    let parentURL = layout.parent(level)
    let descriptor = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(descriptor) }
    let claim = claimName(record, level)
    try resumeProviderDeletionResidue(
      parentDescriptor: descriptor,
      name: claim,
      record: record,
      url: parentURL.appending(path: claim),
      directory: level == .directory
    )
    let state = try itemState(level, descriptor: descriptor, name: liveName, record: record)
    var claimState = try itemState(
      level,
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true
    )
    if claimState == .incomplete {
      switch level {
      case .leaf:
        // An incomplete leaf claim is discarded and created again below.
        try removeMarkedItem(
          parentDescriptor: descriptor, name: claim, record: record, url: live)
        claimState = .missing
      case .directory:
        // An incomplete directory claim is completed in place.
        try createManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
        claimState = try directoryState(descriptor: descriptor, name: claim, record: record)
      }
    }
    if state == .managed {
      if claimState == .original {
        try settleDisplacedOriginal(record, descriptor: descriptor, claim: claim, url: live)
      }
      guard claimState == .missing || claimState == .original else {
        throw SetupOwnershipError.ownershipDrift(live)
      }
      return
    }
    if state == .original, claimState == .managed {
      try displaceOriginal(
        record, descriptor: descriptor, liveName: liveName, claim: claim, url: live)
      try settleDisplacedOriginal(record, descriptor: descriptor, claim: claim, url: live)
      return
    }
    guard state == .original || (state == .missing && originalKind(record) == .absent),
      claimState == .missing
    else { throw SetupOwnershipError.ownershipDrift(live) }
    switch level {
    case .leaf:
      try createSymlink(
        descriptor: descriptor,
        name: claim,
        destination: SkhdLayout.managedTarget,
        url: live,
        record: record
      )
    case .directory:
      try createManagedDirectory(parentDescriptor: descriptor, name: claim, record: record)
    }
    if state == .missing {
      try rename(descriptor: descriptor, from: claim, to: liveName, url: live)
    } else {
      try displaceOriginal(
        record, descriptor: descriptor, liveName: liveName, claim: claim, url: live)
      guard
        try itemState(level, descriptor: descriptor, name: claim, record: record) == .original
      else { throw SetupOwnershipError.ownershipDrift(live) }
      try settleDisplacedOriginal(record, descriptor: descriptor, claim: claim, url: live)
    }
  }

  /// Puts the original back at the live name and removes the managed claim. Only a leaf
  /// restoration re-reads the ownership record and verifies the restored original afterwards.
  func restoreOriginal(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    let level = claimLevel(record)
    let verifiesRestoredOriginal = level == .leaf
    if retainsOriginalSymlink(record) {
      try restoreRetainedOriginalSymlink(record, level: level)
      if verifiesRestoredOriginal {
        try verifyOriginal(try ownershipRecord().0, context: context)
      }
      return
    }
    let liveName = SkhdLayout.liveName(level)
    let live = layout.live(level)
    let parentURL = layout.parent(level)
    let descriptor = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(descriptor) }
    let claim = claimName(record, level)
    try resumeProviderDeletionResidue(
      parentDescriptor: descriptor,
      name: claim,
      record: record,
      url: parentURL.appending(path: claim),
      directory: level == .directory
    )
    let state = try itemState(level, descriptor: descriptor, name: liveName, record: record)
    var claimState = try itemState(
      level,
      descriptor: descriptor,
      name: claim,
      record: record,
      recognizeIncompleteClaim: true
    )
    if claimState == .incomplete {
      try removeClaimItem(
        level, parentDescriptor: descriptor, name: claim, record: record, url: live)
      claimState = .missing
    }
    if state == .original || (state == .missing && originalKind(record) == .absent) {
      if claimState == .managed {
        try removeClaimItem(
          level, parentDescriptor: descriptor, name: claim, record: record, url: live)
      }
      guard claimState == .missing || claimState == .managed else {
        throw SetupOwnershipError.ownershipDrift(live)
      }
      if state == .original,
        try claimMarkerMatches(
          parentDescriptor: descriptor,
          name: liveName,
          record: record,
          url: live
        )
      {
        try finalizeRestoredOriginal(
          record,
          parentDescriptor: descriptor,
          name: liveName,
          url: live
        )
      }
      return
    }
    if state == .managed, claimState == .original {
      try publishRestoredOriginal(
        record, descriptor: descriptor, liveName: liveName, claim: claim, url: live)
      try removeClaimItem(
        level, parentDescriptor: descriptor, name: claim, record: record, url: live)
      return
    }
    guard state == .managed, claimState == .missing else {
      throw SetupOwnershipError.ownershipDrift(live)
    }
    switch originalKind(record) {
    case .absent:
      try rename(descriptor: descriptor, from: liveName, to: claim, url: live)
      try faultInjector(.managedEntryClaimedForRemoval)
    case .regularFile:
      try restoreRegularFileClaim(record, descriptor: descriptor, name: claim)
      try publishRestoredOriginal(
        record, descriptor: descriptor, liveName: liveName, claim: claim, url: live)
    case .symbolicLink, .directorySymbolicLink:
      try createSymlink(
        descriptor: descriptor,
        name: claim,
        destination: try originalLink(record),
        url: live,
        record: record
      )
      try publishRestoredOriginal(
        record, descriptor: descriptor, liveName: liveName, claim: claim, url: live)
    }
    try removeClaimItem(
      level, parentDescriptor: descriptor, name: claim, record: record, url: live)
    if verifiesRestoredOriginal {
      try verifyOriginal(try ownershipRecord().0, context: context)
    }
  }

  func verifyOriginal(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    let level = claimLevel(record)
    let liveName = SkhdLayout.liveName(level)
    let live = layout.live(level)
    let descriptor = try PinnedFilesystem.openDirectory(at: layout.parent(level))
    defer { Darwin.close(descriptor) }
    let state = try itemState(level, descriptor: descriptor, name: liveName, record: record)
    guard state == .original || (state == .missing && originalKind(record) == .absent) else {
      throw SetupOwnershipError.ownershipDrift(live)
    }
    if [.symbolicLink, .directorySymbolicLink].contains(originalKind(record)) {
      try authenticateOriginalSymlinkAtPath(
        record,
        parentDescriptor: descriptor,
        name: liveName,
        url: live
      )
    }
  }

  private func restoreRetainedOriginalSymlink(
    _ record: SetupOwnershipRecord,
    level: SkhdLayout.Level
  ) throws {
    let parentURL = layout.parent(level)
    let liveName = SkhdLayout.liveName(level)
    let liveURL = layout.live(level)
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    let claim = claimName(record, level)
    func state(_ name: String, recognizeIncompleteClaim: Bool = false) throws -> ProviderItemState {
      try itemState(
        level,
        descriptor: parent,
        name: name,
        record: record,
        recognizeIncompleteClaim: recognizeIncompleteClaim
      )
    }
    func removeClaim(_ name: String) throws {
      try removeClaimItem(
        level,
        parentDescriptor: parent,
        name: name,
        record: record,
        url: parentURL.appending(path: name)
      )
    }
    let liveState = try state(liveName)
    var claimState = try state(claim, recognizeIncompleteClaim: true)
    if liveState == .original, claimState == .incomplete {
      try removeClaim(claim)
      claimState = .missing
    }
    if liveState == .original, claimState == .missing {
      try removeClaim(publishingName(claim, record: record))
      try authenticateOriginalSymlinkAtPath(
        record,
        parentDescriptor: parent,
        name: liveName,
        url: liveURL
      )
      return
    }
    if liveState == .managed, claimState == .original {
      try preflightRetainedOriginalClaim(record)
      try swap(descriptor: parent, first: liveName, second: claim, url: liveURL)
      try faultInjector(.restoredOriginalPublished)
    } else {
      guard liveState == .original, claimState == .managed else {
        throw SetupOwnershipError.ownershipDrift(liveURL)
      }
    }
    try authenticateOriginalSymlinkAtPath(
      record,
      parentDescriptor: parent,
      name: liveName,
      url: liveURL
    )
    guard try state(claim) == .managed else { throw SetupOwnershipError.ownershipDrift(liveURL) }
  }

  /// The state of `name` beside the live item at `level`.
  func itemState(
    _ level: SkhdLayout.Level,
    descriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    recognizeIncompleteClaim: Bool = false
  ) throws -> ProviderItemState {
    switch level {
    case .leaf:
      try leafState(
        descriptor: descriptor,
        name: name,
        record: record,
        recognizeIncompleteClaim: recognizeIncompleteClaim
      )
    case .directory:
      try directoryState(
        descriptor: descriptor,
        name: name,
        record: record,
        recognizeIncompleteClaim: recognizeIncompleteClaim
      )
    }
  }

  /// Removes the authenticated managed item `name` at `level`. A leaf removal is reported
  /// against `url`; a directory must hold nothing but the managed link.
  func removeClaimItem(
    _ level: SkhdLayout.Level,
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL
  ) throws {
    switch level {
    case .leaf:
      try removeMarkedItem(
        parentDescriptor: parentDescriptor, name: name, record: record, url: url)
    case .directory:
      try removeManagedDirectory(parentDescriptor: parentDescriptor, name: name, record: record)
    }
  }

  func leafState(
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
      if destination == SkhdLayout.managedTarget {
        return markerMatches ? .managed : .other
      }
      if originalKind(record) == .symbolicLink,
        destination == record.originalLinkDestination
      {
        if try markerMatches || originalIdentityMatches(metadata, url: url, record: record) {
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

  func directoryState(
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
      return try markerMatches || originalIdentityMatches(metadata, url: url, record: record)
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
    guard inventory.entries == [SkhdLayout.configurationName], !inventory.truncated else {
      return .other
    }
    let target = try PinnedFilesystem.symlinkDestination(
      parentDescriptor: directoryDescriptor,
      name: SkhdLayout.configurationName,
      url: url.appending(path: SkhdLayout.configurationName)
    )
    return target == SkhdLayout.managedTarget ? .managed : .other
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
    if inventory.entries == [SkhdLayout.configurationName], !inventory.truncated {
      guard
        try leafState(
          descriptor: descriptor,
          name: SkhdLayout.configurationName,
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
      name: SkhdLayout.configurationName,
      destination: SkhdLayout.managedTarget,
      url: (needsPublication ? publicationURL : url).appending(path: SkhdLayout.configurationName),
      record: record
    )
    try faultInjector(.directoryClaimPopulated)
    if needsPublication {
      try publish(parentDescriptor: parentDescriptor, from: publicationName, to: name, url: url)
      try faultInjector(.directoryClaimCreated)
    }
  }

  /// Moves the authenticated original to `claim` so the managed claim takes the live name.
  private func displaceOriginal(
    _ record: SetupOwnershipRecord,
    descriptor: Int32,
    liveName: String,
    claim: String,
    url: URL
  ) throws {
    try faultInjector(.providerClaimReady)
    if originalKind(record) == .regularFile {
      try displacePinnedRegularOriginal(record, descriptor: descriptor, claim: claim)
      return
    }
    try withAuthenticatedOriginalSource(
      record,
      parentDescriptor: descriptor,
      sourceName: liveName,
      claimName: claim,
      url: url
    ) {
      try swap(descriptor: descriptor, first: liveName, second: claim, url: url)
    }
    try faultInjector(.providerClaimSwapped)
  }

  /// Keeps a retained original symlink's claim, or removes the displaced original.
  private func settleDisplacedOriginal(
    _ record: SetupOwnershipRecord,
    descriptor: Int32,
    claim: String,
    url: URL
  ) throws {
    if retainsOriginalSymlink(record) {
      try preflightRetainedOriginalClaim(record)
    } else {
      try removeOriginalItem(parentDescriptor: descriptor, name: claim, record: record, url: url)
    }
  }

  /// Swaps the restored original back to the live name and records its restored identity.
  private func publishRestoredOriginal(
    _ record: SetupOwnershipRecord,
    descriptor: Int32,
    liveName: String,
    claim: String,
    url: URL
  ) throws {
    try swap(descriptor: descriptor, first: liveName, second: claim, url: url)
    try faultInjector(.restoredOriginalPublished)
    try finalizeRestoredOriginal(record, parentDescriptor: descriptor, name: liveName, url: url)
  }

  private func displacePinnedRegularOriginal(
    _ record: SetupOwnershipRecord,
    descriptor: Int32,
    claim: String
  ) throws {
    let manager = SetupOwnershipManager()
    let current = try manager.openPinnedRegularFile(
      parentDescriptor: descriptor,
      name: SkhdLayout.configurationName,
      url: entry,
      label: "skhd entry"
    )
    defer { Darwin.close(current) }
    let stored = try readOriginalBackup(record, manager: manager)
    let (file, before) = try manager.readPinnedRegularFileSnapshot(
      descriptor: current,
      url: entry,
      label: "skhd entry"
    )
    guard
      file.data == stored.data,
      before.device == record.originalDevice,
      before.inode == record.originalInode,
      before.linkCount == 1,
      before.flags & Self.unsupportedRestorationFlags == 0,
      before.mode & 0o7777 == UInt32(try originalMode(record)),
      before.hasCopiedMetadataIgnoringMode(from: stored.snapshot),
      before.restorableMetadataDigest() == record.originalMetadataDigest
    else { throw SetupOwnershipError.ownershipDrift(entry) }

    try faultInjector(.regularOriginalPinned)
    try swap(descriptor: descriptor, first: SkhdLayout.configurationName, second: claim, url: entry)
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
        try swap(
          descriptor: descriptor, first: SkhdLayout.configurationName, second: claim, url: entry)
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
    guard claim >= 0 else {
      throw SetupOwnershipError.posix("create restored skhd entry", publicationURL)
    }
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
      throw SetupOwnershipError.posix("restore skhd entry metadata", publicationURL)
    }
    guard fchmod(claim, mode_t(try originalMode(record))) == 0 else {
      throw SetupOwnershipError.posix("restore skhd entry permissions", publicationURL)
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
    guard fsync(claim) == 0 else {
      throw SetupOwnershipError.posix("sync restored skhd entry", publicationURL)
    }
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

  func removeManagedDirectory(
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
      let nestedPublication = try publishingName(SkhdLayout.configurationName, record: record)
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
      if inventory.entries == [SkhdLayout.configurationName] {
        guard
          try leafState(
            descriptor: descriptor,
            name: SkhdLayout.configurationName,
            record: record
          ) == .managed
        else {
          throw SetupOwnershipError.ownershipDrift(url)
        }
        try removeMarkedItem(
          parentDescriptor: descriptor,
          name: SkhdLayout.configurationName,
          record: record,
          url: url.appending(path: SkhdLayout.configurationName)
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
}
