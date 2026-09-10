import Darwin
import Foundation
import ThemeCore

/// The native tree is user-owned and deliberately outside the removable runtime root.
/// Only its four theme bridges and the public entry link remain Macarchy-owned.
struct EnvironmentNeovimMigration: Sendable {
  static let themePaths = [
    "colors/macarchy-imported.lua", "lua/config/macarchy-theme.lua",
    "lua/macarchy/current.lua", "lua/plugins/colorscheme.lua",
  ]
  let homeDirectory: URL
  let stateRoot: URL

  var nativeRoot: URL { homeDirectory.appending(path: ".config/nvim-native") }
  var publicURL: URL { homeDirectory.appending(path: ".config/nvim") }
  var legacyTarget: String { stateRoot.appending(path: "environment/current/neovim").path }

  func isNative(_ ownership: EnvironmentOwnership?) -> Bool {
    ownership?.records.contains { $0.id == .neovim && $0.managedTarget == nativeRoot.path } == true
  }

  func allows(_ record: EnvironmentOwnershipRecord, entry: EnvironmentManagedEntry) -> Bool {
    record.publicPath == entry.url.path && record.managedKind == entry.kind.rawValue
      && (record.managedTarget == entry.target
        || (record.id == .neovim && record.managedTarget == nativeRoot.path))
  }

  func validateNativeTree() throws {
    let directory = try PinnedFilesystem.openDirectory(at: nativeRoot)
    defer { Darwin.close(directory) }
    guard access(nativeRoot.path, W_OK) == 0 else {
      throw EnvironmentLifecycleError.drift("Neovim native configuration is not writable")
    }
    for path in Self.themePaths {
      let url = nativeRoot.appending(path: path)
      let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
      defer { Darwin.close(parent) }
      guard
        try PinnedFilesystem.symlinkDestination(
          parentDescriptor: parent, name: url.lastPathComponent, url: url
        ) == stateRoot.appending(path: "environment/current/neovim/\(path)").path
      else {
        throw EnvironmentLifecycleError.drift("Neovim theme bridge: \(url.path)")
      }
    }
    let lock = nativeRoot.appending(path: "lazy-lock.json")
    var metadata = stat()
    if lstat(lock.path, &metadata) == 0 {
      guard metadata.st_mode & S_IFMT == S_IFREG, access(lock.path, W_OK) == 0 else {
        throw EnvironmentLifecycleError.drift(
          "Neovim lazy-lock.json must be an ordinary writable file")
      }
    } else if errno != ENOENT {
      throw EnvironmentLifecycleError.system("inspect Neovim lockfile", lock, errno)
    }
  }

  struct Plan: Encodable {
    let source: String
    let destination: String
    let approval: String
    let message: String
  }

