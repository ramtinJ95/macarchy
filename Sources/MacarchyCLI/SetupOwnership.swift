import Darwin
import Foundation
import ThemeCore

enum SetupOwnershipCheckpoint: Equatable, Sendable {
  case manifestPrepared
  case backupWritten
  case replacementReady
  case replacementSwapped
  case targetWritten
  case teardownReady
}

enum SetupOwnershipError: Error, CustomStringConvertible, Equatable, Sendable {
  case conflictingKittyInclude(URL)
  case corruptBackup(URL)
  case invalidManifest(String)
  case kittyConfigurationIsExternallyOwned(URL)
  case kittyConfigurationTooLarge(URL)
  case missingKittyConfiguration(URL)
  case orphanedBackup(URL)
  case orphanedReplacement(URL)
  case ownershipDrift(URL)
  case system(String, URL, String)
  case unreadableKittyConfiguration(URL)

  var description: String {
    switch self {
    case .conflictingKittyInclude(let url):
      "Kitty configuration at \(url.path) contains a conflicting Macarchy include"
    case .corruptBackup(let url):
      "Macarchy-owned backup at \(url.path) is missing or corrupt"
    case .invalidManifest(let reason):
      "Setup ownership manifest is invalid: \(reason)"
    case .kittyConfigurationIsExternallyOwned(let url):
      "Kitty configuration at \(url.path) is symlinked or inside a symlinked directory; update its external source instead"
    case .kittyConfigurationTooLarge(let url):
      "Kitty configuration at \(url.path) exceeds 1 MiB"
    case .missingKittyConfiguration(let url):
      "Kitty configuration must already exist as an ordinary file at \(url.path)"
    case .orphanedBackup(let url):
      "Setup backup exists without an ownership manifest at \(url.path); refusing to overwrite recovery evidence"
    case .orphanedReplacement(let url):
      "Setup replacement residue exists without an ownership manifest at \(url.path); refusing to overwrite recovery evidence"
    case .ownershipDrift(let url):
      "Macarchy-owned Kitty configuration at \(url.path) changed after setup; refusing to overwrite it"
    case .system(let operation, let url, let cause):
      "Cannot \(operation) \(url.path): \(cause)"
    case .unreadableKittyConfiguration(let url):
      "Cannot read Kitty configuration at \(url.path) as UTF-8"
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.conflictingKittyInclude(let lhs), .conflictingKittyInclude(let rhs)),
      (.corruptBackup(let lhs), .corruptBackup(let rhs)),
      (
        .kittyConfigurationIsExternallyOwned(let lhs),
        .kittyConfigurationIsExternallyOwned(let rhs)
      ),
      (.kittyConfigurationTooLarge(let lhs), .kittyConfigurationTooLarge(let rhs)),
      (.missingKittyConfiguration(let lhs), .missingKittyConfiguration(let rhs)),
      (.orphanedBackup(let lhs), .orphanedBackup(let rhs)),
      (.orphanedReplacement(let lhs), .orphanedReplacement(let rhs)),
      (.ownershipDrift(let lhs), .ownershipDrift(let rhs)),
      (.unreadableKittyConfiguration(let lhs), .unreadableKittyConfiguration(let rhs)):
      lhs.path == rhs.path
    case (.invalidManifest(let lhs), .invalidManifest(let rhs)):
      lhs == rhs
    case (
      .system(let lhsOperation, let lhsURL, let lhsCause),
      .system(let rhsOperation, let rhsURL, let rhsCause)
    ):
      lhsOperation == rhsOperation && lhsURL.path == rhsURL.path && lhsCause == rhsCause
    default:
      false
    }
  }
}

struct SetupOwnershipTransactionError: Error, CustomStringConvertible, Sendable {
  let cause: String

  init(_ error: any Error) {
    cause = String(describing: error)
  }

  var description: String { cause }
}

struct SetupIntegrationResult: Encodable, Sendable {
  enum Status: String, Encodable, Sendable {
    case external
    case failed
    case none
    case owned
    case planned
    case removed
  }

  let id: String
  let status: Status
  let target: String
  let message: String
  let mutationAttempted: Bool

  var succeeded: Bool {
    status != .failed
  }
}

struct SetupOwnershipManager: Sendable {
  static let integrationID = "kitty.include"
  static let maximumConfigurationSize = 1_048_576

  let faultInjector: @Sendable (SetupOwnershipCheckpoint) throws -> Void

