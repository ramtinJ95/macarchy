import Darwin
import Foundation
import ThemeCore

/// Releases one managed entry, without changing generations or running providers.
struct EnvironmentStandardMigration: Sendable {
  struct Intent: Codable, Equatable, Sendable {
    let provider: EnvironmentNativeSeed.Provider
    let source: String
    let linkTarget: String?
    let staging: String
    let device: UInt64?
    let inode: UInt64?
  }

  struct Plan: Encodable {
    let source: String
    let destination: String
    let retainedBackup: String?
    let approval: String
    let message: String
  }

  let provider: EnvironmentNativeSeed.Provider
  let homeDirectory: URL
  let stateRoot: URL
  let sourceURL: URL

  var publicURL: URL {
    let standard = provider.standardURL(homeDirectory: homeDirectory)
    return provider == .kitty ? standard.deletingLastPathComponent() : standard
  }

  func plan() throws -> (Plan, EnvironmentTransaction) {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard !store.transactionExists, let previous = try store.readOwnership(),
      let record = previous.records.first(where: { $0.id == provider.entryID })
    else {
      throw EnvironmentLifecycleError.blocked(
        "migration requires an owned entry and no pending transaction")
    }
    try validateRecord(record)
    guard try oldEntryIsExact(record, at: publicURL) else {
      throw EnvironmentLifecycleError.drift(publicURL.path)
    }
    guard
      EnvironmentNativeSource.targetIsAllowed(
        sourceURL.path, homeDirectory: homeDirectory, stateRoot: stateRoot)
    else { throw EnvironmentLifecycleError.blocked("prepare a source outside managed entries") }
    try EnvironmentStandardNativeConfiguration.validate(
      provider, homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: sourceURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var evidence = try encoder.encode(previous) + Data(sourceURL.path.utf8)
    var device: UInt64?
    var inode: UInt64?
    var linkTarget: String?
    if provider == .neovim {
      let sourceMetadata = try metadata(sourceURL)
      guard let sourceMetadata, sourceMetadata.st_mode & S_IFMT == S_IFDIR,
        let parent = try metadata(publicURL.deletingLastPathComponent()),
        sourceMetadata.st_dev == parent.st_dev
      else {
        throw EnvironmentLifecycleError.blocked(
          "Neovim migration requires an ordinary writable source directory on the same volume")
      }
      device = UInt64(sourceMetadata.st_dev)
      inode = UInt64(sourceMetadata.st_ino)
      evidence += Data("\(sourceMetadata.st_dev):\(sourceMetadata.st_ino)".utf8)
    } else {
      evidence += try BoundedRegularFile.read(at: sourceURL.resolvingSymlinksInPath()).data
      let target = provider == .kitty ? sourceURL.deletingLastPathComponent() : sourceURL
      guard provider != .kitty || sourceURL.lastPathComponent == "kitty.conf" else {
        throw EnvironmentLifecycleError.blocked("Kitty source must be named kitty.conf")
      }
      linkTarget = target.path
      if let original = record.original.linkDestination {
        let originalURL = URL(filePath: original, relativeTo: publicURL.deletingLastPathComponent())
        if originalURL.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path {
          linkTarget = original
        }
      }
      evidence += Data((linkTarget ?? "").utf8)
    }
    let approval = sha256Digest(evidence)
    let staging =
      provider == .neovim
      ? sourceURL
      : publicURL.deletingLastPathComponent()
        .appending(path: ".macarchy-standard-\(provider.rawValue)-\(approval).link")
    if provider != .neovim, try metadata(staging) != nil {
      throw EnvironmentLifecycleError.blocked(
        "migration staging entry already exists: \(staging.path)")
    }
    let intent = Intent(
      provider: provider, source: sourceURL.path, linkTarget: linkTarget,
      staging: staging.path, device: device, inode: inode)
    let transaction = EnvironmentTransaction(
      operation: .standardMigration, standardMigration: intent,
      previousOwnership: previous,
      proposedOwnership: previous.releasingStandardEntry(provider.entryID),
      previousCurrentDestination: "generations/\(previous.generationID)")
    try validate(transaction)
    return (
      Plan(
        source: sourceURL.path, destination: publicURL.path,
        retainedBackup: record.retainedPath, approval: approval,
        message: provider == .neovim
          ? "Move the complete writable Neovim tree to its standard path without copying or downloading plugins. Preserve any original retained backup."
          : "Restore a user-owned dotfile link at the standard path. Preserve source bytes, original link spelling when applicable, and retained backups. No provider restart. Update explicit profile sources to the standard path before reapply."
      ), transaction
    )
  }

  func validate(_ transaction: EnvironmentTransaction) throws {
    guard let intent = transaction.standardMigration,
      intent.provider == provider, intent.source == sourceURL.path,
      let old = transaction.previousOwnership, let new = transaction.proposedOwnership,
      old.releasingStandardEntry(provider.entryID) == new,
      let record = old.records.first(where: { $0.id == provider.entryID }),
      try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination()
        == transaction.previousCurrentDestination,
      transaction.previousCurrentDestination == "generations/\(old.generationID)"
    else { throw EnvironmentLifecycleError.blocked("invalid standard migration authority") }
    try validateRecord(record)
    let current = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    guard current == old || current == new else {
      throw EnvironmentLifecycleError.drift("ownership changed during standard migration")
    }
    let staging = URL(filePath: intent.staging).standardizedFileURL
    if provider == .neovim {
      guard staging.path == sourceURL.path, intent.linkTarget == nil,
        intent.device != nil, intent.inode != nil,
        movePathIsAllowed()
      else { throw EnvironmentLifecycleError.blocked("invalid Neovim move intent") }
    } else {
      guard let target = intent.linkTarget, !target.isEmpty,
        intent.device == nil, intent.inode == nil,
        staging.deletingLastPathComponent().path == publicURL.deletingLastPathComponent().path,
        staging.lastPathComponent.hasPrefix(".macarchy-standard-\(provider.rawValue)-"),
        staging.lastPathComponent.hasSuffix(".link"),
        EnvironmentNativeSource.targetIsAllowed(
          sourceURL.path, homeDirectory: homeDirectory, stateRoot: stateRoot)
      else { throw EnvironmentLifecycleError.blocked("invalid standard link intent") }
      let targetURL = URL(filePath: target, relativeTo: publicURL.deletingLastPathComponent())
      let expected = provider == .kitty ? sourceURL.deletingLastPathComponent() : sourceURL
      guard targetURL.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path,
        provider != .kitty || sourceURL.lastPathComponent == "kitty.conf"
      else { throw EnvironmentLifecycleError.blocked("standard link does not select the source") }
    }
  }

  /// The journal precedes staging; a swap preserves both objects at every cutover boundary.
  func transition(_ transaction: EnvironmentTransaction) throws {
    try validate(transaction)
    let intent = transaction.standardMigration!
    let record = transaction.previousOwnership!.records.first { $0.id == provider.entryID }!
    let staging = URL(filePath: intent.staging)
    let forward = transaction.direction == .forward
    let oldPublic = try oldEntryIsExact(record, at: publicURL)
    let newPublic = try newEntryIsExact(intent, at: publicURL)
    if forward {
      if oldPublic {
        try EnvironmentStandardNativeConfiguration.validate(
          provider, homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: sourceURL)
        if provider != .neovim, try metadata(staging) == nil {
          try createLink(intent.linkTarget!, at: staging)
        }
        guard try newEntryIsExact(intent, at: staging) else {
          throw EnvironmentLifecycleError.drift("migration source or staged link changed")
        }
        try swap(publicURL, staging)
      } else if !newPublic {
        throw EnvironmentLifecycleError.drift(publicURL.path)
      }
      try EnvironmentStandardNativeConfiguration.validate(
        provider, homeDirectory: homeDirectory, stateRoot: stateRoot)
    } else {
      if newPublic {
        if try metadata(staging) == nil { try createOldEntry(record, at: staging) }
        if record.managedKind == "kitty_directory", try emptyDirectory(staging) {
          try createLink(record.managedTarget, at: staging.appending(path: "kitty.conf"))
        }
        guard try oldEntryIsExact(record, at: staging) else {
          throw EnvironmentLifecycleError.drift(staging.path)
        }
        try swap(publicURL, staging)
      } else if !oldPublic {
        throw EnvironmentLifecycleError.drift(publicURL.path)
      }
    }
  }

  func cleanup(_ transaction: EnvironmentTransaction) throws {
    let intent = transaction.standardMigration!
    let staging = URL(filePath: intent.staging)
    guard try metadata(staging) != nil else { return }
    if transaction.direction == .rollback {
      guard try newEntryIsExact(intent, at: staging) else {
        throw EnvironmentLifecycleError.drift(staging.path)
      }
      if provider != .neovim { try unlink(staging, directory: false) }
      return  // Never delete the restored user-owned Neovim tree.
    }
    let record = transaction.previousOwnership!.records.first { $0.id == provider.entryID }!
    // A crash between unlinking Kitty's only managed child and rmdir is resumable.
    if record.managedKind == "kitty_directory", try emptyDirectory(staging) {
      try unlink(staging, directory: true)
      return
    }
    guard try oldEntryIsExact(record, at: staging) else {
      throw EnvironmentLifecycleError.drift(staging.path)
    }
    if record.managedKind == "kitty_directory" {
      try unlink(staging.appending(path: "kitty.conf"), directory: false)
      try unlink(staging, directory: true)
    } else {
      try unlink(staging, directory: false)
    }
  }

  private func validateRecord(_ record: EnvironmentOwnershipRecord) throws {
    let inspector = EnvironmentProviderInspector()
    let expected = inspector.allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
      .first { $0.id == provider.entryID }!
    let native =
      provider == .neovim
      ? EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .allows(record, entry: expected)
      : (provider == .atuin || provider == .starship)
        && EnvironmentNativeFileMigration(
          provider: provider == .atuin ? .atuin : .starship,
          homeDirectory: homeDirectory, stateRoot: stateRoot
        ).allows(record, entry: expected)
    guard record.publicPath == publicURL.path,
      record.managedKind == expected.kind.rawValue,
      record.managedTarget == expected.target || native
        || (provider == .neovim && record.managedTarget == sourceURL.path && movePathIsAllowed())
    else { throw EnvironmentLifecycleError.blocked("unexpected managed migration entry") }
  }

  private func oldEntryIsExact(_ record: EnvironmentOwnershipRecord, at url: URL) throws -> Bool {
    let entry = EnvironmentManagedEntry(
      id: record.id, url: url,
      kind: record.managedKind == "kitty_directory" ? .kittyDirectory : .symbolicLink,
      target: record.managedTarget)
    return try EnvironmentProviderInspector().managedEntryIsExact(entry)
  }

  private func movePathIsAllowed() -> Bool {
    // After the swap the source leaf holds the old managed link, possibly pointing
    // into state (or at itself). Validate the location, never follow that leaf.
    let lexical = sourceURL.standardizedFileURL.path
    let physical = sourceURL.deletingLastPathComponent().resolvingSymlinksInPath()
      .appending(path: sourceURL.lastPathComponent).path
    guard sourceURL.path == lexical, lexical.hasPrefix("/"),
      !lexical.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return false }
    let protected =
      [stateRoot]
      + EnvironmentProviderInspector().allManagedEntries(
        homeDirectory: homeDirectory, stateRoot: stateRoot
      ).map(\.url)
    return protected.allSatisfy { entry in
      let location = entry.deletingLastPathComponent().resolvingSymlinksInPath()
        .appending(path: entry.lastPathComponent).path
      return [lexical, physical].allSatisfy { candidate in
        [entry.standardizedFileURL.path, location].allSatisfy { forbidden in
          candidate != forbidden && !candidate.hasPrefix(forbidden + "/")
            && !forbidden.hasPrefix(candidate + "/")
        }
      }
    }
  }

