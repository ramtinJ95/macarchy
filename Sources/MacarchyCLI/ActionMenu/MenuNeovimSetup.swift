import Darwin
import Foundation
import ThemeCore

struct MenuNeovimSetup {
  let context: UnifiedSetupPlanContext
  let homeDirectory: URL
  var resourcesRoot: URL = RuntimeEnvironment.live.builtInEnvironmentURL
  var io: GuidedSetupIO = .live

  /// Each prompt authorizes one visible step. Cancellation retains earlier
  /// approved personal files and reports that fact; it never runs full setup.
  func prepareForEditing() throws -> MenuNeovimEditor.Target? {
    var layered = try MenuNeovimProfileEdit.load(context)
    let resolved = EnvironmentConfigurationSourceResolver(
      homeDirectory: homeDirectory, stateRoot: context.stateRoot
    ).resolve(.neovim, profile: layered.profile)
    switch resolved.status {
    case .blocked, .readOnly, .disabledInProfile:
      throw EnvironmentLifecycleError.blocked(resolved.message)
    default: break
    }
    let store = EnvironmentStateStore(stateRoot: context.stateRoot)
    let ownership = try store.readOwnership()
    let migration = EnvironmentNeovimMigration(
      homeDirectory: homeDirectory, stateRoot: context.stateRoot)
    let active = migration.nativeTarget(in: ownership)
    let options = layered.profile.environment.neovim
    let standard = homeDirectory.appending(path: ".config/nvim")
    if options.nativeConfigurationDirectoryURL == nil, options.configurationDirectoryURL == nil,
      active == nil, ownership?.records.contains(where: { $0.id == .neovim }) == true
    {
      guard try migrateLegacyToStandard() else { return nil }
      layered = try MenuNeovimProfileEdit.load(context)
      return try MenuNeovimEditor.editTarget(
        profile: layered.profile,
        homeDirectory: homeDirectory, stateRoot: context.stateRoot)
    }
    let source =
      options.nativeConfigurationDirectoryURL ?? options.configurationDirectoryURL ?? active
      ?? standard
    if active?.path == source.path, options.nativeConfigurationDirectoryURL != nil {
      return try MenuNeovimEditor.editTarget(
        profile: layered.profile,
        homeDirectory: homeDirectory, stateRoot: context.stateRoot)
    }
    guard ownership?.standardNativeEntries?.contains(.neovim) != true || active?.path == source.path
    else {
      throw EnvironmentLifecycleError.blocked(
        "the declared source differs from the active standard native Neovim tree; resolve that source conflict before editing. No files were changed"
      )
    }
    let profileEdit = try MenuNeovimProfileEdit.prepare(context: context, source: source)
    if active?.path == source.path {
      guard try publishProfile(profileEdit) else { return nil }
      return try MenuNeovimEditor.editTarget(
        profile: MenuNeovimProfileEdit.load(context).profile,
        homeDirectory: homeDirectory, stateRoot: context.stateRoot)
    }
    io.write(
      "Neovim source: \(source.path)\nOnly Neovim setup is reviewed here. Cancelling retains earlier approved steps.\n"
    )
    var metadata = stat()
    if lstat(source.path, &metadata) != 0 {
      guard errno == ENOENT else {
        throw EnvironmentLifecycleError.system("inspect Neovim source", source, errno)
      }
      let seed = EnvironmentNativeSeed(
        provider: .neovim, destination: source,
        homeDirectory: homeDirectory, stateRoot: context.stateRoot, resourcesRoot: resourcesRoot,
        createParentDirectory: true)
      let plan = try seed.plan()
      io.write("Create absent writable LazyVim starter at \(plan.destination):\n\(plan.contents)\n")
      guard try confirm("Create this starter without changing any existing configuration?") else {
        return nil
      }
      try withMutationLock {
        try profileEdit.validateBefore()
        _ = try seed.seed(approval: plan.approval)
      }
    }
    let preparation = EnvironmentNeovimThemePreparation(
      source: source,
      homeDirectory: homeDirectory, stateRoot: context.stateRoot)
    let theme = try preparation.plan()
    if !theme.links.isEmpty {
      io.write("Add only these missing theme links (no Lua or lockfile replacement):\n")
      for path in theme.links {
        io.write(
          "  \(path) -> \(context.stateRoot.appending(path: "environment/current/neovim/\(path)").path)\n"
        )
      }
      io.write(
        "Supported seam: LazyVim/lazy.nvim must load lua/plugins. Other plugin managers need their own proven integration; Macarchy will not infer or execute Lua to identify one.\n"
      )
      guard try confirm("Does this configuration use that seam, and may Macarchy add these links?")
      else { return nil }
      try withMutationLock {
        try profileEdit.validateBefore()
        try preparation.prepare(approval: theme.approval)
      }
    }
    if ownership?.records.contains(where: { $0.id == .neovim }) == true {
      let reconnect = EnvironmentNeovimMigration(
        homeDirectory: homeDirectory,
        stateRoot: context.stateRoot, sourceURL: source)
      let (plan, _) = try reconnect.plan()
      showProfile(profileEdit)
      io.write(plan.message + "\n")
      guard try confirm("Save the reviewed Neovim profile intent and connect \(source.path)?")
      else { return nil }
      try withMutationLock {
        // Revalidate both consents before the first write.
        guard try reconnect.plan().0.approval == plan.approval else {
          throw EnvironmentLifecycleError.blocked("Neovim connection changed; review again")
        }
        try profileEdit.publish()
        io.write(
          try EnvironmentTransactionCoordinator(
            homeDirectory: homeDirectory,
            stateRoot: context.stateRoot
          ).migrateNeovimLocked(approval: plan.approval, sourceURL: source) + "\n")
      }
    } else {
      let connection = EnvironmentNeovimConnection(
        homeDirectory: homeDirectory,
        stateRoot: context.stateRoot, source: source, resourcesRoot: resourcesRoot)
      let plan = try connection.plan()
      showProfile(profileEdit)
      io.write(
        "Connect Neovim and its generated theme only. Other provider files and runtime processes stay unchanged. No plugin restore, package installation or full environment apply.\n"
      )
      guard try confirm("Save the reviewed Neovim intent and make this connection?") else {
        return nil
      }
      try withMutationLock {
        guard try connection.plan().approval == plan.approval else {
          throw EnvironmentLifecycleError.blocked("Neovim connection changed; review again")
        }
        try profileEdit.publish()
        try connection.connectLocked(approval: plan.approval)
      }
    }
    io.write(
      "Ready to edit. Normal Neovim startup can bootstrap its configured plugins; Macarchy adds no save-time apply or restore hook.\n"
    )
    return try MenuNeovimEditor.editTarget(
      profile: MenuNeovimProfileEdit.load(context).profile,
      homeDirectory: homeDirectory, stateRoot: context.stateRoot)
  }

