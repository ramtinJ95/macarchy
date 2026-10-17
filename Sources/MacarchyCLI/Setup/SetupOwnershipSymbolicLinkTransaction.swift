import Darwin
import Foundation
import ThemeCore

extension SetupOwnershipManager {
  func teardownThemeLink(
    id: String,
    target: URL,
    destination: URL,
    label: String,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    guard let record = records.first(where: { $0.id == id }) else {
      return integrationResult(
        id: id,
        target: target,
        status: .none,
        message: "No Macarchy-owned \(label) link exists"
      )
    }
    try validateThemeLinkRecord(record, target: target, destination: destination)
    guard try themeLinkParentContainsSymlink(id: id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let state = try themeLinkState(id: id, url: target, target: target)
    let removalState = try themeLinkRemovalState(id: id, target: target)
    let removalClaimed: Bool
    switch (state, removalState) {
    case (.matching(let current), .missing) where current == destination.path:
      removalClaimed = false
    case (.missing, .matching(let current)) where current == destination.path:
      removalClaimed = true
    case (.missing, .missing):
      removalClaimed = false
    default:
      throw SetupOwnershipError.ownershipDrift(target)
    }
    if dryRun {
      return integrationResult(
        id: id,
        target: target,
        status: .planned,
        message:
          removalClaimed
          ? "Would finish the interrupted \(label) link removal"
          : state == .missing
            ? "Would clear the already-removed \(label) link record"
            : "Would remove the recorded \(label) canonical link"
      )
    }

    try attributingFailure(to: id, target: target) {
      if state != .missing || removalClaimed {
        try faultInjector(.teardownReady)
        try removePinnedSymbolicLink(
          id: id,
          target: target,
          destination: destination,
          homeDirectory: context.homeDirectory,
          label: label,
          alreadyClaimed: removalClaimed
        )
      }
      records.removeAll { $0.id == id }
      try persist(records: records, context: context)
    }
    return integrationResult(
      id: id,
      target: target,
      status: .removed,
      message: "Removed only the recorded Macarchy-owned \(label) link",
      mutationAttempted: true
    )
  }

  func validateThemeLinkRecord(
    _ record: SetupOwnershipRecord,
    target: URL,
    destination: URL
  ) throws {
    guard record.kind == .symbolicLink, record.targetPath == target.path else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link target is not allowlisted")
    }
    guard record.backupPath == nil, record.originalDigest == nil else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link cannot contain backup state")
    }
    guard record.linkDestination == destination.path else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link destination is not allowlisted")
    }
    guard record.installedDigest == sha256Digest(Data(destination.path.utf8)) else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link digest is invalid")
    }
    guard record.phase == .prepared || record.phase == .applied,
      record.replacementDigest == nil
    else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link has invalid transaction state")
    }
  }

  enum SymbolicLinkState: Equatable {
    case matching(String)
    case missing
    case other
  }

  func symbolicLinkState(_ url: URL) throws -> SymbolicLinkState {
    var metadata = stat()
    if lstat(url.path, &metadata) != 0 {
      if errno == ENOENT { return .missing }
      throw SetupOwnershipError.posix("inspect theme link", url)
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK else { return .other }
    do {
      return .matching(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
    } catch {
      throw SetupOwnershipError.system("read theme link", url, String(describing: error))
    }
  }

  func themeLinkState(id: String, url: URL, target: URL) throws -> SymbolicLinkState {
    try attributingSystemError(to: id, target: target) { try symbolicLinkState(url) }
  }

  func themeLinkRemovalURL(id: String, target: URL) -> URL {
    let safeID = id.replacingOccurrences(of: ".", with: "-")
    return target.deletingLastPathComponent()
      .appending(path: ".macarchy-\(safeID)-removal")
  }

  func themeLinkRemovalState(id: String, target: URL) throws -> SymbolicLinkState {
    try themeLinkState(
      id: id,
      url: themeLinkRemovalURL(id: id, target: target),
      target: target
    )
  }

  func themeLinkParentContainsSymlink(
    id: String,
    target: URL,
    context: Context
  ) throws -> Bool {
    try attributingSystemError(to: id, target: target) {
      try parentPathContainsSymlink(target, below: context.homeDirectory)
    }
  }

  func removePinnedSymbolicLink(
    id: String,
    target: URL,
    destination: URL,
    homeDirectory: URL,
    label: String,
    alreadyClaimed: Bool
  ) throws {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let name = target.lastPathComponent
    let removalURL = themeLinkRemovalURL(id: id, target: target)
    let removalName = removalURL.lastPathComponent
    let destinationPath = destination.path
    if !alreadyClaimed {
      guard PinnedFilesystem.renameExclusively(name, to: removalName, in: parentDescriptor) else {
        throw SetupOwnershipError.ownershipDrift(target)
      }
    }

    do {
      guard
        try pinnedSymbolicLinkMatches(
          parentDescriptor: parentDescriptor,
          name: removalName,
          url: removalURL,
          destination: destinationPath
        )
      else {
        throw SetupOwnershipError.ownershipDrift(target)
      }
    } catch {
      if !alreadyClaimed {
        try restorePinnedThemeLinkClaim(
          parentDescriptor: parentDescriptor,
          removalName: removalName,
          targetName: name,
          removalURL: removalURL,
          target: target,
          label: label
        )
      }
      throw error
    }
    guard removalName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
      throw SetupOwnershipError.posix("remove claimed \(label) link", removalURL)
    }
    guard fsync(parentDescriptor) == 0 else {
      throw SetupOwnershipError.posix("sync removed \(label) link", target)
    }
  }

  func restorePinnedThemeLinkClaim(
    parentDescriptor: Int32,
    removalName: String,
    targetName: String,
    removalURL: URL,
    target: URL,
    label: String
  ) throws {
    guard PinnedFilesystem.renameExclusively(removalName, to: targetName, in: parentDescriptor)
    else {
      throw SetupOwnershipError.posix("restore concurrently replaced \(label) link", removalURL)
    }
    guard fsync(parentDescriptor) == 0 else {
      throw SetupOwnershipError.posix("sync restored \(label) link", target)
    }
  }

  func pinnedSymbolicLinkMatches(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    destination: String
  ) throws -> Bool {
    var metadata = stat()
    let inspection = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard inspection == 0 else {
      throw SetupOwnershipError.posix("inspect claimed theme link", url)
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK else { return false }
    return try readPinnedSymbolicLink(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    ) == destination
  }

  func readPinnedSymbolicLink(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> String {
    do {
      return try PinnedFilesystem.symlinkDestination(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
    } catch let error as PinnedFilesystemError {
      if error.operation == "decode pinned symlink" {
        throw SetupOwnershipError.system(
          "read pinned theme link",
          url,
          "destination is not UTF-8"
        )
      }
      throw SetupOwnershipError.posix("read pinned theme link", url, code: error.code)
    }
  }
}
