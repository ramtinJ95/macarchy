import Darwin
import Foundation
import ThemeCore

/// Review source intent separately from the existing provider-scoped migration.
/// Neither opening nor saving an editor grants aggregate environment authority.
struct MenuNativeConfigurationSetup {
  let provider: EnvironmentNativeSeed.Provider
  let context: UnifiedSetupPlanContext
  var io: GuidedSetupIO = .live

  func prepareForEditing() throws -> URL? {
    let layered = try MenuNativeProfileEdit.load(context)
    let resolver = EnvironmentConfigurationSourceResolver(
      homeDirectory: context.homeDirectory, stateRoot: context.stateRoot)
    let resolved = resolver.resolve(provider, profile: layered.profile)
    switch resolved.status {
    case .blocked, .readOnly, .disabledInProfile:
      throw EnvironmentLifecycleError.blocked(resolved.message)
    default: break
    }
    if provider == .zsh || provider == .kitty,
      resolved.authority == "copied_profile_input", resolved.status == .editable,
      let target = resolved.resolvedSource
    {
      return URL(filePath: target)
    }
    let ownership = try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership()
    if provider == .zsh || provider == .kitty {
      let action: MenuConfigurationAction = provider == .zsh ? .zsh : .kitty
      if try MenuConfigurationEditor.usesManagedProfile(action, context: context) {
        return try MenuConfigurationEditor.target(action, context: context, io: io)
      }
    }
    if provider == .atuin || provider == .starship {
      let kind: EnvironmentNativeFileMigration.Provider = provider == .atuin ? .atuin : .starship
      let migration = EnvironmentNativeFileMigration(
        provider: kind,
        homeDirectory: context.homeDirectory, stateRoot: context.stateRoot)
      let active = migration.nativeTarget(in: ownership)
      let declared = provider.source(in: layered.profile.environment)
      if let active, declared == nil || declared?.path == active.path {
        let edit = try MenuNativeProfileEdit.prepare(
          context: context, source: active, provider: provider)
        if edit.files.contains(where: \.changed) {
          show(edit)
          guard try confirm("Save this native source declaration? The connection stays unchanged.")
          else {
            return nil
          }
          try withMutationLock {
            // Do not publish stale intent if ownership or the public link changed while reviewing.
            _ = try resolver.connectedSource(provider, profile: layered.profile)
            try edit.publish()
          }
        }
      } else if ownership?.records.contains(where: { $0.id == provider.entryID }) == true {
        let reconnect = EnvironmentNativeFileMigration(
          provider: kind,
          homeDirectory: context.homeDirectory, stateRoot: context.stateRoot, sourceURL: declared)
        let edit = try MenuNativeProfileEdit.prepare(
          context: context,
          source: reconnect.nativeURL, provider: provider)
        if let declared, try !prepareStarter(at: declared, edit: edit) { return nil }
        let (plan, _) = try reconnect.plan()
        show(edit)
        io.write("\(plan.message)\nDestination: \(plan.destination)\n")
        guard
          try confirm(
            "Save this source intent and perform only the reviewed \(provider.rawValue) migration?")
        else {
          return nil
        }
        try withMutationLock {
          guard try reconnect.plan().0.approval == plan.approval else {
            throw EnvironmentLifecycleError.blocked("Native connection changed; review again")
          }
          try edit.publish()
          io.write(
            try EnvironmentTransactionCoordinator(
              homeDirectory: context.homeDirectory, stateRoot: context.stateRoot
            ).migrateNativeFileLocked(provider: kind, approval: plan.approval, sourceURL: declared)
              + "\n")
        }
      } else if active == nil {
        guard try prepareInitialConnection(layered: layered.profile) else { return nil }
      }
    } else if provider == .zsh || provider == .kitty,
      ownership?.records.contains(where: { $0.id == provider.entryID }) != true,
      ownership?.standardNativeEntries?.contains(provider.entryID) != true
    {
      guard try prepareInitialConnection(layered: layered.profile) else { return nil }
    }
    let current = try MenuNativeProfileEdit.load(context)
    let connected = try resolver.connectedSource(provider, profile: current.profile)
    guard connected.kind == "file", let target = connected.resolvedSource else {
      throw EnvironmentLifecycleError.blocked("The native editing target is not a file")
    }
    return URL(filePath: target)
  }

