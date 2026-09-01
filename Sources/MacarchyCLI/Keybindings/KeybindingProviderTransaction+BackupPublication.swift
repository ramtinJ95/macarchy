import Darwin
import Foundation
import ThemeCore

extension KeybindingProviderTransaction {
  func writeOriginalBackup(
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

  func recoverBackupPublication(
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

  func validateBackupPublicationResidue(
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

  func readOriginalBackup(
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
}
