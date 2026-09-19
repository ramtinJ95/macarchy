import Darwin
import Foundation
import ThemeCore

/// Initial connection only. Existing ownership uses the established migrations;
/// this operation neither adopts an incumbent entry nor applies another provider.
struct EnvironmentNeovimConnection {
  let homeDirectory: URL
  let stateRoot: URL
  let source: URL
  var resourcesRoot: URL = RuntimeEnvironment.live.builtInEnvironmentURL

  struct Plan {
    let approval: String
    let previous: EnvironmentOwnership?
    let composition: EnvironmentComposition
    let standard: Bool
  }

  var publicURL: URL { homeDirectory.appending(path: ".config/nvim") }

  func plan() throws -> Plan {
    do {
      let theme = try ReconciliationStatusStore(root: stateRoot).activeManifest()
      _ = try BoundedRegularFile.read(
        at: stateRoot.appending(
          path: "generations/\(theme.generationID)/generated/neovim.lua"))
    } catch {
      throw EnvironmentLifecycleError.blocked(
        "Neovim connection requires a valid active theme; select or repair the theme first. \(error)"
      )
    }
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard !store.transactionExists else {
      throw EnvironmentLifecycleError.blocked("recover the pending environment transaction first")
    }
    let previous = try store.readOwnership()
    guard previous?.records.contains(where: { $0.id == .neovim }) != true,
      previous?.standardNativeEntries?.contains(.neovim) != true
    else {
      throw EnvironmentLifecycleError.blocked(
        "Neovim is already owned; use its reviewed migration instead")
    }
    guard previous == nil || previous?.enabledThemeAdapterIDs != nil else {
      throw EnvironmentLifecycleError.blocked(
        "legacy environment adapter inventory requires reviewed migration first")
    }
    let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
    guard try generations.currentDestination() == previous.map({ "generations/\($0.generationID)" })
    else {
      throw EnvironmentLifecycleError.drift("environment pointer and ownership disagree")
    }
    let preparation = EnvironmentNeovimThemePreparation(
      source: source, homeDirectory: homeDirectory, stateRoot: stateRoot)
    let prepared = try preparation.plan()
    guard prepared.links.isEmpty else {
      throw EnvironmentLifecycleError.blocked(
        "review and prepare the four Neovim theme links before connecting")
    }
    let standard = source.path == publicURL.path
    if !standard {
      var metadata = stat()
      guard lstat(publicURL.path, &metadata) != 0, errno == ENOENT else {
        throw EnvironmentLifecycleError.blocked(
          "Neovim public entry already exists; it will not be adopted or replaced")
      }
      let parent = try PinnedFilesystem.openDirectory(at: publicURL.deletingLastPathComponent())
      Darwin.close(parent)
    }
    let manifest = try generations.currentManifest()
    let artifacts = try (manifest?.artifacts.keys.sorted() ?? []).map { path in
      EnvironmentConfigurationArtifact(
        path: path,
        data: try generations.validatedArtifact(generationID: manifest!.generationID, path: path))
    }
    let composition = try EnvironmentConfigurationComposer().composeNeovimConnection(
      resourcesRoot: resourcesRoot, source: source, stateRoot: stateRoot,
      retaining: artifacts, previousInputDigest: manifest?.inputDigest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let approval = sha256Digest(
      try encoder.encode(previous)
        + encoder.encode([
          prepared.approval, composition.inputDigest, publicURL.path,
          standard ? "standard" : "absent",
        ]))
    return Plan(
      approval: approval, previous: previous, composition: composition, standard: standard)
  }

  /// Caller holds EnvironmentLifecycleLock then ActivationLock. Approval is checked before
  /// staging; the journal's recovery path has the same Neovim-only boundary.
  func connectLocked(
    approval: String,
    faultInjector: @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
  ) throws {
    let plan = try plan()
    guard plan.approval == approval else {
      throw EnvironmentLifecycleError.blocked("Neovim connection changed; review it again")
    }
    let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
    let staged = try generations.stage(plan.composition)
    let proposed = Self.proposedOwnership(
      previous: plan.previous, generationID: staged.manifest.generationID,
      publicURL: publicURL, source: source, standard: plan.standard)
    let transaction = EnvironmentTransaction(
      operation: .neovimConnection, previousOwnership: plan.previous, proposedOwnership: proposed,
      previousCurrentDestination: plan.previous.map { "generations/\($0.generationID)" })
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    try store.writeTransaction(transaction)
    do {
      try transition(transaction)
      try faultInjector(.authorityPublished)
      try store.removeTransaction()
    } catch {
      let failure = error
      let rollback = transaction.rollingBack
      try store.writeTransaction(rollback)
      try transition(rollback)
      try store.removeTransaction()
      throw EnvironmentLifecycleError.blocked(
        "Neovim connection rolled back; user configuration remains at \(source.path). \(failure)")
    }
  }

  static func proposedOwnership(
    previous: EnvironmentOwnership?, generationID: String,
    publicURL: URL, source: URL, standard: Bool
  ) -> EnvironmentOwnership {
    var records = previous?.records ?? []
    var native = previous?.standardNativeEntries ?? []
    if standard {
      native.append(.neovim)
    } else {
      records.append(
        EnvironmentOwnershipRecord(
          id: .neovim, publicPath: publicURL.path, managedKind: "symbolic_link",
          managedTarget: source.path,
          original: EnvironmentEntryEvidence(
            kind: .absent, device: nil, inode: nil, mode: nil,
            size: nil, linkDestination: nil, contentDigest: nil, metadataDigest: nil, inventory: []),
          retainedPath: nil))
    }
    return EnvironmentOwnership(
      generationID: generationID, records: records,
      createdDirectories: previous?.createdDirectories ?? [],
      originalThemeBridges: previous?.originalThemeBridges ?? [],
      btop: previous?.btop, borders: previous?.borders, codex: previous?.codex,
      herdr: previous?.herdr, pi: previous?.pi, spicetify: previous?.spicetify,
      tuicr: previous?.tuicr,
      codexEnabled: previous?.codexEnabled ?? false, herdrEnabled: previous?.herdrEnabled ?? false,
      piEnabled: previous?.piEnabled ?? false, slackEnabled: previous?.slackEnabled ?? false,
      spicetifyEnabled: previous?.spicetifyEnabled ?? false,
      tuicrEnabled: previous?.tuicrEnabled ?? false,
      enabledThemeAdapterIDs: Array(Set((previous?.enabledThemeAdapterIDs ?? []) + ["neovim"])),
      standardNativeEntries: native)
  }

  static func ownershipChangeIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    guard let proposed = transaction.proposedOwnership,
      transaction.previousOwnership?.records.contains(where: { $0.id == .neovim }) != true,
      transaction.previousOwnership?.standardNativeEntries?.contains(.neovim) != true,
      transaction.previousOwnership == nil
        || transaction.previousOwnership?.enabledThemeAdapterIDs != nil,
      proposed.generationID != transaction.previousOwnership?.generationID
    else { return false }
    let record = proposed.records.first { $0.id == .neovim }
    let standard = proposed.standardNativeEntries?.contains(.neovim) == true
    guard standard != (record != nil) else { return false }
    // Standard paths are derived from the host at recovery, never stored as an
    // arbitrary writable path in a journal.
    let placeholder = URL(filePath: "/standard-neovim")
    return proposed
      == proposedOwnership(
        previous: transaction.previousOwnership, generationID: proposed.generationID,
        publicURL: record.map { URL(filePath: $0.publicPath) } ?? placeholder,
        source: record.map { URL(filePath: $0.managedTarget) } ?? placeholder,
        standard: standard)
  }