  init(
    faultInjector: @escaping @Sendable (SetupOwnershipCheckpoint) throws -> Void = { _ in }
  ) {
    self.faultInjector = faultInjector
  }

  func setup(
    homeDirectory: URL,
    dryRun: Bool
  ) throws -> SetupIntegrationResult {
    let context = Context(homeDirectory: homeDirectory)
    if dryRun { return try setup(context: context, dryRun: true) }
    return try ActivationLock(root: context.stateRoot).withLock {
      try setup(context: context, dryRun: false)
    }
  }

  func teardown(homeDirectory: URL, dryRun: Bool) throws -> SetupIntegrationResult {
    let context = Context(homeDirectory: homeDirectory)
    if dryRun { return try teardown(context: context, dryRun: true) }
    return try ActivationLock(root: context.stateRoot).withLock {
      try teardown(context: context, dryRun: false)
    }
  }

  private func setup(
    context: Context,
    dryRun: Bool
  ) throws -> SetupIntegrationResult {
    if let record = try readRecord(context: context) {
      return try resume(
        record: record,
        context: context,
        dryRun: dryRun
      )
    }

    guard try itemExists(context.backupURL) == false else {
      throw SetupOwnershipError.orphanedBackup(context.backupURL)
    }
    guard try itemExists(context.replacementURL) == false else {
      throw SetupOwnershipError.orphanedReplacement(context.replacementURL)
    }
    let original = try readConfiguration(context.kittyConfiguration)
    if try hasValidExternalInclude(original, context: context) {
      return result(
        context: context,
        status: .external,
        message: "The exact Kitty include already exists and remains externally owned"
      )
    }
    guard try pathContainsSymlink(context.kittyConfiguration, below: context.homeDirectory) == false
    else {
      throw SetupOwnershipError.kittyConfigurationIsExternallyOwned(context.kittyConfiguration)
    }

    let installed = addingInclude(original, directive: context.includeDirective)
    if dryRun {
      return result(
        context: context,
        status: .planned,
        message: "Would back up the Kitty configuration and add the exact Macarchy bridge include"
      )
    }

    let record = SetupOwnershipRecord(
      id: Self.integrationID,
      phase: .prepared,
      targetPath: context.kittyConfiguration.path,
      backupPath: context.backupRelativePath,
      originalDigest: sha256Digest(original),
      installedDigest: sha256Digest(installed)
    )
    do {
      try writeManifest(record: record, context: context)
      try faultInjector(.manifestPrepared)
      try writeBackup(original, record: record, context: context)
      try faultInjector(.backupWritten)
      try replaceConfiguration(
        context: context,
        expectedDigest: record.originalDigest,
        with: installed
      )
      try faultInjector(.targetWritten)
      try writeManifest(record: record.applied, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error)
    }
    return result(
      context: context,
      status: .owned,
      message: "Added the Kitty include and recorded Macarchy ownership",
      mutationAttempted: true
    )
  }

  private func resume(
    record: SetupOwnershipRecord,
    context: Context,
    dryRun: Bool
  ) throws -> SetupIntegrationResult {
    try validate(record: record, context: context)
    try validateReplacementResidue(record: record, context: context, remove: !dryRun)
    guard try pathContainsSymlink(context.kittyConfiguration, below: context.homeDirectory) == false
    else {
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }
    let current = try readConfiguration(context.kittyConfiguration)
    let digest = sha256Digest(current)

    if digest == record.installedDigest {
      let original = try readBackup(record: record, context: context)
      guard
        sha256Digest(addingInclude(original, directive: context.includeDirective))
          == record.installedDigest
      else {
        throw SetupOwnershipError.invalidManifest("Kitty installed digest cannot be reproduced")
      }
      guard record.phase == .prepared else {
        return result(
          context: context,
          status: .owned,
          message: "The Kitty include is Macarchy-owned and current"
        )
      }
      if dryRun {
        return result(
          context: context,
          status: .planned,
          message: "Would finalize the interrupted Kitty ownership record"
        )
      }
      do {
        try writeManifest(record: record.applied, context: context)
      } catch {
        throw SetupOwnershipTransactionError(error)
      }
      return result(
        context: context,
        status: .owned,
        message: "Finalized the interrupted Kitty ownership record",
        mutationAttempted: true
      )
    }

    guard digest == record.originalDigest else {
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }
    if dryRun {
      return result(
        context: context,
        status: .planned,
        message: "Would resume the recorded Kitty include change"
      )
    }

    let backupExists = try itemExists(context.backupURL)
    let original =
      backupExists ? try readBackup(record: record, context: context) : current
    let installed = addingInclude(original, directive: context.includeDirective)
    guard sha256Digest(installed) == record.installedDigest else {
      throw SetupOwnershipError.invalidManifest("Kitty installed digest cannot be reproduced")
    }
    do {
      if !backupExists {
        try writeBackup(original, record: record, context: context)
      }
      try replaceConfiguration(
        context: context,
        expectedDigest: record.originalDigest,
        with: installed
      )
      try faultInjector(.targetWritten)
      try writeManifest(record: record.applied, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error)
    }
    return result(
      context: context,
      status: .owned,
      message: "Resumed the recorded Kitty include change",
      mutationAttempted: true
    )
  }