  private func publishProfile(_ edit: MenuNeovimProfileEdit) throws -> Bool {
    guard edit.files.contains(where: \.changed) else { return true }
    showProfile(edit)
    guard
      try confirm(
        "Save this Neovim source declaration? No connection or runtime changes are needed.")
    else { return false }
    try withMutationLock { try edit.publish() }
    return true
  }

  private func showProfile(_ edit: MenuNeovimProfileEdit) {
    // Do not dump unrelated or potentially sensitive profile contents.
    io.write(
      "Effective Neovim source: \(edit.profile.environment.neovim.nativeConfigurationDirectoryURL!.path)\n"
    )
    for file in edit.files where file.changed {
      io.write("Profile: \(file.declared.path)\nPhysical file: \(file.physical.path)\n")
      if file.before == nil { io.write("  Create schema_version = 1 profile.\n") }
      let before = CanonicalTOMLSelector(
        configuration: file.before ?? "", table: "neovim", key: "native_configuration")
      let after = CanonicalTOMLSelector(
        configuration: file.after, table: "neovim", key: "native_configuration")
      if before.values != after.values {
        io.write("  Set neovim.native_configuration = \(after.values.joined())\n")
      }
      if file.before.map({
        !CanonicalTOMLSelector(configuration: $0, table: "neovim", key: "configuration").assignments
          .isEmpty
      }) == true {
        io.write("  Remove the copied neovim.configuration declaration.\n")
      }
    }
  }

  private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
    let lock = EnvironmentLifecycleLock(stateRoot: context.stateRoot)
    let descriptor = try lock.acquire()
    defer { lock.release(descriptor) }
    return try ActivationLock(root: context.stateRoot).withLock(body)
  }

  private func confirm(_ question: String) throws -> Bool {
    let approved = try io.confirm(question)
    if !approved {
      io.write(
        "Cancelled. Earlier approved personal files, if any, are retained; no editor was opened.\n")
    }
    return approved
  }

  private func migrateLegacyToStandard() throws -> Bool {
    let migration = EnvironmentNeovimMigration(
      homeDirectory: homeDirectory, stateRoot: context.stateRoot)
    let (plan, _) = try migration.plan()
    let standard = homeDirectory.appending(path: ".config/nvim")
    let edit = try MenuNeovimProfileEdit.prepare(context: context, source: standard)
    io.write(
      "\(plan.message)\nIntermediate writable tree: \(plan.destination)\nA separately reviewed move to \(standard.path) follows.\n"
    )
    guard try confirm("Preserve this owned legacy configuration as writable files?") else {
      return false
    }
    try withMutationLock {
      try edit.validateBefore()
      io.write(
        try EnvironmentTransactionCoordinator(
          homeDirectory: homeDirectory,
          stateRoot: context.stateRoot
        ).migrateNeovimLocked(approval: plan.approval) + "\n")
    }
    let cutover = EnvironmentStandardMigration(
      provider: .neovim,
      homeDirectory: homeDirectory, stateRoot: context.stateRoot, sourceURL: migration.nativeRoot)
    let (move, _) = try cutover.plan()
    showProfile(edit)
    io.write(move.message + "\n")
    guard
      try confirm(
        "Save the reviewed profile intent and move the writable tree to \(standard.path)?")
    else { return false }
    try withMutationLock {
      guard try cutover.plan().0.approval == move.approval else {
        throw EnvironmentLifecycleError.blocked("Neovim migration changed; review again")
      }
      try edit.publish()
      io.write(
        try EnvironmentTransactionCoordinator(
          homeDirectory: homeDirectory,
          stateRoot: context.stateRoot
        ).migrateStandardLocked(
          provider: .neovim,
          sourceURL: migration.nativeRoot, approval: move.approval) + "\n")
    }
    return true
  }
}
