import Darwin
import Foundation
import ThemeCore

/// The native tree is user-owned and deliberately outside the removable runtime root.
/// Only its four theme bridges and the public entry link remain Macarchy-owned.
struct EnvironmentNeovimMigration: Sendable {
  static let themePaths = NeovimAdapter.managedThemePaths
  let homeDirectory: URL
  let stateRoot: URL
  var sourceURL: URL? = nil

  var nativeRoot: URL { sourceURL ?? homeDirectory.appending(path: ".config/nvim-native") }
  var publicURL: URL { homeDirectory.appending(path: ".config/nvim") }
  var legacyTarget: String { stateRoot.appending(path: "environment/current/neovim").path }

  func isNative(_ ownership: EnvironmentOwnership?) -> Bool {
    nativeTarget(in: ownership) != nil
  }

  func nativeTarget(in ownership: EnvironmentOwnership?) -> URL? {
    if ownership?.standardNativeEntries?.contains(.neovim) == true { return publicURL }
    guard let record = ownership?.records.first(where: { $0.id == .neovim }),
      record.publicPath == publicURL.path, record.managedKind == "symbolic_link",
      targetIsAllowed(record.managedTarget)
    else { return nil }
    return URL(filePath: record.managedTarget)
  }

  func targetIsAllowed(_ path: String, userOwnedPublicEntry: Bool = false) -> Bool {
    guard
      EnvironmentNativeSource.targetIsAllowed(
        path, homeDirectory: homeDirectory, stateRoot: stateRoot,
        userOwnedPublicEntry: userOwnedPublicEntry ? .neovim : nil)
    else { return false }
    let resolved = URL(filePath: path).resolvingSymlinksInPath().path
    // A directory containing its own public connection or managed state is not
    // an external native configuration tree.
    let protected =
      [stateRoot]
      + EnvironmentProviderInspector().allManagedEntries(
        homeDirectory: homeDirectory, stateRoot: stateRoot
      ).map(\.url)
    return !protected.contains {
      let physical = $0.deletingLastPathComponent().resolvingSymlinksInPath()
        .appending(path: $0.lastPathComponent).path
      return physical.hasPrefix(resolved + "/")
    }
  }

  func allows(_ record: EnvironmentOwnershipRecord, entry: EnvironmentManagedEntry) -> Bool {
    record.publicPath == entry.url.path && record.managedKind == entry.kind.rawValue
      && (record.managedTarget == entry.target
        || (record.id == .neovim && targetIsAllowed(record.managedTarget)))
  }

  /// The root's authority covers ordinary descendants, not a leaf link escaping
  /// into generated state or another provider. Keep root and leaf checks distinct:
  /// the public-entry exemption deliberately permits only the exact root path.
  func writableInitURL(at source: URL) throws -> URL {
    guard targetIsAllowed(source.path, userOwnedPublicEntry: true) else {
      throw EnvironmentLifecycleError.blocked("Neovim source overlaps managed configuration")
    }
    let root = source.resolvingSymlinksInPath()
    let file = root.appending(path: "init.lua").resolvingSymlinksInPath()
    guard
      file.path.hasPrefix(root.path + "/")
        || EnvironmentNativeSource.targetIsAllowed(
          file.path, homeDirectory: homeDirectory, stateRoot: stateRoot)
    else {
      throw EnvironmentLifecycleError.blocked("Neovim init.lua points into managed configuration")
    }
    var metadata = stat()
    guard lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      access(file.path, R_OK | W_OK) == 0
    else {
      throw EnvironmentLifecycleError.blocked(
        "Neovim init.lua must be an ordinary readable, writable file")
    }
    return file
  }