  func plan() throws -> (Plan, EnvironmentOwnership) {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard !store.transactionExists else {
      throw EnvironmentLifecycleError.blocked("recover the pending environment transaction first")
    }
    guard let ownership = try store.readOwnership(),
      let record = ownership.records.first(where: { $0.id == .neovim }),
      record.publicPath == publicURL.path, record.managedKind == "symbolic_link",
      record.managedTarget == legacyTarget
    else {
      throw EnvironmentLifecycleError.blocked(
        "migration requires an owned, immutable Neovim configuration")
    }
    let inspector = EnvironmentProviderInspector()
    guard try inspector.managedEntryIsExact(inspector.managedEntry(from: record)) else {
      throw EnvironmentLifecycleError.drift(publicURL.path)
    }
    let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
    guard try generations.currentDestination() == "generations/\(ownership.generationID)" else {
      throw EnvironmentLifecycleError.drift("environment pointer and ownership disagree")
    }
    let manifest = try generations.manifest(generationID: ownership.generationID)
    let paths = Set(manifest.artifacts.keys.filter { $0.hasPrefix("neovim/") })
    guard paths.contains("neovim/init.lua"), paths.contains("neovim/lazy-lock.json"),
      Self.themePaths.allSatisfy({ paths.contains("neovim/\($0)") })
    else {
      throw EnvironmentLifecycleError.blocked("the active generation has no complete Neovim seed")
    }
    let parent = try PinnedFilesystem.openDirectory(at: nativeRoot.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    var metadata = stat()
    guard lstat(nativeRoot.path, &metadata) != 0 else {
      throw EnvironmentLifecycleError.blocked(
        "destination already exists; it will not be overwritten: \(nativeRoot.path)")
    }
    guard errno == ENOENT else {
      throw EnvironmentLifecycleError.system("inspect native destination", nativeRoot, errno)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = sha256Digest(
      try encoder.encode(ownership) + Data(nativeRoot.path.utf8)
        + Data(manifest.renderedDigest.utf8))
    return (
      Plan(
        source: stateRoot.appending(
          path: "environment/generations/\(ownership.generationID)/neovim"
        ).path,
        destination: nativeRoot.path, approval: digest,
        message:
          "Preserve the active configuration as writable user files; manage only theme bridges. No plugin downloads. Reapply preserves edits; teardown restores the old entry and retains this native tree."
      ), ownership
    )
  }

  /// Seed once from the validated sealed generation. Never execute Lua or copy a live cache.
  func seed(_ ownership: EnvironmentOwnership) throws {
    let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
    let manifest = try generations.manifest(generationID: ownership.generationID)
    let paths = manifest.artifacts.keys.filter { $0.hasPrefix("neovim/") }.sorted()
    let parentURL = nativeRoot.deletingLastPathComponent()
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    let temporary = parentURL.appending(
      path: ".macarchy-neovim-\(UUID().uuidString.lowercased()).seed")
    let directory = try PinnedFilesystem.createDirectory(
      parentDescriptor: parent, name: temporary.lastPathComponent, url: temporary)
    Darwin.close(directory)
    // Only this newly-created private staging tree may be removed on failure.
    defer { try? FileManager.default.removeItem(at: temporary) }
    var directories: Set<URL> = [temporary]
    for path in paths {
      let relative = String(path.dropFirst("neovim/".count))
      let target = temporary.appending(path: relative)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      var ancestor = target.deletingLastPathComponent()
      while ancestor.path.hasPrefix(temporary.path + "/") {
        directories.insert(ancestor)
        ancestor.deleteLastPathComponent()
      }
      let targetParent = try PinnedFilesystem.openDirectory(at: target.deletingLastPathComponent())
      defer { Darwin.close(targetParent) }
      if Self.themePaths.contains(relative) {
        try FileManager.default.createSymbolicLink(
          at: target, withDestinationURL: stateRoot.appending(path: "environment/current/\(path)"))
      } else {
        let data = try generations.validatedArtifact(
          generationID: ownership.generationID, path: path)
        try PinnedFilesystem.writeNewRegularFile(
          parentDescriptor: targetParent, name: target.lastPathComponent, url: target,
          data: data, mode: 0o600)
      }
    }
    for url in directories.sorted(by: { $0.path.count > $1.path.count }) {
      let descriptor = try PinnedFilesystem.openDirectory(at: url)
      defer { Darwin.close(descriptor) }
      guard fsync(descriptor) == 0 else {
        throw EnvironmentLifecycleError.system("sync Neovim seed directory", url, errno)
      }
    }
    let result = temporary.lastPathComponent.withCString { source in
      nativeRoot.lastPathComponent.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0, fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("publish native Neovim seed", nativeRoot, errno)
    }
    try validateNativeTree()
  }

  /// Used by both immediate cutover and the existing environment journal's recovery.
  func transition(from old: EnvironmentOwnership, to new: EnvironmentOwnership) throws {
    guard let before = old.records.first(where: { $0.id == .neovim }),
      let after = new.records.first(where: { $0.id == .neovim }),
      old.replacingNeovimTarget(after.managedTarget) == new,
      Set([before.managedTarget, after.managedTarget]) == Set([legacyTarget, nativeRoot.path]),
      before.publicPath == publicURL.path, before.managedKind == "symbolic_link"
    else { throw EnvironmentLifecycleError.blocked("Neovim migration changes unrelated ownership") }
    guard
      try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination()
        == "generations/\(old.generationID)"
    else {
      throw EnvironmentLifecycleError.drift("environment pointer changed during Neovim migration")
    }
    if after.managedTarget == nativeRoot.path { try validateNativeTree() }
    let parent = try PinnedFilesystem.openDirectory(at: publicURL.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let destination = try PinnedFilesystem.symlinkDestination(
      parentDescriptor: parent, name: publicURL.lastPathComponent, url: publicURL)
    if destination == after.managedTarget { return }
    guard destination == before.managedTarget else {
      throw EnvironmentLifecycleError.drift(publicURL.path)
    }
    let name = ".macarchy-neovim-\(UUID().uuidString.lowercased()).link"
    let created = after.managedTarget.withCString { Darwin.symlinkat($0, parent, name) }
    guard created == 0 else {
      throw EnvironmentLifecycleError.system("stage native Neovim entry", publicURL, errno)
    }
    defer { name.withCString { _ = Darwin.unlinkat(parent, $0, 0) } }
    let replaced = name.withCString { source in
      publicURL.lastPathComponent.withCString { Darwin.renameat(parent, source, parent, $0) }
    }
    guard replaced == 0, fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("switch native Neovim entry", publicURL, errno)
    }
  }
}

extension EnvironmentOwnership {
  func replacingNeovimTarget(_ target: String) -> Self {
    Self(
      generationID: generationID,
      records: records.map { record in
        guard record.id == .neovim else { return record }
        return EnvironmentOwnershipRecord(
          id: record.id, publicPath: record.publicPath, managedKind: record.managedKind,
          managedTarget: target, original: record.original, retainedPath: record.retainedPath)
      },
      createdDirectories: createdDirectories, originalThemeBridges: originalThemeBridges,
      btop: btop, borders: borders, codex: codex, herdr: herdr, pi: pi,
      spicetify: spicetify, tuicr: tuicr, codexEnabled: codexEnabled,
      herdrEnabled: herdrEnabled, piEnabled: piEnabled, slackEnabled: slackEnabled,
      spicetifyEnabled: spicetifyEnabled, tuicrEnabled: tuicrEnabled,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs)
  }
}

extension EnvironmentTransactionCoordinator {
  func migrateNeovimLocked(approval: String) throws -> String {
    let migration = EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
    let (plan, previous) = try migration.plan()
    guard approval == plan.approval else {
      throw EnvironmentLifecycleError.blocked(
        "Neovim migration approval changed; review the plan again")
    }
    let proposed = previous.replacingNeovimTarget(migration.nativeRoot.path)
    try migration.seed(previous)
    let transaction = EnvironmentTransaction(
      operation: .neovimMigration, previousOwnership: previous, proposedOwnership: proposed,
      previousCurrentDestination: "generations/\(previous.generationID)")
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    try store.writeTransaction(transaction)
    do {
      try migration.transition(from: previous, to: proposed)
      try store.writeOwnership(proposed)
      try faultInjector(.authorityPublished)
      try store.removeTransaction()
    } catch {
      let failure = error
      try store.writeTransaction(transaction.rollingBack)
      try migration.transition(from: proposed, to: previous)
      try store.writeOwnership(previous)
      try store.removeTransaction()
      throw EnvironmentLifecycleError.blocked(
        "Neovim entry rolled back; the writable copy is preserved at \(migration.nativeRoot.path). \(failure)"
      )
    }
    return
      "Neovim now uses writable configuration at \(migration.nativeRoot.path). Restart Neovim before using Lazy. No plugins were downloaded; old dotfiles are untouched."
  }
}
