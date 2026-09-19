import Darwin
import Foundation
import ThemeCore

/// Initial native connections use the existing journal, never aggregate
/// apply. Existing owned entries continue to use native-file migration.
struct EnvironmentNativeFileConnection {
  let provider: EnvironmentNativeSeed.Provider
  let homeDirectory: URL
  let stateRoot: URL
  let source: URL
  var resourcesRoot: URL = RuntimeEnvironment.live.builtInEnvironmentURL

  var publicURL: URL {
    provider == .kitty
      ? homeDirectory.appending(path: ".config/kitty")
      : provider.standardURL(homeDirectory: homeDirectory)
  }
  private var operation: EnvironmentTransactionOperation {
    switch provider {
    case .zsh: .zshConnection
    case .kitty: .kittyConnection
    case .atuin: .atuinConnection
    case .starship: .starshipConnection
    case .neovim: preconditionFailure("Neovim uses its tree connection")
    }
  }
  private var selectedArtifacts: Set<String> {
    let names: [String]
    switch provider {
    case .zsh: names = ["defaults.zsh", ".zshrc"]
    case .kitty: names = ["defaults.conf", "kitty.conf"]
    case .atuin: names = ["config.toml"]
    case .starship: names = ["behavior.toml"]
    case .neovim: names = []
    }
    return Set((names + ["native-source.txt"]).map { provider.rawValue + "/" + $0 })
  }
  var themeURL: URL { homeDirectory.appending(path: ".config/atuin/themes/macarchy-current.toml") }

  struct Plan {
    let approval: String
    let previous: EnvironmentOwnership?
    let composition: EnvironmentComposition
    let standard: Bool
  }

