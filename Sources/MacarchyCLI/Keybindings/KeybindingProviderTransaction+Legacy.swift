import Darwin
import Foundation
import ThemeCore

extension KeybindingProviderTransaction {
  func preflightLegacyCleanInstall(_ record: SetupOwnershipRecord) throws {
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

  func removeLegacyManagedEntry(_ record: SetupOwnershipRecord) throws {
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

  func restoreLegacyManagedEntry(_ record: SetupOwnershipRecord) throws {
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

  func legacyRestorationResidueExists(
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

  func removeLegacyRestorationResidue(
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

  func verifyLegacyManagedLink(
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
    do {
      guard try !KeybindingProviderPrimitives.claimMarkerExists(descriptor: pinned) else {
        throw SetupOwnershipError.ownershipDrift(url)
      }
    } catch let failure as KeybindingProviderPrimitives.POSIXFailure {
      throw posixError(
        "inspect legacy keybinding ownership marker",
        url,
        code: failure.code
      )
    }
  }

  func requireLegacyEntryAbsent() throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    try requireAbsent(parentDescriptor: descriptor, name: "skhdrc", url: entry)
    try requireAbsent(
      parentDescriptor: descriptor,
      name: legacyRestorationName,
      url: directory.appending(path: legacyRestorationName)
    )
  }
}