  private func newEntryIsExact(_ intent: Intent, at url: URL) throws -> Bool {
    guard let metadata = try metadata(url) else { return false }
    if provider == .neovim {
      return metadata.st_mode & S_IFMT == S_IFDIR
        && UInt64(metadata.st_dev) == intent.device && UInt64(metadata.st_ino) == intent.inode
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK else { return false }
    return try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == intent.linkTarget
  }

  private func metadata(_ url: URL) throws -> stat? {
    var value = stat()
    if lstat(url.path, &value) == 0 { return value }
    if errno == ENOENT { return nil }
    throw EnvironmentLifecycleError.system("inspect migration entry", url, errno)
  }

  private func emptyDirectory(_ url: URL) throws -> Bool {
    guard let value = try metadata(url), value.st_mode & S_IFMT == S_IFDIR else { return false }
    let directory = try PinnedFilesystem.openDirectory(at: url)
    defer { Darwin.close(directory) }
    let entries = try PinnedFilesystem.directoryEntries(descriptor: directory, url: url, limit: 1)
    return !entries.truncated && entries.entries.isEmpty
  }

  private func createLink(_ target: String, at url: URL) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    guard target.withCString({ Darwin.symlinkat($0, parent, url.lastPathComponent) }) == 0,
      fsync(parent) == 0
    else { throw EnvironmentLifecycleError.system("stage standard link", url, errno) }
  }