  func validateNativeTree(at selectedURL: URL? = nil, userOwnedPublicEntry: Bool = false) throws {
    let selected = selectedURL ?? self.nativeRoot
    guard targetIsAllowed(selected.path, userOwnedPublicEntry: userOwnedPublicEntry) else {
      throw EnvironmentLifecycleError.blocked(
        "native Neovim source must live outside managed provider entries and Macarchy state")
    }
    let nativeRoot = selected.resolvingSymlinksInPath()
    let directory = try PinnedFilesystem.openDirectory(at: nativeRoot)
    defer { Darwin.close(directory) }
    guard access(nativeRoot.path, W_OK) == 0 else {
      throw EnvironmentLifecycleError.drift("Neovim native configuration is not writable")
    }
    _ = try BoundedRegularFile.read(
      at: nativeRoot.appending(path: "init.lua").resolvingSymlinksInPath())
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
        || (sourceURL != nil && targetIsAllowed(record.managedTarget))
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
    if let sourceURL {
      guard sourceURL.path != record.managedTarget else {
        throw EnvironmentLifecycleError.blocked(
          "source connection requires a different Neovim target")
      }
      try validateNativeTree()
      let resolved = sourceURL.resolvingSymlinksInPath()
      let descriptor = try PinnedFilesystem.openDirectory(at: resolved)
      defer { Darwin.close(descriptor) }
      var identity = stat()
      guard fstat(descriptor, &identity) == 0 else {
        throw EnvironmentLifecycleError.system("inspect Neovim source", resolved, errno)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let initData = try BoundedRegularFile.read(
        at: resolved.appending(path: "init.lua").resolvingSymlinksInPath()
      ).data
      let digest = sha256Digest(
        try encoder.encode(ownership)
          + Data(
            "\(sourceURL.path)\n\(resolved.path)\n\(identity.st_dev):\(identity.st_ino)\n".utf8)
          + initData)
      return (
        Plan(
          source: sourceURL.path, destination: sourceURL.path, approval: digest,
          message:
            "Connect the prepared user-owned Neovim tree. Only the public link changes; no Lua execution, copies, plugin downloads or lockfile changes. Approval binds the directory identity, init.lua and exact four theme links, not arbitrary plugin behavior."
        ), ownership
      )
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
    let artifacts = try paths.map {
      EnvironmentConfigurationArtifact(
        path: $0,
        data: try generations.validatedArtifact(generationID: ownership.generationID, path: $0))
    }
    try Self.seedArtifacts(artifacts, destination: nativeRoot, stateRoot: stateRoot)
    try validateNativeTree()
  }

  /// Shared absent-only publication for shipped starters and reviewed legacy migration.
  static func seedArtifacts(
    _ artifacts: [EnvironmentConfigurationArtifact], destination nativeRoot: URL, stateRoot: URL
  ) throws {
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
    for artifact in artifacts {
      let path = artifact.path
      guard path.hasPrefix("neovim/"), !path.split(separator: "/").contains("..") else {
        throw EnvironmentLifecycleError.blocked("invalid native Neovim starter path: \(path)")
      }
      let relative = String(path.dropFirst("neovim/".count))
      let target = temporary.appending(path: relative)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
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
        try PinnedFilesystem.writeNewRegularFile(
          parentDescriptor: targetParent, name: target.lastPathComponent, url: target,
          data: artifact.data, mode: 0o600)
      }
    }
    for url in directories.sorted(by: { $0.path.count > $1.path.count }) {
      let descriptor = try PinnedFilesystem.openDirectory(at: url)
      defer { Darwin.close(descriptor) }
      guard fsync(descriptor) == 0 else {
        throw EnvironmentLifecycleError.system("sync Neovim seed directory", url, errno)
      }
    }
    guard
      PinnedFilesystem.renameExclusively(
        temporary.lastPathComponent, to: nativeRoot.lastPathComponent, in: parent),
      fsync(parent) == 0
    else {
      throw EnvironmentLifecycleError.system("publish native Neovim seed", nativeRoot, errno)
    }
  }

  /// Used by both immediate cutover and the existing environment journal's recovery.
  func transition(from old: EnvironmentOwnership, to new: EnvironmentOwnership) throws {
    guard let before = old.records.first(where: { $0.id == .neovim }),
      let after = new.records.first(where: { $0.id == .neovim }),
      old.replacingTarget(for: .neovim, with: after.managedTarget) == new,
      [before.managedTarget, after.managedTarget].allSatisfy({
        $0 == legacyTarget || targetIsAllowed($0)
      }),
      before.publicPath == publicURL.path, before.managedKind == "symbolic_link"
    else { throw EnvironmentLifecycleError.blocked("Neovim migration changes unrelated ownership") }
    guard
      try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination()
        == "generations/\(old.generationID)"
    else {
      throw EnvironmentLifecycleError.drift("environment pointer changed during Neovim migration")
    }
    if after.managedTarget != legacyTarget {
      try validateNativeTree(at: URL(filePath: after.managedTarget))
    }
    try EnvironmentNativeSource.switchPublicLink(
      at: publicURL, from: before.managedTarget, to: after.managedTarget,
      stagingPrefix: ".macarchy-neovim", entryLabel: "native Neovim entry")
  }
}

extension EnvironmentOwnership {
  func replacingTarget(for id: EnvironmentEntryID, with target: String) -> Self {
    Self(
      copying: self,
      generationID: generationID,
      records: records.map { record in
        guard record.id == id else { return record }
        return EnvironmentOwnershipRecord(
          id: record.id, publicPath: record.publicPath, managedKind: record.managedKind,
          managedTarget: target, original: record.original, retainedPath: record.retainedPath)
      },
      herdr: herdr, enabledThemeAdapterIDs: enabledThemeAdapterIDs,
      standardNativeEntries: standardNativeEntries ?? [])
  }
}

extension EnvironmentTransactionCoordinator {
  func migrateNeovimLocked(approval: String, sourceURL: URL? = nil) throws -> String {
    let migration = EnvironmentNeovimMigration(
      homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: sourceURL)
    let (plan, previous) = try migration.plan()
    guard approval == plan.approval else {
      throw EnvironmentLifecycleError.blocked(
        "Neovim migration approval changed; review the plan again")
    }
    let proposed = previous.replacingTarget(for: .neovim, with: migration.nativeRoot.path)
    if sourceURL == nil { try migration.seed(previous) }
    try journaledNativeMigration(
      .neovimMigration, from: previous, to: proposed, label: "Neovim",
      preservedPath: migration.nativeRoot.path
    ) { try migration.transition(from: $0, to: $1) }
    return
      "Neovim now uses writable configuration at \(migration.nativeRoot.path). Restart Neovim before using Lazy. No plugins were downloaded; old dotfiles are untouched."
  }
}