  private func teardown(context: Context, dryRun: Bool) throws -> SetupIntegrationResult {
    guard let record = try readRecord(context: context) else {
      return result(
        context: context,
        status: .none,
        message: "No Macarchy-owned Kitty integration exists"
      )
    }
    try validate(record: record, context: context)
    try validateReplacementResidue(record: record, context: context, remove: !dryRun)
    guard try pathContainsSymlink(context.kittyConfiguration, below: context.homeDirectory) == false
    else {
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }

    let current = try readConfiguration(context.kittyConfiguration)
    let digest = sha256Digest(current)
    guard digest == record.installedDigest || digest == record.originalDigest else {
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }
    let original =
      digest == record.installedDigest
      ? try readBackup(record: record, context: context) : nil
    _ = try validateRegularFileIfPresent(
      context.backupURL,
      unsafe: .corruptBackup(context.backupURL)
    )
    _ = try validateRegularFileIfPresent(
      context.manifestURL,
      unsafe: .invalidManifest("ownership path is not an ordinary file")
    )
    if dryRun {
      return result(
        context: context,
        status: .planned,
        message:
          digest == record.installedDigest
          ? "Would restore the backed-up Kitty configuration"
          : "Would clear the already-reverted Kitty ownership record"
      )
    }

    do {
      if let original {
        try faultInjector(.teardownReady)
        try replaceConfiguration(
          context: context,
          expectedDigest: record.installedDigest,
          with: original
        )
      }
      try removeRegularFileIfPresent(
        context.backupURL,
        unsafe: .corruptBackup(context.backupURL)
      )
      try removeRegularFileIfPresent(
        context.manifestURL,
        unsafe: .invalidManifest("ownership path is not an ordinary file")
      )
    } catch {
      throw SetupOwnershipTransactionError(error)
    }
    return result(
      context: context,
      status: .removed,
      message: "Removed only the recorded Macarchy-owned Kitty integration",
      mutationAttempted: true
    )
  }

  private func readRecord(context: Context) throws -> SetupOwnershipRecord? {
    guard try itemExists(context.manifestURL) else { return nil }
    let data: Data
    do {
      data = try BoundedRegularFile.read(
        at: context.manifestURL,
        maximumSize: 65_536
      ).data
    } catch {
      throw SetupOwnershipError.system(
        "read", context.manifestURL, String(describing: error))
    }
    let manifest: SetupOwnershipManifest
    do {
      manifest = try JSONDecoder().decode(SetupOwnershipManifest.self, from: data)
    } catch {
      throw SetupOwnershipError.invalidManifest(String(describing: error))
    }
    guard manifest.schemaVersion == SetupOwnershipManifest.currentSchemaVersion else {
      throw SetupOwnershipError.invalidManifest(
        "unsupported schema version \(manifest.schemaVersion)"
      )
    }
    guard manifest.records.count == 1, manifest.records[0].id == Self.integrationID else {
      throw SetupOwnershipError.invalidManifest("expected exactly the Kitty include record")
    }
    return manifest.records[0]
  }

