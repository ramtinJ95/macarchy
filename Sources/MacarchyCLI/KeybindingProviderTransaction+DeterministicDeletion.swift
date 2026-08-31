import Darwin
import Foundation
import ThemeCore

extension KeybindingProviderTransaction {
  func removeMarkedItem(
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

  func removeOriginalItem(
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

  func resumeProviderDeletionResidue(
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

  func preflightProviderDeletionResidue(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord,
    url: URL,
    directory: Bool
  ) throws -> Bool {
    let deletionName = try deletionName(name, record: record)
    let deletionURL = url.deletingLastPathComponent().appending(path: deletionName)
    guard
      try itemExists(
        parentDescriptor: parentDescriptor,
        name: deletionName,
        url: deletionURL
      )
    else { return false }
    guard
      try claimMarkerMatches(
        parentDescriptor: parentDescriptor,
        name: deletionName,
        record: record,
        url: deletionURL
      )
    else { throw SetupOwnershipError.ownershipDrift(deletionURL) }
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
    } else {
      guard
        try leafState(
          descriptor: parentDescriptor,
          name: deletionName,
          record: record
        ) == .managed
      else { throw SetupOwnershipError.ownershipDrift(deletionURL) }
    }
    return true
  }

  func removePinnedItem(
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

  func deletionName(_ name: String, record: SetupOwnershipRecord) throws -> String {
    ".\(name).deleting-\(try residueNonce(record))"
  }

  func residueNonce(_ record: SetupOwnershipRecord) throws -> String {
    if let nonce = record.claimNonce { return nonce }
    if KeybindingProviderInspector.isLegacyCleanInstallRecord(record) {
      return "legacy-clean-install"
    }
    throw SetupOwnershipError.invalidManifest("keybinding claim nonce is missing")
  }

  func itemExists(parentDescriptor: Int32, name: String, url: URL) throws -> Bool {
    do {
      _ = try PinnedFilesystem.metadata(parentDescriptor: parentDescriptor, name: name, url: url)
      return true
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return false
    }
  }

  func rename(descriptor: Int32, from: String, to: String, url: URL) throws {
    let result = from.withCString { source in
      to.withCString { destination in Darwin.renameat(descriptor, source, descriptor, destination) }
    }
    guard result == 0 else { throw posixError("rename keybinding provider item", url) }
    try sync(descriptor, url: url.deletingLastPathComponent())
  }

  func swap(descriptor: Int32, first: String, second: String, url: URL) throws {
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
}
