import Darwin
import Foundation
import ThemeCore

/// Shared absent-only publication and scoped cutover for native TOML seeds.
struct EnvironmentNativeFileMigration: Sendable {
  enum Provider: String, Sendable {
    case atuin, starship
    var label: String { self == .atuin ? "Atuin" : "Starship" }
    var entryID: EnvironmentEntryID { self == .atuin ? .atuinConfiguration : .starship }
    var operation: EnvironmentTransactionOperation {
      self == .atuin ? .atuinMigration : .starshipMigration
    }
    var artifact: String { self == .atuin ? "atuin/config.toml" : "starship/behavior.toml" }
  }

  let provider: Provider
  let homeDirectory: URL
  let stateRoot: URL
  var sourceURL: URL? = nil

  var nativeURL: URL {
    sourceURL ?? homeDirectory.appending(path: ".config/\(provider.rawValue)-native.toml")
  }
  var publicURL: URL {
    homeDirectory.appending(
      path: provider == .atuin ? ".config/atuin/config.toml" : ".config/starship.toml")
  }
  var legacyTarget: String {
    stateRoot.appending(
      path: provider == .atuin
        ? "environment/current/atuin/config.toml" : StarshipAdapter.bridgePath
    ).path
  }

  func nativeTarget(in ownership: EnvironmentOwnership?) -> URL? {
    if ownership?.standardNativeEntries?.contains(provider.entryID) == true {
      return publicURL
    }
    guard let record = ownership?.records.first(where: { $0.id == provider.entryID }),
      record.publicPath == publicURL.path, record.managedKind == "symbolic_link",
      nativeTargetIsAllowed(record.managedTarget)
    else { return nil }
    return URL(filePath: record.managedTarget)
  }

  private func nativeTargetIsAllowed(_ path: String) -> Bool {
    EnvironmentNativeSource.targetIsAllowed(
      path, homeDirectory: homeDirectory, stateRoot: stateRoot)
  }

  func allows(_ record: EnvironmentOwnershipRecord, entry: EnvironmentManagedEntry) -> Bool {
    record.id == provider.entryID && record.publicPath == entry.url.path
      && record.managedKind == entry.kind.rawValue && nativeTargetIsAllowed(record.managedTarget)
  }