  private func createOldEntry(_ record: EnvironmentOwnershipRecord, at url: URL) throws {
    if record.managedKind == "kitty_directory" {
      guard mkdir(url.path, 0o700) == 0 else {
        throw EnvironmentLifecycleError.system("stage old Kitty directory", url, errno)
      }
      try createLink(record.managedTarget, at: url.appending(path: "kitty.conf"))
    } else {
      try createLink(record.managedTarget, at: url)
    }
  }

  private func swap(_ first: URL, _ second: URL) throws {
    let a = try PinnedFilesystem.openDirectory(at: first.deletingLastPathComponent())
    defer { Darwin.close(a) }
    let b = try PinnedFilesystem.openDirectory(at: second.deletingLastPathComponent())
    defer { Darwin.close(b) }
    guard
      Darwin.renameatx_np(
        a, first.lastPathComponent, b, second.lastPathComponent,
        UInt32(RENAME_SWAP)) == 0, fsync(a) == 0, fsync(b) == 0
    else { throw EnvironmentLifecycleError.system("swap standard configuration", first, errno) }
  }

  private func unlink(_ url: URL, directory: Bool) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    guard Darwin.unlinkat(parent, url.lastPathComponent, directory ? AT_REMOVEDIR : 0) == 0,
      fsync(parent) == 0
    else { throw EnvironmentLifecycleError.system("remove staged managed entry", url, errno) }
  }
}