  func transition(_ transaction: EnvironmentTransaction) throws {
    guard Self.ownershipChangeIsValid(transaction), let proposed = transaction.proposedOwnership
    else {
      throw EnvironmentLifecycleError.blocked("Neovim connection changes unrelated ownership")
    }
    let record = proposed.records.first { $0.id == .neovim }
    guard
      record == nil
        || (record?.publicPath == publicURL.path && record?.managedTarget == source.path),
      EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .targetIsAllowed(source.path, userOwnedPublicEntry: true)
    else {
      throw EnvironmentLifecycleError.blocked(
        "Neovim connection contains an unexpected source or public path")
    }
    let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
    let before = transaction.previousOwnership
    let oldManifest = try before.map { try generations.manifest(generationID: $0.generationID) }
    let newManifest = try generations.manifest(generationID: proposed.generationID)
    guard
      (oldManifest?.artifacts ?? [:]).filter({ !$0.key.hasPrefix("neovim/") })
        == newManifest.artifacts.filter({ !$0.key.hasPrefix("neovim/") })
    else {
      throw EnvironmentLifecycleError.blocked("Neovim connection changed another provider artifact")
    }
    let identity = try generations.validatedArtifact(
      generationID: proposed.generationID, path: "neovim/native-source.txt")
    guard try JSONDecoder().decode(String.self, from: identity) == source.path,
      Set(newManifest.artifacts.keys.filter { $0.hasPrefix("neovim/") })
        == Set(
          EnvironmentNeovimMigration.themePaths.map { "neovim/" + $0 } + [
            "neovim/native-source.txt"
          ])
    else {
      throw EnvironmentLifecycleError.blocked(
        "Neovim connection has an invalid generated theme inventory")
    }
    let current = try generations.currentDestination()
    guard
      current == transaction.previousCurrentDestination
        || current == "generations/\(proposed.generationID)"
    else {
      throw EnvironmentLifecycleError.drift("environment pointer changed during Neovim connection")
    }
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    let currentOwnership = try store.readOwnership()
    guard currentOwnership == before || currentOwnership == proposed else {
      throw EnvironmentLifecycleError.drift(
        "environment ownership changed during Neovim connection")
    }
    let forward = transaction.direction == .forward
    if forward {
      try EnvironmentNeovimMigration(
        homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: source
      )
      .validateNativeTree(userOwnedPublicEntry: true)
    }
    if record != nil { try transitionPublicLink(connect: forward) }
    if forward {
      try generations.select(proposed.generationID)
    } else {
      try generations.restoreCurrent(transaction.previousCurrentDestination)
    }
    try store.writeOwnership(forward ? proposed : before)
  }