  private func prepareInitialConnection(
    layered: PortableProfile
  ) throws -> Bool {
    let source =
      provider.source(in: layered.environment)
      ?? provider.standardURL(homeDirectory: context.homeDirectory)
    let edit = try MenuNativeProfileEdit.prepare(
      context: context, source: source, provider: provider)
    guard try prepareStarter(at: source, edit: edit) else { return false }
    // These are personal application directories, not adopted configuration.
    // Retain explicitly approved empty directories on cancellation, like starters.
    if provider == .atuin {
      for path in [".config/atuin", ".config/atuin/themes"] {
        let directory = context.homeDirectory.appending(path: path)
        var metadata = stat()
        if lstat(directory.path, &metadata) == 0 {
          let descriptor = try PinnedFilesystem.openDirectory(at: directory)
          Darwin.close(descriptor)
          continue
        }
        guard errno == ENOENT else {
          throw EnvironmentLifecycleError.system("inspect Atuin directory", directory, errno)
        }
        io.write("Atuin's theme connection needs personal directory: \(directory.path)\n")
        guard try confirm("Create this absent directory? It remains if connection is cancelled.")
        else { return false }
        try withMutationLock {
          try edit.validateBefore()
          let parent = try PinnedFilesystem.openDirectory(at: directory.deletingLastPathComponent())
          defer { Darwin.close(parent) }
          guard directory.lastPathComponent.withCString({ mkdirat(parent, $0, 0o755) }) == 0 else {
            throw EnvironmentLifecycleError.system("create Atuin directory", directory, errno)
          }
        }
      }
    }
    if provider == .kitty {
      io.write(
        "Prepare the canonical Kitty theme bridge without signaling Kitty. The cache remains on cancellation.\n"
      )
      guard try confirm("Prepare Kitty's theme bridge for this connection?") else { return false }
      try withMutationLock {
        try edit.validateBefore()
        try KittyAdapter.prepareBridge(root: context.stateRoot)
      }
    }
    let connection = EnvironmentNativeFileConnection(
      provider: provider, homeDirectory: context.homeDirectory, stateRoot: context.stateRoot,
      source: source, resourcesRoot: context.environmentResourcesRoot)
    let plan = try connection.plan(profile: edit.profile)
    show(edit)
    io.write("Connect only \(provider.rawValue) at \(connection.publicURL.path).\n")
    if provider == .atuin { io.write("Create theme link: \(connection.themeURL.path)\n") }
    guard try confirm("Save this source intent and connect this provider only?") else {
      return false
    }
    try withMutationLock {
      guard try connection.plan(profile: edit.profile).approval == plan.approval else {
        throw EnvironmentLifecycleError.blocked("Native connection changed; review again")
      }
      try edit.publish()
      try connection.connectLocked(profile: edit.profile, approval: plan.approval)
    }
    return true
  }

  private func prepareStarter(at source: URL, edit: MenuNativeProfileEdit) throws -> Bool {
    if FileManager.default.fileExists(atPath: source.path) { return true }
    let seed = EnvironmentNativeSeed(
      provider: provider, destination: source,
      homeDirectory: context.homeDirectory, stateRoot: context.stateRoot,
      resourcesRoot: context.environmentResourcesRoot, createParentDirectory: true)
    let starter = try seed.plan()
    io.write("Create absent native starter at \(starter.destination):\n\(starter.contents)\n")
    guard try confirm("Create this personal starter? Connection is reviewed separately.") else {
      return false
    }
    try withMutationLock {
      try edit.validateBefore()
      _ = try seed.seed(approval: starter.approval)
    }
    return true
  }

  private func show(_ edit: MenuNativeProfileEdit) {
    io.write(
      "Native \(provider.rawValue) source: \(provider.source(in: edit.profile.environment)!.path)\n"
    )
    for file in edit.files where file.changed {
      io.write("Profile: \(file.declared.path)\nPhysical file: \(file.physical.path)\n")
      io.write("  Set \(provider.rawValue).\(provider.profileKey).\n")
      for key in provider.copiedProfileKeys {
        if !CanonicalTOMLSelector(
          configuration: file.before ?? "", table: provider.rawValue,
          key: key
        ).assignments.isEmpty {
          io.write(
            "  Remove copied \(provider.rawValue).\(key); native behavior becomes authoritative.\n")
        }
      }
    }
    io.write(
      "Saved intent and any created personal files remain if a later step fails. No full apply, installation or restart.\n"
    )
  }

  private func confirm(_ question: String) throws -> Bool {
    let approved = try io.confirm(question)
    if !approved {
      io.write("Cancelled. No editor opened. Earlier approved personal files remain.\n")
    }
    return approved
  }

  private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
    let lock = EnvironmentLifecycleLock(stateRoot: context.stateRoot)
    let descriptor = try lock.acquire()
    defer { lock.release(descriptor) }
    return try ActivationLock(root: context.stateRoot).withLock(body)
  }
}
