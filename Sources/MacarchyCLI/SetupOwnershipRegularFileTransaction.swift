import Darwin
import Foundation
import ThemeCore

extension SetupOwnershipManager {
  func setupRegularFile(
    id: String,
    target: URL,
    backupURL: URL,
    replacementName: String,
    label: String,
    read: (URL) throws -> Data,
    isExternal: (Data) throws -> Bool,
    installedData: (Data) throws -> Data,
    externalOwnershipError: SetupOwnershipError,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if let record = records.first(where: { $0.id == id }) {
      return try resumeRegularFile(
        record: record,
        target: target,
        backupURL: backupURL,
        replacementName: replacementName,
        label: label,
        read: read,
        installedData: installedData,
        context: context,
        dryRun: dryRun,
        records: &records
      )
    }

    guard try itemExists(backupURL) == false else {
      throw SetupOwnershipError.orphanedBackup(backupURL)
    }
    let replacementURL = target.deletingLastPathComponent().appending(path: replacementName)
    guard try itemExists(replacementURL) == false else {
      throw SetupOwnershipError.orphanedReplacement(replacementURL)
    }
    let original = try read(target)
    if try isExternal(original) {
      return integrationResult(
        id: id,
        target: target,
        status: .external,
        message: "The exact \(label) is already externally owned"
      )
    }
    guard try pathContainsSymlink(target, below: context.homeDirectory) == false else {
      throw externalOwnershipError
    }

    let installed = try installedConfiguration(
      id: id,
      target: target,
      original: original,
      transform: installedData
    )
    if dryRun {
      return integrationResult(
        id: id,
        target: target,
        status: .planned,
        message: "Would back up the configuration and add the exact \(label)"
      )
    }

    let record = SetupOwnershipRecord(
      id: id,
      phase: .prepared,
      kind: .regularFile,
      targetPath: target.path,
      backupPath: relativePath(backupURL, below: context.stateRoot),
      originalDigest: sha256Digest(original),
      installedDigest: sha256Digest(installed),
      linkDestination: nil
    )
    do {
      try save(record: record, records: &records, context: context)
      try faultInjector(.manifestPrepared)
      try writeRegularBackup(original, record: record, backupURL: backupURL)
      try faultInjector(.backupWritten)
      try replaceRegularFile(
        target: target,
        replacementName: replacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: try requiredOriginalDigest(record),
        data: installed,
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
      message: "Added the \(label) and recorded Macarchy ownership",
      mutationAttempted: true
    )
  }

  func resumeRegularFile(
    record: SetupOwnershipRecord,
    target: URL,
    backupURL: URL,
    replacementName: String,
    label: String,
    read: (URL) throws -> Data,
    installedData: (Data) throws -> Data,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try validateRegularFileRecord(record, target: target, backupURL: backupURL, context: context)
    let originalDigest = try requiredOriginalDigest(record)
    guard
      try regularFilePathContainsSymlink(id: record.id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let replacementResidueExists = try validateRegularReplacementResidue(
      record: record,
      target: target,
      replacementName: replacementName,
      context: context,
      remove: false,
      label: label
    )
    let current = try read(target)
    let digest = sha256Digest(current)

    if digest == record.installedDigest {
      let original = try readRegularBackup(record: record, backupURL: backupURL)
      let installed = try installedConfiguration(
        id: record.id,
        target: target,
        original: original,
        transform: installedData
      )
      guard sha256Digest(installed) == record.installedDigest else {
        throw SetupOwnershipError.invalidManifest(
          installedDigestError(recordID: record.id, label: label)
        )
      }
      if record.phase == .applied {
        if replacementResidueExists {
          if dryRun {
            return integrationResult(
              id: record.id,
              target: target,
              status: .planned,
              message: "Would remove the validated interrupted \(label) replacement"
            )
          }
          do {
            _ = try validateRegularReplacementResidue(
              record: record,
              target: target,
              replacementName: replacementName,
              context: context,
              remove: true,
              label: label
            )
          } catch {
            throw SetupOwnershipTransactionError(
              error, integrationID: record.id, target: target)
          }
          return integrationResult(
            id: record.id,
            target: target,
            status: .owned,
            message: "Removed the validated interrupted \(label) replacement",
            mutationAttempted: true
          )
        }
        return integrationResult(
          id: record.id,
          target: target,
          status: .owned,
          message: "The \(label) is Macarchy-owned and current"
        )
      }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: target,
          status: .planned,
          message: "Would finalize the interrupted \(label) ownership record"
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
        message: "Finalized the interrupted \(label) ownership record",
        mutationAttempted: true
      )
    }

    guard digest == originalDigest else { throw SetupOwnershipError.ownershipDrift(target) }
    if dryRun {
      return integrationResult(
        id: record.id,
        target: target,
        status: .planned,
        message: "Would resume the recorded \(label) change"
      )
    }

    let backupExists = try itemExists(backupURL)
    let original =
      backupExists ? try readRegularBackup(record: record, backupURL: backupURL) : current
    let installed = try installedConfiguration(
      id: record.id,
      target: target,
      original: original,
      transform: installedData
    )
    guard sha256Digest(installed) == record.installedDigest else {
      throw SetupOwnershipError.invalidManifest(
        installedDigestError(recordID: record.id, label: label)
      )
    }
    do {
      if replacementResidueExists {
        _ = try validateRegularReplacementResidue(
          record: record,
          target: target,
          replacementName: replacementName,
          context: context,
          remove: true,
          label: label
        )
      }
      if !backupExists {
        try writeRegularBackup(original, record: record, backupURL: backupURL)
      }
      try replaceRegularFile(
        target: target,
        replacementName: replacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: originalDigest,
        data: installed,
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
      message: "Resumed the recorded \(label) change",
      mutationAttempted: true
    )
  }

  func teardownRegularFile(
    id: String,
    target: URL,
    backupURL: URL,
    replacementName: String,
    label: String,
    read: (URL) throws -> Data,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    guard let record = records.first(where: { $0.id == id }) else {
      return integrationResult(
        id: id,
        target: target,
        status: .none,
        message: "No Macarchy-owned \(label) exists"
      )
    }
    try validateRegularFileRecord(record, target: target, backupURL: backupURL, context: context)
    let originalDigest = try requiredOriginalDigest(record)
    guard try regularFilePathContainsSymlink(id: id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let replacementResidueExists = try validateRegularReplacementResidue(
      record: record,
      target: target,
      replacementName: replacementName,
      context: context,
      remove: false,
      label: label
    )
    let current = try read(target)
    let digest = sha256Digest(current)
    guard digest == record.installedDigest || digest == originalDigest else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let original =
      digest == record.installedDigest
      ? try readRegularBackup(record: record, backupURL: backupURL) : nil
    _ = try validateRegularFileIfPresent(backupURL, unsafe: .corruptBackup(backupURL))
    if dryRun {
      return integrationResult(
        id: id,
        target: target,
        status: .planned,
        message:
          digest == record.installedDigest
          ? "Would restore the backed-up \(label) configuration"
          : "Would clear the already-reverted \(label) ownership record"
      )
    }

    do {
      if replacementResidueExists {
        _ = try validateRegularReplacementResidue(
          record: record,
          target: target,
          replacementName: replacementName,
          context: context,
          remove: true,
          label: label
        )
      }
      if let original {
        try faultInjector(.teardownReady)
        try replaceRegularFile(
          target: target,
          replacementName: replacementName,
          homeDirectory: context.homeDirectory,
          expectedDigest: record.installedDigest,
          data: original,
          label: label
        )
      }
      try removeRegularFileIfPresent(backupURL, unsafe: .corruptBackup(backupURL))
      records.removeAll { $0.id == id }
      try persist(records: records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error, integrationID: id, target: target)
    }
    return integrationResult(
      id: id,
      target: target,
      status: .removed,
      message: "Removed only the recorded Macarchy-owned \(label)",
      mutationAttempted: true
    )
  }

  func requiredOriginalDigest(_ record: SetupOwnershipRecord) throws -> String {
    guard let digest = record.originalDigest else {
      throw SetupOwnershipError.invalidManifest("regular-file record is missing original digest")
    }
    return digest
  }

  func installedConfiguration(
    id: String,
    target: URL,
    original: Data,
    transform: (Data) throws -> Data
  ) throws -> Data {
    let installed = try transform(original)
    guard installed.count <= Self.maximumConfigurationSize else {
      throw SetupOwnershipError.installedConfigurationTooLarge(id, target)
    }
    return installed
  }

  func installedDigestError(recordID: String, label: String) -> String {
    recordID == Self.integrationID
      ? "Kitty installed digest cannot be reproduced"
      : "\(label) digest cannot be reproduced"
  }

  func validateRegularFileRecord(
    _ record: SetupOwnershipRecord,
    target: URL,
    backupURL: URL,
    context: Context
  ) throws {
    guard record.kind == .regularFile, record.targetPath == target.path else {
      throw SetupOwnershipError.invalidManifest("\(record.id) target is not allowlisted")
    }
    guard record.backupPath == relativePath(backupURL, below: context.stateRoot) else {
      throw SetupOwnershipError.invalidManifest("\(record.id) backup is not allowlisted")
    }
    guard record.linkDestination == nil else {
      throw SetupOwnershipError.invalidManifest("\(record.id) cannot own a symbolic link")
    }
    guard record.phase == .prepared || record.phase == .applied,
      record.replacementDigest == nil
    else {
      throw SetupOwnershipError.invalidManifest("\(record.id) has invalid transaction state")
    }
    _ = try requiredOriginalDigest(record)
  }

  func relativePath(_ url: URL, below root: URL) -> String {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    precondition(url.path.hasPrefix(prefix))
    return String(url.path.dropFirst(prefix.count))
  }

  func readRegularBackup(
    record: SetupOwnershipRecord,
    backupURL: URL
  ) throws -> Data {
    let backup: BoundedRegularFile
    do {
      backup = try BoundedRegularFile.read(
        at: backupURL,
        maximumSize: Self.maximumConfigurationSize
      )
    } catch {
      throw SetupOwnershipError.corruptBackup(backupURL)
    }
    guard
      backup.permissions == 0o600,
      sha256Digest(backup.data) == (try requiredOriginalDigest(record))
    else {
      throw SetupOwnershipError.corruptBackup(backupURL)
    }
    return backup.data
  }

  func writeRegularBackup(
    _ data: Data,
    record: SetupOwnershipRecord,
    backupURL: URL
  ) throws {
    guard sha256Digest(data) == (try requiredOriginalDigest(record)) else {
      throw SetupOwnershipError.invalidManifest(
        "\(record.id) original digest changed before backup")
    }
    do {
      try FileManager.default.createDirectory(
        at: backupURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      throw SetupOwnershipError.system(
        "create backup directory", backupURL, String(describing: error))
    }

    let safeID = record.id.replacingOccurrences(of: ".", with: "-")
    let temporary = backupURL.deletingLastPathComponent()
      .appending(path: ".\(safeID)-backup-\(UUID().uuidString).tmp")
    let descriptor = temporary.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else { throw posixError("create temporary backup", temporary) }
    defer { Darwin.close(descriptor) }
    var published = false
    defer {
      if !published { _ = Darwin.unlink(temporary.path) }
    }
    try write(
      data,
      descriptor: descriptor,
      url: temporary,
      operation: "write temporary \(record.id) backup"
    )
    guard fsync(descriptor) == 0 else { throw posixError("sync temporary backup", temporary) }
    let publication = temporary.path.withCString { source in
      backupURL.path.withCString { destination in
        Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
      }
    }
    guard publication == 0 else { throw posixError("publish backup", backupURL) }
    published = true
    _ = try readRegularBackup(record: record, backupURL: backupURL)
  }

  func validateRegularReplacementResidue(
    record: SetupOwnershipRecord,
    target: URL,
    replacementName: String,
    context: Context,
    remove: Bool,
    label: String
  ) throws -> Bool {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: context.homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let replacementURL = target.deletingLastPathComponent().appending(path: replacementName)
    let residueDescriptor = replacementName.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    if residueDescriptor < 0, errno == ENOENT { return false }
    guard residueDescriptor >= 0 else {
      throw posixError("open replacement residue", replacementURL)
    }
    defer { Darwin.close(residueDescriptor) }

    let residue = try readPinnedRegularFile(
      descriptor: residueDescriptor,
      url: replacementURL,
      label: label
    )
    let current = try readPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: target.lastPathComponent,
      url: target,
      label: label
    )
    let currentDigest = sha256Digest(current.data)
    let residueDigest = sha256Digest(residue.data)
    let originalDigest = try requiredOriginalDigest(record)
    guard
      (currentDigest == record.installedDigest && residueDigest == originalDigest)
        || (currentDigest == originalDigest && residueDigest == record.installedDigest)
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    if remove {
      guard replacementName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
        throw posixError("remove replacement residue", replacementURL)
      }
    }
    return true
  }

  func replaceRegularFile(
    target: URL,
    replacementName: String,
    homeDirectory: URL,
    expectedDigest: String,
    data: Data,
    label: String
  ) throws {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let targetName = target.lastPathComponent
    let currentDescriptor = try openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: targetName,
      url: target,
      label: label
    )
    defer { Darwin.close(currentDescriptor) }
    let current = try readPinnedRegularFile(
      descriptor: currentDescriptor, url: target, label: label)
    let originalSnapshot = try regularFileSnapshot(
      descriptor: currentDescriptor,
      url: target,
      label: label
    )
    guard sha256Digest(current.data) == expectedDigest else {
      throw SetupOwnershipError.ownershipDrift(target)
    }

    let temporaryDescriptor = replacementName.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
    }
    guard temporaryDescriptor >= 0 else { throw posixError("create temporary \(label)", target) }
    defer { Darwin.close(temporaryDescriptor) }
    var cleanupTemporary = true
    defer {
      if cleanupTemporary {
        _ = replacementName.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
      }
    }

    try write(
      data,
      descriptor: temporaryDescriptor,
      url: target,
      operation: "write temporary \(label) configuration"
    )
    guard fsync(temporaryDescriptor) == 0 else { throw posixError("sync \(label)", target) }
    guard
      fcopyfile(
        currentDescriptor,
        temporaryDescriptor,
        nil,
        copyfile_flags_t(COPYFILE_METADATA)
      ) == 0
    else {
      throw posixError("copy \(label) metadata", target)
    }
    guard fsync(temporaryDescriptor) == 0 else {
      throw posixError("sync \(label) metadata", target)
    }
    try faultInjector(.replacementReady)
    let recheckedDescriptor = try openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: targetName,
      url: target,
      label: label
    )
    defer { Darwin.close(recheckedDescriptor) }
    let rechecked = try readPinnedRegularFile(
      descriptor: recheckedDescriptor,
      url: target,
      label: label
    )
    let recheckedSnapshot = try regularFileSnapshot(
      descriptor: recheckedDescriptor,
      url: target,
      label: label
    )
    guard
      sha256Digest(rechecked.data) == expectedDigest,
      recheckedSnapshot == originalSnapshot
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    guard swap(parentDescriptor: parentDescriptor, first: replacementName, second: targetName) == 0
    else {
      throw posixError("replace \(label)", target)
    }
    do {
      try faultInjector(.replacementSwapped)
    } catch {
      cleanupTemporary = false
      throw error
    }