  private func writeManifest(record: SetupOwnershipRecord, context: Context) throws {
    do {
      try FileManager.default.createDirectory(
        at: context.manifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(SetupOwnershipManifest(records: [record])).write(
        to: context.manifestURL,
        options: .atomic
      )
    } catch {
      throw SetupOwnershipError.system(
        "write", context.manifestURL, String(describing: error))
    }
  }

  private func validate(record: SetupOwnershipRecord, context: Context) throws {
    guard record.id == Self.integrationID else {
      throw SetupOwnershipError.invalidManifest("unknown integration \(record.id)")
    }
    guard record.targetPath == context.kittyConfiguration.path else {
      throw SetupOwnershipError.invalidManifest("Kitty target does not match this home directory")
    }
    guard record.backupPath == context.backupRelativePath else {
      throw SetupOwnershipError.invalidManifest("Kitty backup path is not allowlisted")
    }
  }

  private func readConfiguration(_ url: URL) throws -> Data {
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

  private func readBackup(record: SetupOwnershipRecord, context: Context) throws -> Data {
    let backup: BoundedRegularFile
    do {
      backup = try BoundedRegularFile.read(
        at: context.backupURL,
        maximumSize: Self.maximumConfigurationSize
      )
    } catch {
      throw SetupOwnershipError.corruptBackup(context.backupURL)
    }
    guard backup.permissions == 0o600, sha256Digest(backup.data) == record.originalDigest else {
      throw SetupOwnershipError.corruptBackup(context.backupURL)
    }
    return backup.data
  }

  private func writeBackup(
    _ data: Data,
    record: SetupOwnershipRecord,
    context: Context
  ) throws {
    guard sha256Digest(data) == record.originalDigest else {
      throw SetupOwnershipError.invalidManifest("Kitty original digest changed before backup")
    }
    do {
      try FileManager.default.createDirectory(
        at: context.backupURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      throw SetupOwnershipError.system(
        "create backup directory", context.backupURL, String(describing: error))
    }

    let temporary = context.backupURL.deletingLastPathComponent()
      .appending(path: ".kitty-backup-\(UUID().uuidString).tmp")
    let descriptor = temporary.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
      throw posixError("create temporary Kitty backup", temporary)
    }
    defer { Darwin.close(descriptor) }
    var published = false
    defer {
      if !published { _ = Darwin.unlink(temporary.path) }
    }
    try write(data, descriptor: descriptor, url: temporary)
    guard fsync(descriptor) == 0 else {
      throw posixError("sync temporary Kitty backup", temporary)
    }
    let publication = temporary.path.withCString { source in
      context.backupURL.path.withCString { destination in
        Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
      }
    }
    guard publication == 0 else {
      throw posixError("publish Kitty backup", context.backupURL)
    }
    published = true
    _ = try readBackup(record: record, context: context)
  }

  private func validateReplacementResidue(
    record: SetupOwnershipRecord,
    context: Context,
    remove: Bool
  ) throws {
    let parentDescriptor = try openPinnedKittyParent(context: context)
    defer { Darwin.close(parentDescriptor) }
    let residueDescriptor = context.replacementName.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    if residueDescriptor < 0, errno == ENOENT { return }
    guard residueDescriptor >= 0 else {
      throw posixError("open Kitty replacement residue", context.replacementURL)
    }
    defer { Darwin.close(residueDescriptor) }

    let residue: BoundedRegularFile
    do {
      residue = try BoundedRegularFile.read(
        descriptor: residueDescriptor,
        maximumSize: Self.maximumConfigurationSize
      )
    } catch {
      throw SetupOwnershipError.system(
        "read Kitty replacement residue",
        context.replacementURL,
        String(describing: error)
      )
    }
    let current = try readPinnedKittyConfiguration(
      parentDescriptor: parentDescriptor,
      context: context
    )
    let currentDigest = sha256Digest(current.data)
    let residueDigest = sha256Digest(residue.data)
    guard
      (currentDigest == record.installedDigest && residueDigest == record.originalDigest)
        || (currentDigest == record.originalDigest && residueDigest == record.installedDigest)
    else {
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }
    if remove {
      guard
        context.replacementName.withCString({
          Darwin.unlinkat(parentDescriptor, $0, 0)
        }) == 0
      else {
        throw posixError("remove Kitty replacement residue", context.replacementURL)
      }
    }
  }

  private func replaceConfiguration(
    context: Context,
    expectedDigest: String,
    with data: Data
  ) throws {
    let parentDescriptor = try openPinnedKittyParent(context: context)
    defer { Darwin.close(parentDescriptor) }

    let currentDescriptor = try openPinnedKittyConfiguration(
      parentDescriptor: parentDescriptor,
      name: "kitty.conf",
      url: context.kittyConfiguration
    )
    defer { Darwin.close(currentDescriptor) }
    let current = try readPinnedKittyConfiguration(
      descriptor: currentDescriptor,
      context: context
    )
    guard sha256Digest(current.data) == expectedDigest else {
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }
    let temporaryName = context.replacementName
    let temporaryDescriptor = temporaryName.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
    }
    guard temporaryDescriptor >= 0 else {
      throw posixError(
        "create temporary Kitty configuration",
        context.kittyConfiguration,
        code: errno
      )
    }
    defer { Darwin.close(temporaryDescriptor) }
    var cleanupTemporary = true
    defer {
      if cleanupTemporary {
        _ = temporaryName.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
      }
    }

    try write(data, descriptor: temporaryDescriptor, url: context.kittyConfiguration)
    guard fsync(temporaryDescriptor) == 0 else {
      throw posixError("sync Kitty configuration", context.kittyConfiguration)
    }
    let metadataCopied = fcopyfile(
      currentDescriptor,
      temporaryDescriptor,
      nil,
      copyfile_flags_t(COPYFILE_METADATA)
    )
    guard metadataCopied == 0 else {
      throw posixError("copy Kitty configuration metadata", context.kittyConfiguration)
    }
    guard fsync(temporaryDescriptor) == 0 else {
      throw posixError("sync Kitty configuration metadata", context.kittyConfiguration)
    }

    let rechecked = try readPinnedKittyConfiguration(
      parentDescriptor: parentDescriptor,
      context: context
    )
    guard sha256Digest(rechecked.data) == expectedDigest else {
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }
    try faultInjector(.replacementReady)
    let replaced = swap(
      parentDescriptor: parentDescriptor,
      first: temporaryName,
      second: "kitty.conf"
    )
    guard replaced == 0 else {
      throw posixError("replace Kitty configuration", context.kittyConfiguration)
    }
    do {
      try faultInjector(.replacementSwapped)
    } catch {
      cleanupTemporary = false
      throw error
    }

    let displaced: BoundedRegularFile
    do {
      displaced = try readPinnedKittyConfiguration(
        parentDescriptor: parentDescriptor,
        name: temporaryName,
        url: context.replacementURL
      )
    } catch {
      let restored = swap(
        parentDescriptor: parentDescriptor,
        first: temporaryName,
        second: "kitty.conf"
      )
      guard restored == 0 else {
        cleanupTemporary = false
        throw posixError(
          "restore concurrently changed Kitty configuration",
          context.replacementURL
        )
      }
      throw error
    }
    guard sha256Digest(displaced.data) == expectedDigest else {
      let restored = swap(
        parentDescriptor: parentDescriptor,
        first: temporaryName,
        second: "kitty.conf"
      )
      guard restored == 0 else {
        cleanupTemporary = false
        throw posixError(
          "restore concurrently changed Kitty configuration",
          context.replacementURL
        )
      }
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }
    guard temporaryName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
      throw posixError("remove displaced Kitty configuration", context.replacementURL)
    }
    cleanupTemporary = false

    let installed = try readPinnedKittyConfiguration(
      parentDescriptor: parentDescriptor,
      context: context
    )
    guard sha256Digest(installed.data) == sha256Digest(data) else {
      throw SetupOwnershipError.ownershipDrift(context.kittyConfiguration)
    }
  }