extension EnvironmentTransactionCoordinator {
  func migrateStandardLocked(
    provider: EnvironmentNativeSeed.Provider, sourceURL: URL, approval: String
  ) throws -> String {
    let migration = EnvironmentStandardMigration(
      provider: provider, homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: sourceURL)
    let (plan, transaction) = try migration.plan()
    guard approval == plan.approval else {
      throw EnvironmentLifecycleError.blocked("standard migration approval changed; review again")
    }
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    try store.writeTransaction(transaction)
    do {
      try migration.transition(transaction)
      try store.writeOwnership(transaction.proposedOwnership)
      try faultInjector(.authorityPublished)
    } catch {
      let failure = error
      let rollback = transaction.rollingBack
      try store.writeTransaction(rollback)
      try finishStandardMigrationLocked(rollback)
      throw EnvironmentLifecycleError.blocked("standard migration rolled back: \(failure)")
    }
    // Cleanup errors retain forward authority and its journal for explicit recovery.
    try migration.cleanup(transaction)
    try store.removeTransaction()
    return "\(provider.rawValue) now uses user-owned configuration at \(plan.destination). "
      + "Retained backup: \(plan.retainedBackup ?? "none"). No runtime was restarted."
  }

  func finishStandardMigrationLocked(_ transaction: EnvironmentTransaction) throws {
    guard let intent = transaction.standardMigration else {
      throw EnvironmentLifecycleError.blocked("standard migration has no intent")
    }
    let migration = EnvironmentStandardMigration(
      provider: intent.provider, homeDirectory: homeDirectory, stateRoot: stateRoot,
      sourceURL: URL(filePath: intent.source))
    try migration.transition(transaction)
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    try store.writeOwnership(
      transaction.direction == .forward
        ? transaction.proposedOwnership : transaction.previousOwnership)
    try migration.cleanup(transaction)
    try store.removeTransaction()
  }
}