  func validateNativeFile(at selectedURL: URL? = nil, userOwnedPublicEntry: Bool = false) throws {
    let nativeURL = selectedURL ?? self.nativeURL
    guard
      EnvironmentNativeSource.targetIsAllowed(
        nativeURL.path, homeDirectory: homeDirectory, stateRoot: stateRoot,
        userOwnedPublicEntry: userOwnedPublicEntry ? provider.entryID : nil)
    else {
      throw EnvironmentLifecycleError.blocked(
        "native source must live outside managed provider entries and Macarchy state")
    }
    if provider == .starship {
      let native = StarshipNativeConfiguration(url: nativeURL.resolvingSymlinksInPath())
      let data = try native.read()
      guard let text = String(data: data, encoding: .utf8) else {
        throw EnvironmentLifecycleError.drift("native Starship configuration is not UTF-8")
      }
      _ = try native.replacingPalette(in: data, with: text)
      return
    }
    let resolved = nativeURL.resolvingSymlinksInPath()
    let parent = try PinnedFilesystem.openDirectory(at: resolved.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let data = try PinnedFilesystem.readRegularFile(
      parentDescriptor: parent, name: resolved.lastPathComponent, url: resolved)
    guard access(nativeURL.path, W_OK) == 0,
      let text = String(data: data.data, encoding: .utf8), AtuinAdapter.selectsTheme(in: text)
    else {
      throw EnvironmentLifecycleError.drift(
        "native Atuin configuration must be writable and select the Macarchy theme")
    }
  }

  struct Plan: Encodable {
    let source: String
    let destination: String
    let approval: String
    let message: String
  }

  private func seedData(_ ownership: EnvironmentOwnership) throws -> Data {
    let data = try EnvironmentGenerationStore(stateRoot: stateRoot).validatedArtifact(
      generationID: ownership.generationID, path: provider.artifact)
    guard provider == .starship else {
      guard let text = String(data: data, encoding: .utf8), AtuinAdapter.selectsTheme(in: text)
      else {
        throw EnvironmentLifecycleError.blocked("the Atuin seed must select the Macarchy theme")
      }
      return data
    }
    let manifest = try ReconciliationStatusStore(root: stateRoot).activeManifest()
    let palette = try BoundedRegularFile.read(
      at: stateRoot.appending(
        path: "generations/\(manifest.generationID)/generated/starship.toml")
    ).data
    return try StarshipNativeConfiguration(url: nativeURL).seed(behavior: data, palette: palette)
  }

  func plan() throws -> (Plan, EnvironmentOwnership) {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard !store.transactionExists else {
      throw EnvironmentLifecycleError.blocked("recover the pending environment transaction first")
    }
    guard let ownership = try store.readOwnership(),
      let record = ownership.records.first(where: { $0.id == provider.entryID }),
      record.publicPath == publicURL.path, record.managedKind == "symbolic_link",
      record.managedTarget == legacyTarget
        || (sourceURL != nil && nativeTargetIsAllowed(record.managedTarget))
    else {
      throw EnvironmentLifecycleError.blocked(
        "migration requires an owned, immutable \(provider.label) configuration")
    }
    if let sourceURL {
      guard sourceURL.path != record.managedTarget else {
        throw EnvironmentLifecycleError.blocked(
          "source connection requires a different \(provider.label) target")
      }
      try validateNativeFile()
    }
    let inspector = EnvironmentProviderInspector()
    guard try inspector.managedEntryIsExact(inspector.managedEntry(from: record)) else {
      throw EnvironmentLifecycleError.drift(publicURL.path)
    }
    let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
    guard try generations.currentDestination() == "generations/\(ownership.generationID)" else {
      throw EnvironmentLifecycleError.drift("environment pointer and ownership disagree")
    }
    let data =
      try sourceURL.map { try BoundedRegularFile.read(at: $0.resolvingSymlinksInPath()).data }
      ?? seedData(ownership)
    if sourceURL == nil {
      let parent = try PinnedFilesystem.openDirectory(at: nativeURL.deletingLastPathComponent())
      defer { Darwin.close(parent) }
      var metadata = stat()
      guard lstat(nativeURL.path, &metadata) != 0 else {
        throw EnvironmentLifecycleError.blocked(
          "destination already exists; it will not be overwritten: \(nativeURL.path)")
      }
      guard errno == ENOENT else {
        throw EnvironmentLifecycleError.system("inspect native destination", nativeURL, errno)
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = sha256Digest(try encoder.encode(ownership) + Data(nativeURL.path.utf8) + data)
    return (
      Plan(
        source: sourceURL?.path
          ?? stateRoot.appending(
            path: "environment/generations/\(ownership.generationID)/\(provider.artifact)"
          ).path,
        destination: nativeURL.path, approval: digest,
        message: sourceURL != nil
          ? "Connect the existing user-owned \(provider.label) file without copying its contents. Only the public config link changes. Reapply preserves behavior; Starship reconciliation updates only its reserved palette."
          : "Seed the active \(provider.label) settings as a writable native file. Reapply preserves behavior edits; theme selection remains managed. Starship colors are reconciled narrowly in its reserved palette. No history database, sync state, shell or daemon is changed."
      ), ownership
    )
  }

  func seed(_ ownership: EnvironmentOwnership) throws {
    let data = try seedData(ownership)
    try EnvironmentNativeSeed.publishFile(
      data, at: nativeURL, temporaryPrefix: ".macarchy-\(provider.rawValue)",
      publishOperation: "publish native seed", syncOperation: "publish native seed")
    try validateNativeFile()
  }

  func transition(from old: EnvironmentOwnership, to new: EnvironmentOwnership) throws {
    guard let before = old.records.first(where: { $0.id == provider.entryID }),
      let after = new.records.first(where: { $0.id == provider.entryID }),
      old.replacingTarget(for: provider.entryID, with: after.managedTarget) == new,
      [before.managedTarget, after.managedTarget].allSatisfy({
        $0 == legacyTarget || nativeTargetIsAllowed($0)
      }),
      before.publicPath == publicURL.path, before.managedKind == "symbolic_link"
    else { throw EnvironmentLifecycleError.blocked("native migration changes unrelated ownership") }
    guard
      try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination()
        == "generations/\(old.generationID)"
    else {
      throw EnvironmentLifecycleError.drift("environment pointer changed during native migration")
    }
    if after.managedTarget != legacyTarget {
      try validateNativeFile(at: URL(filePath: after.managedTarget))
    }
    let parent = try PinnedFilesystem.openDirectory(at: publicURL.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let destination = try PinnedFilesystem.symlinkDestination(
      parentDescriptor: parent, name: publicURL.lastPathComponent, url: publicURL)
    if destination == after.managedTarget { return }
    guard destination == before.managedTarget else {
      throw EnvironmentLifecycleError.drift(publicURL.path)
    }
    let name = ".macarchy-\(provider.rawValue)-\(UUID().uuidString.lowercased()).link"
    guard after.managedTarget.withCString({ Darwin.symlinkat($0, parent, name) }) == 0 else {
      throw EnvironmentLifecycleError.system("stage native entry", publicURL, errno)
    }
    defer { name.withCString { _ = Darwin.unlinkat(parent, $0, 0) } }
    let result = name.withCString { source in
      publicURL.lastPathComponent.withCString { Darwin.renameat(parent, source, parent, $0) }
    }
    guard result == 0, fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("switch native entry", publicURL, errno)
    }
  }
}

/// Shared exclusion boundary for explicit external native provider connections.
enum EnvironmentNativeSource {
  static func targetIsAllowed(
    _ path: String, homeDirectory: URL, stateRoot: URL,
    userOwnedPublicEntry: EnvironmentEntryID? = nil
  ) -> Bool {
    let url = URL(filePath: path).standardizedFileURL
    guard path.hasPrefix("/"), path == url.path,
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return false }
    let resolved = url.resolvingSymlinksInPath().path
    let state = stateRoot.resolvingSymlinksInPath().path
    let lexicalState = stateRoot.standardizedFileURL.path
    guard path != lexicalState, !path.hasPrefix(lexicalState + "/"),
      resolved != state, !resolved.hasPrefix(state + "/")
    else { return false }
    for entry in EnvironmentProviderInspector().allManagedEntries(
      homeDirectory: homeDirectory, stateRoot: stateRoot)
    {
      // Only explicit native profile authority may exempt its exact standard path.
      // State exclusion above still rejects an incumbent managed-generation link.
      let standardPath =
        entry.id == .kitty
        ? entry.url.appending(path: "kitty.conf").path : entry.url.standardizedFileURL.path
      if entry.id == userOwnedPublicEntry, path == standardPath {
        continue
      }
      let physical = entry.url.deletingLastPathComponent().resolvingSymlinksInPath()
        .appending(path: entry.url.lastPathComponent).path
      for forbidden in [entry.url.standardizedFileURL.path, physical] {
        if path == forbidden || path.hasPrefix(forbidden + "/")
          || resolved == forbidden || resolved.hasPrefix(forbidden + "/")
        {
          return false
        }
      }
    }
    return true
  }
}

extension EnvironmentTransactionCoordinator {
  func migrateNativeFileLocked(
    provider: EnvironmentNativeFileMigration.Provider, approval: String, sourceURL: URL? = nil
  )
    throws -> String
  {
    let migration = EnvironmentNativeFileMigration(
      provider: provider, homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: sourceURL)
    let (plan, previous) = try migration.plan()
    guard approval == plan.approval else {
      throw EnvironmentLifecycleError.blocked(
        "\(provider.label) migration approval changed; review the plan again")
    }
    let proposed = previous.replacingTarget(
      for: provider.entryID, with: migration.nativeURL.path)
    if sourceURL == nil { try migration.seed(previous) }
    let transaction = EnvironmentTransaction(
      operation: provider.operation, previousOwnership: previous, proposedOwnership: proposed,
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
        "\(provider.label) entry rolled back; the writable configuration is preserved at \(migration.nativeURL.path). \(failure)"
      )
    }
    return
      "\(provider.label) now uses writable configuration at \(migration.nativeURL.path). Edits affect fresh invocations; history and sync state are untouched."
  }
}
