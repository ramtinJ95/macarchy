import Darwin
import Foundation
import ThemeCore

extension SetupOwnershipManager {
  func setupThemeLink(
    id: String,
    target: URL,
    destination: URL,
    label: String,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if let record = records.first(where: { $0.id == id }) {
      return try resumeThemeLink(
        record: record,
        target: target,
        destination: destination,
        label: label,
        context: context,
        dryRun: dryRun,
        records: &records
      )
    }

    guard try themeLinkRemovalState(id: id, target: target) == .missing else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    switch try themeLinkState(id: id, url: target, target: target) {
    case .matching(let current) where current == destination.path:
      return integrationResult(
        id: id,
        target: target,
        status: .external,
        message: "The exact \(label) link is already externally owned"
      )
    case .missing:
      break
    case .matching, .other:
      throw SetupOwnershipError.conflictingThemeLink(id, target)
    }
    guard try themeLinkParentContainsSymlink(id: id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.configurationIsExternallyOwned(id, target)
    }
    if dryRun {
      return integrationResult(
        id: id,
        target: target,
        status: .planned,
        message: "Would create the exact \(label) canonical link"
      )
    }

    let record = SetupOwnershipRecord(
      id: id,
      phase: .prepared,
      kind: .symbolicLink,
      targetPath: target.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(destination.path.utf8)),
      linkDestination: destination.path
    )
    do {
      try save(record: record, records: &records, context: context)
      try faultInjector(.manifestPrepared)
      try createPinnedSymbolicLink(
        target: target,
        destination: destination,
        homeDirectory: context.homeDirectory,
        label: label
      )
      try faultInjector(.targetWritten)
      try save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error, integrationID: id, target: target)
    }
    return integrationResult(
      id: id,
      target: target,
      status: .owned,
      message: "Created the \(label) canonical link and recorded Macarchy ownership",
      mutationAttempted: true
    )
  }

  func resumeThemeLink(
    record: SetupOwnershipRecord,
    target: URL,
    destination: URL,
    label: String,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try validateThemeLinkRecord(record, target: target, destination: destination)
    guard
      try themeLinkParentContainsSymlink(id: record.id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let state = try themeLinkState(id: record.id, url: target, target: target)
    let removalState = try themeLinkRemovalState(id: record.id, target: target)
    if case .matching(let current) = removalState, current == destination.path {
      guard state == .missing else { throw SetupOwnershipError.ownershipDrift(target) }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: target,
          status: .planned,
          message: "Would restore the interrupted \(label) link removal"
        )
      }
      do {
        try restorePinnedThemeLinkRemoval(
          id: record.id,
          target: target,
          destination: destination,
          homeDirectory: context.homeDirectory,
          label: label
        )
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(error, integrationID: record.id, target: target)
      }
      return integrationResult(
        id: record.id,
        target: target,
        status: .owned,
        message: "Restored the interrupted \(label) link removal",
        mutationAttempted: true
      )
    }
    guard removalState == .missing else { throw SetupOwnershipError.ownershipDrift(target) }
    switch state {
    case .matching(let current) where current == destination.path:
      if record.phase == .applied {
        return integrationResult(
          id: record.id,
          target: target,
          status: .owned,
          message: "The \(label) link is Macarchy-owned and current"
        )
      }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: target,
          status: .planned,
          message: "Would finalize the interrupted \(label) link record"
        )
      }
      do {
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(error, integrationID: record.id, target: target)
      }
      return integrationResult(
        id: record.id,
        target: target,
        status: .owned,
        message: "Finalized the interrupted \(label) link record",
        mutationAttempted: true
      )
    case .missing:
      if dryRun {
        return integrationResult(
          id: record.id,
          target: target,
          status: .planned,
          message: "Would resume the recorded \(label) link creation"
        )
      }
      do {
        try createPinnedSymbolicLink(
          target: target,
          destination: destination,
          homeDirectory: context.homeDirectory,
          label: label
        )
        try faultInjector(.targetWritten)
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(error, integrationID: record.id, target: target)
      }
      return integrationResult(
        id: record.id,
        target: target,
        status: .owned,
        message: "Resumed the recorded \(label) link creation",
        mutationAttempted: true
      )
    case .matching, .other:
      throw SetupOwnershipError.ownershipDrift(target)
    }
  }

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

    do {
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
    } catch {
      throw SetupOwnershipTransactionError(error, integrationID: id, target: target)
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
      throw posixError("inspect theme link", url)
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK else { return .other }
    do {
      return .matching(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
    } catch {
      throw SetupOwnershipError.system("read theme link", url, String(describing: error))
    }
  }

  func themeLinkState(id: String, url: URL, target: URL) throws -> SymbolicLinkState {
    do {
      return try symbolicLinkState(url)
    } catch SetupOwnershipError.system(let operation, _, let cause) {
      throw SetupOwnershipError.system("\(operation) for \(id)", target, cause)
    }
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
    do {
      return try parentPathContainsSymlink(target, below: context.homeDirectory)
    } catch SetupOwnershipError.system(let operation, _, let cause) {
      throw SetupOwnershipError.system("\(operation) for \(id)", target, cause)
    }
  }

  func createPinnedSymbolicLink(
    target: URL,
    destination: URL,
    homeDirectory: URL,
    label: String
  ) throws {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let name = target.lastPathComponent
    var metadata = stat()
    let inspection = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard inspection != 0, errno == ENOENT else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let destinationPath = destination.path
    let created = destinationPath.withCString { destinationPath in
      name.withCString { namePath in
        Darwin.symlinkat(destinationPath, parentDescriptor, namePath)
      }
    }
    guard created == 0 else { throw posixError("create \(label) link", target) }
    guard
      try readPinnedSymbolicLink(parentDescriptor: parentDescriptor, name: name, url: target)
        == destinationPath
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    guard fsync(parentDescriptor) == 0 else { throw posixError("sync \(label) link", target) }
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
      let claimed = name.withCString { source in
        removalName.withCString { claimed in
          Darwin.renameatx_np(
            parentDescriptor,
            source,
            parentDescriptor,
            claimed,
            UInt32(RENAME_EXCL)
          )
        }
      }
      guard claimed == 0 else {
        throw SetupOwnershipError.ownershipDrift(target)
      }
    }

    let claimedLinkMatches: Bool
    do {
      claimedLinkMatches = try pinnedSymbolicLinkMatches(
        parentDescriptor: parentDescriptor,
        name: removalName,
        url: removalURL,
        destination: destinationPath
      )
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
    guard claimedLinkMatches else {
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
      throw SetupOwnershipError.ownershipDrift(target)
    }
    guard removalName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
      throw posixError("remove claimed \(label) link", removalURL)
    }
    guard fsync(parentDescriptor) == 0 else {
      throw posixError("sync removed \(label) link", target)
    }
  }

  func restorePinnedThemeLinkRemoval(
    id: String,
    target: URL,
    destination: URL,
    homeDirectory: URL,
    label: String
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
    guard
      try pinnedSymbolicLinkMatches(
        parentDescriptor: parentDescriptor,
        name: removalName,
        url: removalURL,
        destination: destination.path
      )
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    try restorePinnedThemeLinkClaim(
      parentDescriptor: parentDescriptor,
      removalName: removalName,
      targetName: name,
      removalURL: removalURL,
      target: target,
      label: label
    )
  }

  func restorePinnedThemeLinkClaim(
    parentDescriptor: Int32,
    removalName: String,
    targetName: String,
    removalURL: URL,
    target: URL,
    label: String
  ) throws {
    let restored = removalName.withCString { source in
      targetName.withCString { restored in
        Darwin.renameatx_np(
          parentDescriptor,
          source,
          parentDescriptor,
          restored,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard restored == 0 else {
      throw posixError("restore concurrently replaced \(label) link", removalURL)
    }
    guard fsync(parentDescriptor) == 0 else {
      throw posixError("sync restored \(label) link", target)
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
    guard inspection == 0 else { throw posixError("inspect claimed theme link", url) }
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
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = name.withCString {
      Darwin.readlinkat(parentDescriptor, $0, &buffer, buffer.count - 1)
    }
    guard count >= 0 else { throw posixError("read pinned theme link", url) }
    let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    guard let destination = String(bytes: bytes, encoding: .utf8) else {
      throw SetupOwnershipError.system("read pinned theme link", url, "destination is not UTF-8")
    }
    return destination
  }
}