  private func openPinnedKittyParent(context: Context) throws -> Int32 {
    var descriptor = context.homeDirectory.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw posixError("open home directory", context.homeDirectory)
    }

    var candidate = context.homeDirectory
    for component in [".config", "kitty"] {
      candidate.append(path: component)
      let next = component.withCString {
        Darwin.openat(
          descriptor,
          $0,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
      }
      let code = errno
      Darwin.close(descriptor)
      guard next >= 0 else {
        throw posixError("open pinned Kitty directory", candidate, code: code)
      }
      descriptor = next
    }
    return descriptor
  }

  private func readPinnedKittyConfiguration(
    parentDescriptor: Int32,
    context: Context
  ) throws -> BoundedRegularFile {
    let descriptor = try openPinnedKittyConfiguration(
      parentDescriptor: parentDescriptor,
      name: "kitty.conf",
      url: context.kittyConfiguration
    )
    defer { Darwin.close(descriptor) }
    return try readPinnedKittyConfiguration(descriptor: descriptor, context: context)
  }

  private func readPinnedKittyConfiguration(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> BoundedRegularFile {
    let descriptor = try openPinnedKittyConfiguration(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    defer { Darwin.close(descriptor) }
    do {
      return try BoundedRegularFile.read(
        descriptor: descriptor,
        maximumSize: Self.maximumConfigurationSize
      )
    } catch {
      throw SetupOwnershipError.system(
        "read pinned Kitty configuration", url, String(describing: error)
      )
    }
  }

  private func readPinnedKittyConfiguration(
    descriptor: Int32,
    context: Context
  ) throws -> BoundedRegularFile {
    do {
      return try BoundedRegularFile.read(
        descriptor: descriptor,
        maximumSize: Self.maximumConfigurationSize
      )
    } catch {
      throw SetupOwnershipError.system(
        "read pinned Kitty configuration",
        context.kittyConfiguration,
        String(describing: error)
      )
    }
  }

  private func openPinnedKittyConfiguration(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> Int32 {
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw posixError("open pinned Kitty configuration", url)
    }
    return descriptor
  }

  private func swap(parentDescriptor: Int32, first: String, second: String) -> Int32 {
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

  private func write(_ data: Data, descriptor: Int32, url: URL) throws {
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
          throw posixError("write temporary Kitty configuration", url)
        }
        guard count > 0 else {
          throw SetupOwnershipError.system(
            "write temporary Kitty configuration", url, "write returned zero bytes"
          )
        }
        offset += count
      }
    }
  }