  private func transitionPublicLink(connect: Bool) throws {
    let parent = try PinnedFilesystem.openDirectory(at: publicURL.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    var metadata = stat()
    let rc = publicURL.lastPathComponent.withCString {
      fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    if rc == 0 {
      guard metadata.st_mode & S_IFMT == S_IFLNK,
        try PinnedFilesystem.symlinkDestination(
          parentDescriptor: parent, name: publicURL.lastPathComponent, url: publicURL)
          == source.path
      else { throw EnvironmentLifecycleError.drift(publicURL.path) }
      if !connect {
        guard publicURL.lastPathComponent.withCString({ unlinkat(parent, $0, 0) }) == 0 else {
          throw EnvironmentLifecycleError.system("remove Neovim connection", publicURL, errno)
        }
      }
    } else {
      guard errno == ENOENT else {
        throw EnvironmentLifecycleError.system("inspect Neovim connection", publicURL, errno)
      }
      if connect {
        let created = source.path.withCString { target in
          publicURL.lastPathComponent.withCString { symlinkat(target, parent, $0) }
        }
        guard created == 0 else {
          throw EnvironmentLifecycleError.system("connect Neovim", publicURL, errno)
        }
      }
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync Neovim connection", publicURL, errno)
    }
  }
}

extension EnvironmentTransactionCoordinator {
  func finishNeovimConnectionLocked(_ transaction: EnvironmentTransaction) throws {
    let source =
      transaction.proposedOwnership?.records.first { $0.id == .neovim }?.managedTarget
      ?? homeDirectory.appending(path: ".config/nvim").path
    try EnvironmentNeovimConnection(
      homeDirectory: homeDirectory, stateRoot: stateRoot,
      source: URL(filePath: source)
    ).transition(transaction)
    try EnvironmentStateStore(stateRoot: stateRoot).removeTransaction()
  }
}