    let displaced: BoundedRegularFile
    let displacedSnapshot: RegularFileSnapshot
    do {
      let displacedDescriptor = try openPinnedRegularFile(
        parentDescriptor: parentDescriptor,
        name: replacementName,
        url: target.deletingLastPathComponent().appending(path: replacementName),
        label: label
      )
      defer { Darwin.close(displacedDescriptor) }
      displaced = try readPinnedRegularFile(
        descriptor: displacedDescriptor,
        url: target.deletingLastPathComponent().appending(path: replacementName),
        label: label
      )
      displacedSnapshot = try regularFileSnapshot(
        descriptor: displacedDescriptor,
        url: target.deletingLastPathComponent().appending(path: replacementName),
        label: label
      )
    } catch {
      let restored = swap(
        parentDescriptor: parentDescriptor,
        first: replacementName,
        second: targetName
      )
      guard restored == 0 else {
        cleanupTemporary = false
        throw posixError("restore concurrently changed \(label)", target)
      }
      throw error
    }
    guard
      sha256Digest(displaced.data) == expectedDigest,
      originalSnapshot.matchesDisplaced(displacedSnapshot)
    else {
      let restored = swap(
        parentDescriptor: parentDescriptor,
        first: replacementName,
        second: targetName
      )
      guard restored == 0 else {
        cleanupTemporary = false
        throw posixError("restore concurrently changed \(label)", target)
      }
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let installedDescriptor = try openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: targetName,
      url: target,
      label: label
    )
    defer { Darwin.close(installedDescriptor) }
    let installed = try readPinnedRegularFile(
      descriptor: installedDescriptor,
      url: target,
      label: label
    )
    let installedSnapshot = try regularFileSnapshot(
      descriptor: installedDescriptor,
      url: target,
      label: label
    )
    if sha256Digest(installed.data) != sha256Digest(data)
      || !installedSnapshot.hasCopiedMetadata(from: originalSnapshot)
    {
      let restored = swap(
        parentDescriptor: parentDescriptor,
        first: replacementName,
        second: targetName
      )
      guard restored == 0 else {
        cleanupTemporary = false
        throw posixError("restore concurrently changed \(label)", target)
      }
      throw SetupOwnershipError.ownershipDrift(target)
    }
    cleanupTemporary = false
    guard replacementName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
      throw posixError("remove displaced \(label)", target)
    }
  }

  func openPinnedParent(
    target: URL,
    homeDirectory: URL,
    label: String
  ) throws -> Int32 {
    let home = homeDirectory.standardizedFileURL
    let target = target.standardizedFileURL
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard target.path.hasPrefix(prefix) else {
      throw SetupOwnershipError.invalidManifest("\(label) target is outside the selected home")
    }
    let parent = target.deletingLastPathComponent()
    let relativeParent =
      parent.path == home.path ? ""[...] : parent.path.dropFirst(prefix.count)
    var descriptor = home.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw posixError("open home directory", home) }
    var candidate = home
    for component in relativeParent.split(separator: "/") {
      candidate.append(path: String(component))
      let next = component.withCString {
        Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      }
      let code = errno
      Darwin.close(descriptor)
      guard next >= 0 else {
        throw posixError("open pinned \(label) directory", candidate, code: code)
      }
      descriptor = next
    }
    return descriptor
  }

  func openPinnedRegularFile(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    label: String
  ) throws -> Int32 {
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw posixError("open pinned \(label)", url) }
    return descriptor
  }

  func readPinnedRegularFile(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    label: String
  ) throws -> BoundedRegularFile {
    let descriptor = try openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      label: label
    )
    defer { Darwin.close(descriptor) }
    return try readPinnedRegularFile(descriptor: descriptor, url: url, label: label)
  }

  func readPinnedRegularFile(
    descriptor: Int32,
    url: URL,
    label: String
  ) throws -> BoundedRegularFile {
    do {
      return try BoundedRegularFile.read(
        descriptor: descriptor,
        maximumSize: Self.maximumConfigurationSize
      )
    } catch {
      throw SetupOwnershipError.system("read pinned \(label)", url, String(describing: error))
    }
  }

  func regularFileSnapshot(
    descriptor: Int32,
    url: URL,
    label: String
  ) throws -> RegularFileSnapshot {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw posixError("inspect pinned \(label) metadata", url)
    }
    return try RegularFileSnapshot(
      metadata: metadata,
      extendedAttributes: extendedAttributes(
        descriptor: descriptor,
        url: url,
        label: label
      )
    )
  }

  func extendedAttributes(
    descriptor: Int32,
    url: URL,
    label: String
  ) throws -> [String: Data] {
    let size = Darwin.flistxattr(descriptor, nil, 0, 0)
    guard size >= 0 else { throw posixError("list pinned \(label) attributes", url) }
    guard size > 0 else { return [:] }
    var names = [CChar](repeating: 0, count: size)
    let count = Darwin.flistxattr(descriptor, &names, names.count, 0)
    guard count == size else { throw posixError("read pinned \(label) attribute names", url) }

    var attributes = [String: Data]()
    let bytes = names.prefix(count).map { UInt8(bitPattern: $0) }
    for nameBytes in bytes.split(separator: 0) {
      guard let name = String(bytes: nameBytes, encoding: .utf8) else {
        throw SetupOwnershipError.system(
          "read pinned \(label) attribute names",
          url,
          "attribute name is not UTF-8"
        )
      }
      let valueSize = name.withCString {
        Darwin.fgetxattr(descriptor, $0, nil, 0, 0, 0)
      }
      guard valueSize >= 0 else { throw posixError("inspect pinned \(label) attribute", url) }
      var value = Data(count: valueSize)
      let valueCount = value.withUnsafeMutableBytes { bytes in
        name.withCString {
          Darwin.fgetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
      guard valueCount == valueSize else {
        throw posixError("read pinned \(label) attribute", url)
      }
      attributes[name] = value
    }
    return attributes
  }

  func readConfiguration(_ url: URL) throws -> Data {
    var metadata = stat()
    guard stat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      throw SetupOwnershipError.missingKittyConfiguration(url)
    }
    let data: Data
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      data = try handle.read(upToCount: Self.maximumConfigurationSize + 1) ?? Data()
    } catch {
      throw SetupOwnershipError.system("read", url, String(describing: error))
    }
    guard data.count <= Self.maximumConfigurationSize else {
      throw SetupOwnershipError.kittyConfigurationTooLarge(url)
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw SetupOwnershipError.unreadableKittyConfiguration(url)
    }
    return data
  }

  func swap(parentDescriptor: Int32, first: String, second: String) -> Int32 {
    first.withCString { firstPath in
      second.withCString { secondPath in
        Darwin.renameatx_np(
          parentDescriptor,
          firstPath,
          parentDescriptor,
          secondPath,
          UInt32(RENAME_SWAP)
        )
      }
    }
  }

  func write(
    _ data: Data,
    descriptor: Int32,
    url: URL,
    operation: String
  ) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          throw posixError(operation, url)
        }
        guard count > 0 else {
          throw SetupOwnershipError.system(
            operation, url, "write returned zero bytes"
          )
        }
        offset += count
      }
    }
  }

  func posixError(
    _ operation: String,
    _ url: URL,
    code: Int32 = errno
  ) -> SetupOwnershipError {
    .system(operation, url, String(cString: strerror(code)))
  }

  func removeRegularFileIfPresent(
    _ url: URL,
    unsafe error: SetupOwnershipError
  ) throws {
    guard try validateRegularFileIfPresent(url, unsafe: error) else { return }
    guard Darwin.unlink(url.path) == 0 else {
      throw posixError("remove setup state", url)
    }
  }

  func validateRegularFileIfPresent(
    _ url: URL,
    unsafe error: SetupOwnershipError
  ) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) != 0 {
      if errno == ENOENT { return false }
      throw posixError("inspect setup state for removal", url)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else { throw error }
    return true
  }

  func itemExists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return true }
    if errno == ENOENT { return false }
    throw SetupOwnershipError.system(
      "inspect", url, String(cString: strerror(errno))
    )
  }

  struct RegularFileSnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let flags: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let extendedAttributes: [String: Data]

    init(metadata: stat, extendedAttributes: [String: Data]) {
      device = UInt64(metadata.st_dev)
      inode = UInt64(metadata.st_ino)
      mode = UInt32(metadata.st_mode)
      owner = metadata.st_uid
      group = metadata.st_gid
      flags = metadata.st_flags
      size = metadata.st_size
      modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
      modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
      changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
      changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
      self.extendedAttributes = extendedAttributes
    }

    func matchesDisplaced(_ other: Self) -> Bool {
      device == other.device
        && inode == other.inode
        && size == other.size
        && hasCopiedMetadata(from: other)
    }

    func hasCopiedMetadata(from other: Self) -> Bool {
      mode == other.mode
        && hasCopiedMetadataIgnoringMode(from: other)
    }

    func hasCopiedMetadataIgnoringMode(from other: Self) -> Bool {
      owner == other.owner
        && group == other.group
        && flags == other.flags
        && modifiedSeconds == other.modifiedSeconds
        && modifiedNanoseconds == other.modifiedNanoseconds
        && extendedAttributes == other.extendedAttributes
    }
  }
}