  private func posixError(
    _ operation: String,
    _ url: URL,
    code: Int32 = errno
  ) -> SetupOwnershipError {
    .system(operation, url, String(cString: strerror(code)))
  }

  private func removeRegularFileIfPresent(
    _ url: URL,
    unsafe error: SetupOwnershipError
  ) throws {
    guard try validateRegularFileIfPresent(url, unsafe: error) else { return }
    guard Darwin.unlink(url.path) == 0 else {
      throw posixError("remove setup state", url)
    }
  }

  private func validateRegularFileIfPresent(
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

  private func itemExists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return true }
    if errno == ENOENT { return false }
    throw SetupOwnershipError.system(
      "inspect", url, String(cString: strerror(errno))
    )
  }

  private func hasValidExternalInclude(_ data: Data, context: Context) throws -> Bool {
    let configuration = String(decoding: data, as: UTF8.self)
    let targets = configuration.components(separatedBy: .newlines).compactMap { line in
      includeTarget(line, context: context)
    }
    let macarchyTargets = targets.filter { target in
      target.path == context.stateRoot.path
        || target.path.hasPrefix(context.stateRoot.path + "/")
    }
    let expectedCount = macarchyTargets.count { $0.path == context.bridgeURL.path }
    if expectedCount > 1 || macarchyTargets.count != expectedCount {
      throw SetupOwnershipError.conflictingKittyInclude(context.kittyConfiguration)
    }
    return expectedCount == 1
  }

  private func includeTarget(_ line: String, context: Context) -> URL? {
    let fields = line.split(
      maxSplits: 1,
      omittingEmptySubsequences: true,
      whereSeparator: { $0.isWhitespace }
    )
    guard fields.count == 2, fields[0] == "include" else { return nil }
    var path = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    if (path.hasPrefix("\"") && path.hasSuffix("\""))
      || (path.hasPrefix("'") && path.hasSuffix("'"))
    {
      path.removeFirst()
      path.removeLast()
    }
    if path.hasPrefix("~/") {
      return context.homeDirectory.appending(path: String(path.dropFirst(2))).standardizedFileURL
    }
    if path.hasPrefix("/") {
      return URL(filePath: path).standardizedFileURL
    }
    return context.kittyConfiguration.deletingLastPathComponent()
      .appending(path: path).standardizedFileURL
  }

  private func addingInclude(_ original: Data, directive: String) -> Data {
    var configuration = String(decoding: original, as: UTF8.self)
    if !configuration.isEmpty, !configuration.hasSuffix("\n") {
      configuration.append("\n")
    }
    configuration.append("\(directive)\n")
    return Data(configuration.utf8)
  }

  private func pathContainsSymlink(_ target: URL, below home: URL) throws -> Bool {
    let home = home.standardizedFileURL
    let target = target.standardizedFileURL
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard target.path.hasPrefix(prefix) else {
      throw SetupOwnershipError.invalidManifest("Kitty target is outside the selected home")
    }

    let relative = String(target.path.dropFirst(prefix.count))
    var candidate = home
    for component in relative.split(separator: "/") {
      candidate.append(path: String(component))
      var metadata = stat()
      guard lstat(candidate.path, &metadata) == 0 else {
        let cause = String(cString: strerror(errno))
        throw SetupOwnershipError.system("inspect", candidate, cause)
      }
      if metadata.st_mode & S_IFMT == S_IFLNK { return true }
    }
    return false
  }

  private func result(
    context: Context,
    status: SetupIntegrationResult.Status,
    message: String,
    mutationAttempted: Bool = false
  ) -> SetupIntegrationResult {
    SetupIntegrationResult(
      id: Self.integrationID,
      status: status,
      target: context.kittyConfiguration.path,
      message: message,
      mutationAttempted: mutationAttempted
    )
  }

  private struct Context {
    let homeDirectory: URL
    let stateRoot: URL
    let kittyConfiguration: URL
    let includeDirective: String
    let manifestURL: URL
    let backupRelativePath = "state/setup/backups/kitty.conf"

    init(homeDirectory: URL) {
      let homeDirectory = homeDirectory.standardizedFileURL
      let stateRoot = homeDirectory.appending(
        path: ".config/macarchy", directoryHint: .isDirectory)
      self.homeDirectory = homeDirectory
      self.stateRoot = stateRoot
      kittyConfiguration = homeDirectory.appending(path: ".config/kitty/kitty.conf")
      includeDirective = ThemeActivationCoordinator.kittyIncludeDirective(root: stateRoot)
      manifestURL = stateRoot.appending(path: "state/setup/ownership.json")
    }

    var backupURL: URL {
      stateRoot.appending(path: backupRelativePath)
    }

    var bridgeURL: URL {
      stateRoot.appending(path: "state/adapters/kitty.conf")
    }

    let replacementName = ".macarchy-kitty-transaction"

    var replacementURL: URL {
      kittyConfiguration.deletingLastPathComponent().appending(path: replacementName)
    }
  }
}