  func plan(profile: PortableProfile) throws -> Plan {
    guard provider != .neovim,
      provider.source(in: profile.environment)?.path == source.path,
      provider.isEnabled(in: profile.environment)
    else {
      throw EnvironmentLifecycleError.blocked("Native source intent does not match connection")
    }
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard !store.transactionExists else {
      throw EnvironmentLifecycleError.blocked("Recover the pending environment transaction first")
    }
    let previous = try store.readOwnership()
    guard previous?.records.contains(where: { affectedIDs.contains($0.id) }) != true,
      previous?.standardNativeEntries?.contains(provider.entryID) != true,
      previous == nil || previous?.enabledThemeAdapterIDs != nil
    else {
      throw EnvironmentLifecycleError.blocked("Existing ownership requires reviewed migration")
    }
    let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
    guard try generations.currentDestination() == previous.map({ "generations/\($0.generationID)" })
    else { throw EnvironmentLifecycleError.drift("Environment pointer and ownership disagree") }
    let theme = try ReconciliationStatusStore(root: stateRoot).activeManifest()
    let themeEncoder = JSONEncoder()
    themeEncoder.outputFormatting = [.sortedKeys]
    let themeData = try themeEncoder.encode(theme)
    if provider == .kitty { try KittyAdapter.validatePreparedBridge(root: stateRoot) }
    try validateSource()
    let standard = source.path == provider.standardURL(homeDirectory: homeDirectory).path
    for record in newRecords(standard: standard) {
      let url = URL(filePath: record.publicPath)
      let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
      Darwin.close(parent)
      var metadata = stat()
      guard lstat(url.path, &metadata) != 0, errno == ENOENT else {
        throw EnvironmentLifecycleError.blocked(
          "Will not adopt or replace existing entry: \(url.path)")
      }
    }
    let manifest = try generations.currentManifest()
    let artifacts = try (manifest?.artifacts.keys.sorted() ?? []).map { path in
      EnvironmentConfigurationArtifact(
        path: path,
        data: try generations.validatedArtifact(generationID: manifest!.generationID, path: path))
    }
    let composition = try EnvironmentConfigurationComposer().composeNativeConnection(
      provider: provider.rawValue, resourcesRoot: resourcesRoot, profile: profile,
      source: source, stateRoot: stateRoot, retaining: artifacts,
      previousInputDigest: manifest?.inputDigest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let approval = sha256Digest(
      try encoder.encode(previous)
        + encoder.encode([
          composition.inputDigest, source.path, source.resolvingSymlinksInPath().path,
          sha256Digest(try BoundedRegularFile.read(at: source.resolvingSymlinksInPath()).data),
          theme.generationID, sha256Digest(themeData), standard ? "standard" : "absent",
        ]))
    return Plan(
      approval: approval, previous: previous, composition: composition, standard: standard)
  }

  /// Caller holds environment then activation lock; no prompts while locked.
  func connectLocked(
    profile: PortableProfile, approval: String,
    faultInjector: @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
  ) throws {
    let reviewed = try plan(profile: profile)
    guard reviewed.approval == approval else {
      throw EnvironmentLifecycleError.blocked("Native connection changed; review again")
    }
    let staged = try EnvironmentGenerationStore(stateRoot: stateRoot).stage(reviewed.composition)
    let proposed = ownership(
      previous: reviewed.previous, generationID: staged.manifest.generationID,
      standard: reviewed.standard)
    let transaction = EnvironmentTransaction(
      operation: operation,
      previousOwnership: reviewed.previous, proposedOwnership: proposed,
      previousCurrentDestination: reviewed.previous.map { "generations/\($0.generationID)" })
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    try store.writeTransaction(transaction)
    do {
      try transition(transaction)
      try faultInjector(.authorityPublished)
      try store.removeTransaction()
    } catch {
      let failure = error
      try store.writeTransaction(transaction.rollingBack)
      try transition(transaction.rollingBack)
      try store.removeTransaction()
      throw EnvironmentLifecycleError.blocked(
        "Native connection rolled back; personal configuration remains at \(source.path). \(failure)"
      )
    }
  }

  private var affectedIDs: Set<EnvironmentEntryID> {
    provider == .atuin ? [.atuinConfiguration, .atuinTheme] : [provider.entryID]
  }

  private func newRecords(standard: Bool) -> [EnvironmentOwnershipRecord] {
    var links: [(EnvironmentEntryID, URL, String)] = []
    if !standard {
      let target: String
      switch provider {
      case .zsh: target = stateRoot.appending(path: "environment/current/zsh/.zshrc").path
      case .kitty: target = stateRoot.appending(path: "environment/current/kitty/kitty.conf").path
      default: target = source.path
      }
      links.append((provider.entryID, publicURL, target))
    }
    if provider == .atuin {
      links.append(
        (.atuinTheme, themeURL, stateRoot.appending(path: "current/generated/atuin.toml").path))
    }
    return links.map { id, url, target in
      EnvironmentOwnershipRecord(
        id: id, publicPath: url.path,
        managedKind: id == .kitty
          ? EnvironmentManagedEntry.ManagedKind.kittyDirectory.rawValue : "symbolic_link",
        managedTarget: target,
        original: EnvironmentEntryEvidence(
          kind: .absent, device: nil, inode: nil, mode: nil, size: nil,
          linkDestination: nil, contentDigest: nil, metadataDigest: nil, inventory: []),
        retainedPath: nil)
    }
  }

  private func ownership(
    previous: EnvironmentOwnership?, generationID: String, standard: Bool
  ) -> EnvironmentOwnership {
    EnvironmentOwnership(
      generationID: generationID,
      records: (previous?.records ?? []) + newRecords(standard: standard),
      createdDirectories: previous?.createdDirectories ?? [],
      originalThemeBridges: previous?.originalThemeBridges ?? [],
      btop: previous?.btop, borders: previous?.borders, codex: previous?.codex,
      herdr: previous?.herdr, pi: previous?.pi, spicetify: previous?.spicetify,
      tuicr: previous?.tuicr,
      codexEnabled: previous?.codexEnabled ?? false, herdrEnabled: previous?.herdrEnabled ?? false,
      piEnabled: previous?.piEnabled ?? false, slackEnabled: previous?.slackEnabled ?? false,
      spicetifyEnabled: previous?.spicetifyEnabled ?? false,
      tuicrEnabled: previous?.tuicrEnabled ?? false,
      enabledThemeAdapterIDs: Array(
        Set(
          (previous?.enabledThemeAdapterIDs ?? []) + (provider == .zsh ? [] : [provider.rawValue]))),
      standardNativeEntries: (previous?.standardNativeEntries ?? [])
        + (standard ? [provider.entryID] : []))
  }

  static func ownershipChangeIsValid(_ transaction: EnvironmentTransaction, stateRoot: URL) -> Bool
  {
    guard let provider = transaction.operation.nativeConnectionProvider,
      let proposed = transaction.proposedOwnership,
      proposed.generationID != transaction.previousOwnership?.generationID,
      transaction.previousOwnership == nil
        || transaction.previousOwnership?.enabledThemeAdapterIDs != nil
    else { return false }
    let ids: Set<EnvironmentEntryID> =
      provider == .atuin ? [.atuinConfiguration, .atuinTheme] : [provider.entryID]
    guard transaction.previousOwnership?.records.contains(where: { ids.contains($0.id) }) != true,
      transaction.previousOwnership?.standardNativeEntries?.contains(provider.entryID) != true
    else { return false }
    let record = proposed.records.first { $0.id == provider.entryID }
    let standard = proposed.standardNativeEntries?.contains(provider.entryID) == true
    guard standard != (record != nil) else { return false }
    // Derive the host from canonical state placement only at the caller. This
    // shape check uses the journal's public path; transition checks actual host paths.
    let publicPath =
      record?.publicPath
      ?? proposed.records.first(where: { $0.id == .atuinTheme })?.publicPath
      ?? "/placeholder/.config/starship.toml"
    var home = URL(filePath: publicPath).deletingLastPathComponent()
    if provider == .atuin {
      if record == nil { home.deleteLastPathComponent() }
      home.deleteLastPathComponent()
    }
    if provider != .zsh { home.deleteLastPathComponent() }
    let connection = Self(
      provider: provider, homeDirectory: home, stateRoot: stateRoot,
      source: record.map { URL(filePath: $0.managedTarget) }
        ?? provider.standardURL(homeDirectory: home))
    return proposed
      == connection.ownership(
        previous: transaction.previousOwnership, generationID: proposed.generationID,
        standard: standard)
  }

  func transition(_ transaction: EnvironmentTransaction) throws {
    guard Self.ownershipChangeIsValid(transaction, stateRoot: stateRoot),
      transaction.operation.nativeConnectionProvider == provider,
      let proposed = transaction.proposedOwnership
    else {
      throw EnvironmentLifecycleError.blocked("Native connection changes unrelated ownership")
    }
    let standard = proposed.standardNativeEntries?.contains(provider.entryID) == true
    guard
      proposed
        == ownership(
          previous: transaction.previousOwnership, generationID: proposed.generationID,
          standard: standard)
    else {
      throw EnvironmentLifecycleError.blocked("Native connection contains unexpected public paths")
    }
    let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
    let old = try transaction.previousOwnership.map {
      try generations.manifest(generationID: $0.generationID)
    }
    let new = try generations.manifest(generationID: proposed.generationID)
    let prefix = provider.rawValue + "/"
    guard
      (old?.artifacts ?? [:]).filter({ !$0.key.hasPrefix(prefix) })
        == new.artifacts.filter({ !$0.key.hasPrefix(prefix) }),
      Set(new.artifacts.keys.filter { $0.hasPrefix(prefix) }) == selectedArtifacts,
      try JSONDecoder().decode(
        String.self,
        from: generations.validatedArtifact(
          generationID: proposed.generationID, path: prefix + "native-source.txt")) == source.path
    else {
      throw EnvironmentLifecycleError.blocked(
        "Native connection changed unrelated artifacts or source")
    }
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    let current = try generations.currentDestination()
    let owned = try store.readOwnership()
    guard
      current == transaction.previousCurrentDestination
        || current == "generations/\(proposed.generationID)",
      owned == transaction.previousOwnership || owned == proposed
    else {
      throw EnvironmentLifecycleError.drift(
        "Environment authority changed during native connection")
    }
    let forward = transaction.direction == .forward
    if forward {
      try validateSource()
      if provider == .kitty { try KittyAdapter.validatePreparedBridge(root: stateRoot) }
    }
    for record in newRecords(standard: standard) {
      if record.id == .kitty {
        try transitionKittyDirectory(record, connect: forward)
      } else {
        try transitionLink(record, connect: forward)
      }
    }
    if forward {
      try generations.select(proposed.generationID)
    } else {
      try generations.restoreCurrent(transaction.previousCurrentDestination)
    }
    try store.writeOwnership(forward ? proposed : transaction.previousOwnership)
  }

  private func validateSource() throws {
    // Only standard Kitty files own the theme include; external inputs use a wrapper.
    try EnvironmentStandardNativeConfiguration.validate(
      provider, homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: source,
      ownsKittyThemeInclude: source.path == provider.standardURL(homeDirectory: homeDirectory).path)
  }

  private func transitionKittyDirectory(
    _ record: EnvironmentOwnershipRecord, connect: Bool
  ) throws {
    let url = URL(filePath: record.publicPath)
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    var metadata = stat()
    if url.lastPathComponent.withCString({ fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW) })
      != 0
    {
      guard errno == ENOENT else { throw EnvironmentLifecycleError.drift(url.path) }
      if !connect { return }
      guard url.lastPathComponent.withCString({ mkdirat(parent, $0, 0o755) }) == 0 else {
        throw EnvironmentLifecycleError.system("create Kitty directory", url, errno)
      }
    }
    let directory = try PinnedFilesystem.openDirectory(at: url)
    defer { Darwin.close(directory) }
    let children = try PinnedFilesystem.directoryEntries(descriptor: directory, url: url, limit: 2)
    guard !children.truncated,
      children.entries.isEmpty || children.entries == ["kitty.conf"]
    else { throw EnvironmentLifecycleError.drift("Kitty directory contains personal additions") }
    let link = EnvironmentOwnershipRecord(
      id: record.id, publicPath: url.appending(path: "kitty.conf").path,
      managedKind: "symbolic_link", managedTarget: record.managedTarget,
      original: record.original, retainedPath: nil)
    try transitionLink(link, connect: connect)
    if !connect {
      guard url.lastPathComponent.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
        throw EnvironmentLifecycleError.system("remove Kitty directory", url, errno)
      }
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync Kitty parent", url, errno)
    }
  }

  private func transitionLink(_ record: EnvironmentOwnershipRecord, connect: Bool) throws {
    let url = URL(filePath: record.publicPath)
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    var metadata = stat()
    let rc = url.lastPathComponent.withCString {
      fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    if rc == 0 {
      guard metadata.st_mode & S_IFMT == S_IFLNK,
        try PinnedFilesystem.symlinkDestination(
          parentDescriptor: parent, name: url.lastPathComponent, url: url)
          == record.managedTarget
      else { throw EnvironmentLifecycleError.drift(url.path) }
      if !connect, url.lastPathComponent.withCString({ unlinkat(parent, $0, 0) }) != 0 {
        throw EnvironmentLifecycleError.system("remove native connection", url, errno)
      }
    } else {
      guard errno == ENOENT else {
        throw EnvironmentLifecycleError.system("inspect native connection", url, errno)
      }
      if connect {
        let rc = record.managedTarget.withCString { target in
          url.lastPathComponent.withCString { symlinkat(target, parent, $0) }
        }
        guard rc == 0 else {
          throw EnvironmentLifecycleError.system("connect native source", url, errno)
        }
      }
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync native connection", url, errno)
    }
  }
}

extension EnvironmentTransactionCoordinator {
  func finishNativeFileConnectionLocked(_ transaction: EnvironmentTransaction) throws {
    guard let provider = transaction.operation.nativeConnectionProvider else {
      throw EnvironmentLifecycleError.blocked("Not a native-file connection")
    }
    guard let proposed = transaction.proposedOwnership else {
      throw EnvironmentLifecycleError.blocked("Native connection has no proposed ownership")
    }
    let source = try JSONDecoder().decode(
      String.self,
      from: EnvironmentGenerationStore(stateRoot: stateRoot).validatedArtifact(
        generationID: proposed.generationID, path: provider.rawValue + "/native-source.txt"))
    try EnvironmentNativeFileConnection(
      provider: provider, homeDirectory: homeDirectory, stateRoot: stateRoot,
      source: URL(filePath: source)
    ).transition(transaction)
    try EnvironmentStateStore(stateRoot: stateRoot).removeTransaction()
  }
}
