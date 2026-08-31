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
      name: "skhdrc",
      url: entry,
      maximumSize: SetupOwnershipManager.maximumConfigurationSize
    ).data
    try writeOriginalBackup(data, record: record, manager: manager)
  }

  func replaceOriginalWithManaged(_ record: SetupOwnershipRecord) throws {
    switch originalKind(record) {
    case .directorySymbolicLink:
      try replaceOriginalDirectoryWithManaged(record)
    case .absent, .regularFile, .symbolicLink:
      try replaceOriginalLeafWithManaged(record)
    }
  }

  func replaceOriginalLeafWithManaged(_ record: SetupOwnershipRecord) throws {
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
        if retainsOriginalSymlink(record) {
          try preflightRetainedOriginalClaim(record)
        } else {
          try removeOriginalItem(
            parentDescriptor: descriptor, name: claim, record: record, url: entry)
        }
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
      if retainsOriginalSymlink(record) {
        try preflightRetainedOriginalClaim(record)
      } else {
        try removeOriginalItem(
          parentDescriptor: descriptor, name: claim, record: record, url: entry)
      }
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
      if retainsOriginalSymlink(record) {
        try preflightRetainedOriginalClaim(record)
      } else {
        try removeOriginalItem(
          parentDescriptor: descriptor, name: claim, record: record, url: entry)
      }
    }
  }

  func restoreOriginalLeaf(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    if retainsOriginalSymlink(record) {
      try restoreRetainedOriginalSymlink(record, directoryLevel: false)
      try verifyOriginal(try ownershipRecord().0, context: context)
      return
    }
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

  func replaceOriginalDirectoryWithManaged(_ record: SetupOwnershipRecord) throws {
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
        if retainsOriginalSymlink(record) {
          try preflightRetainedOriginalClaim(record)
        } else {
          try removeOriginalItem(
            parentDescriptor: descriptor, name: claim, record: record, url: directory)
        }
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
      if retainsOriginalSymlink(record) {
        try preflightRetainedOriginalClaim(record)
      } else {
        try removeOriginalItem(
          parentDescriptor: descriptor, name: claim, record: record, url: directory)
      }
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
    if retainsOriginalSymlink(record) {
      try preflightRetainedOriginalClaim(record)
    } else {
      try removeOriginalItem(
        parentDescriptor: descriptor, name: claim, record: record, url: directory)
    }
  }

  func restoreOriginalDirectory(_ record: SetupOwnershipRecord) throws {
    if retainsOriginalSymlink(record) {
      try restoreRetainedOriginalSymlink(record, directoryLevel: true)
      return
    }
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

  func verifyOriginal(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    switch originalKind(record) {
    case .directorySymbolicLink:
      let descriptor = try PinnedFilesystem.openDirectory(at: configurationDirectory)
      defer { Darwin.close(descriptor) }
      guard try directoryState(descriptor: descriptor, name: "skhd", record: record) == .original
      else { throw SetupOwnershipError.ownershipDrift(directory) }
      try authenticateOriginalSymlinkAtPath(
        record,
        parentDescriptor: descriptor,
        name: "skhd",
        url: directory
      )
    case .absent, .regularFile, .symbolicLink:
      let descriptor = try PinnedFilesystem.openDirectory(at: directory)
      defer { Darwin.close(descriptor) }
      let state = try leafState(descriptor: descriptor, name: "skhdrc", record: record)
      guard state == .original || (state == .missing && originalKind(record) == .absent) else {
        throw SetupOwnershipError.ownershipDrift(entry)
      }
      if originalKind(record) == .symbolicLink {
        try authenticateOriginalSymlinkAtPath(
          record,
          parentDescriptor: descriptor,
          name: "skhdrc",
          url: entry
        )
      }
    }
  }

  func restoreRetainedOriginalSymlink(
    _ record: SetupOwnershipRecord,
    directoryLevel: Bool
  ) throws {
    let parentURL = directoryLevel ? configurationDirectory : directory
    let liveName = directoryLevel ? "skhd" : "skhdrc"
    let liveURL = directoryLevel ? directory : entry
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    let claim = claimName(record, directory: directoryLevel)
    let liveState: ProviderItemState
    if directoryLevel {
      liveState = try directoryState(
        descriptor: parent,
        name: liveName,
        record: record
      )
    } else {
      liveState = try leafState(
        descriptor: parent,
        name: liveName,
        record: record
      )
    }
    var claimState: ProviderItemState
    if directoryLevel {
      claimState = try directoryState(
        descriptor: parent,
        name: claim,
        record: record,
        recognizeIncompleteClaim: true
      )
    } else {
      claimState = try leafState(
        descriptor: parent,
        name: claim,
        record: record,
        recognizeIncompleteClaim: true
      )
    }
    if liveState == .original, claimState == .incomplete {
      if directoryLevel {
        try removeManagedDirectory(
          parentDescriptor: parent,
          name: claim,
          record: record
        )
      } else {
        try removeMarkedItem(
          parentDescriptor: parent,
          name: claim,
          record: record,
          url: parentURL.appending(path: claim)
        )
      }
      claimState = .missing
    }
    if liveState == .original, claimState == .missing {
      let publication = try publishingName(claim, record: record)
      if directoryLevel {
        try removeManagedDirectory(
          parentDescriptor: parent,
          name: publication,
          record: record
        )
      } else {
        try removeMarkedItem(
          parentDescriptor: parent,
          name: publication,
          record: record,
          url: parentURL.appending(path: publication)
        )
      }
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
    let managedState: ProviderItemState
    if directoryLevel {
      managedState = try directoryState(
        descriptor: parent,
        name: claim,
        record: record
      )
    } else {
      managedState = try leafState(descriptor: parent, name: claim, record: record)
    }
    guard managedState == .managed else { throw SetupOwnershipError.ownershipDrift(liveURL) }
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

  func createManagedDirectory(
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

  func displacePinnedRegularOriginal(
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

  func restoreRegularFileClaim(
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
}