private struct SetupOwnershipManifest: Codable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let records: [SetupOwnershipRecord]

  init(records: [SetupOwnershipRecord]) {
    schemaVersion = Self.currentSchemaVersion
    self.records = records
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case records
  }
}

private struct SetupOwnershipRecord: Codable {
  enum Phase: String, Codable {
    case applied
    case prepared
  }

  let id: String
  let phase: Phase
  let targetPath: String
  let backupPath: String
  let originalDigest: String
  let installedDigest: String

  var applied: SetupOwnershipRecord {
    SetupOwnershipRecord(
      id: id,
      phase: .applied,
      targetPath: targetPath,
      backupPath: backupPath,
      originalDigest: originalDigest,
      installedDigest: installedDigest
    )
  }

  enum CodingKeys: String, CodingKey {
    case id
    case phase
    case targetPath = "target_path"
    case backupPath = "backup_path"
    case originalDigest = "original_digest"
    case installedDigest = "installed_digest"
  }
}

struct TeardownCommandRunner: Sendable {
  let ownershipManager: SetupOwnershipManager

  static let live = TeardownCommandRunner(ownershipManager: SetupOwnershipManager())

  func execute(
    homeDirectory: URL,
    dryRun: Bool,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let integration: SetupIntegrationResult
    do {
      integration = try ownershipManager.teardown(
        homeDirectory: homeDirectory,
        dryRun: dryRun
      )
    } catch {
      let mutationAttempted = error is SetupOwnershipTransactionError
      integration = SetupIntegrationResult(
        id: SetupOwnershipManager.integrationID,
        status: .failed,
        target: homeDirectory.appending(path: ".config/kitty/kitty.conf").path,
        message: String(describing: error),
        mutationAttempted: mutationAttempted
      )
    }
    let report = TeardownReport(dryRun: dryRun, integration: integration)
    return (try report.render(json: json), integration.succeeded)
  }
}

private struct TeardownReport: Encodable {
  let schemaVersion = 1
  let operation = "teardown"
  let dryRun: Bool
  let integration: SetupIntegrationResult

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    let mutation =
      integration.mutationAttempted
      ? "Recorded integration mutation attempted." : "No changes made."
    return [
      "Macarchy teardown\(dryRun ? " (dry run)" : ""):",
      "- \(integration.id) [\(integration.status.rawValue)]: \(integration.message)",
      mutation,
    ].joined(separator: "\n")
  }
}
