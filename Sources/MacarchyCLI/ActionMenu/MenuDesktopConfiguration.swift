import Foundation
import ThemeCore

/// One personal input and one provider lifecycle. No per-write execution.
struct MenuDesktopConfiguration {
  let provider: DesktopPersonalProvider
  let context: UnifiedSetupPlanContext
  var io: GuidedSetupIO = .live

  func prepareForEditing() throws -> MenuDesktopEditSession? {
    let layered = try MenuNativeProfileEdit.load(context)
    let generation = try provider.managedGeneration(profile: layered.profile, context: context)
    let origin = layered.fieldOrigins[provider.rawValue + ".hook"] ?? .portable
    let parent = (origin == .machine ? context.machineProfileURL : context.profileURL)
      .resolvingSymlinksInPath().deletingLastPathComponent()
    let declared = provider.source(in: layered.profile)
    let source = declared ?? parent.appending(path: "overrides/\(provider.rawValue).sh")
    let edit = try MenuNativeProfileEdit.desktop(
      context: context, source: source, provider: provider)
    let existing = try MenuProfileSource.prepare(
      source, stateRoot: context.stateRoot, confirmCreation: { _ in false })
    if declared != nil, existing != nil {
      // Parsing happens after editing, so a broken personal script remains repairable.
      guard !edit.files.contains(where: \.changed) else {
        throw EnvironmentLifecycleError.blocked(
          "both legacy hook and personal configuration are declared; resolve that conflict in the profile"
        )
      }
      return try MenuDesktopEditSession.begin(
        provider: provider, context: context, source: source, newConnection: false)
    }
    guard
      try provider.inputsMatchGeneration(
        profile: layered.profile, context: context,
        excludingPersonalConfiguration: declared != nil)
    else {
      throw EnvironmentLifecycleError.blocked(
        "review and apply the existing provider input drift before connecting a personal configuration"
      )
    }
    let legacySource = provider.legacyHook(in: layered.profile)
    let legacyPhysical = legacySource?.resolvingSymlinksInPath()
    let legacy = try legacyPhysical.map {
      try BoundedRegularFile.readUTF8(at: $0, maximumSize: 1_048_576)
    }
    func legacyUnchanged() throws -> Bool {
      try legacySource?.resolvingSymlinksInPath() == legacyPhysical
        && legacyPhysical.map {
          try BoundedRegularFile.readUTF8(at: $0, maximumSize: 1_048_576)
        } == legacy
    }
    let starter =
      Self.starter(provider) + (legacy.map { "\n# Preserved former hook:\n" + $0 } ?? "")
    if existing == nil {
      io.write(
        "Create personal \(provider.rawValue) configuration at \(source.path):\n\(starter)\n")
      guard try io.confirm("Create this absent file? It remains if connection is cancelled.") else {
        return nil
      }
      try ActivationLock(root: context.stateRoot).withLock {
        try edit.validateBefore()
        guard
          try provider.managedGeneration(profile: layered.profile, context: context) == generation,
          try legacyUnchanged(),
          try MenuProfileSource.prepare(
            source, stateRoot: context.stateRoot, confirmCreation: { _ in false }) == nil
        else { throw EnvironmentLifecycleError.blocked("setup inputs changed; review again") }
        _ = try MenuProfileSource.prepare(
          source, stateRoot: context.stateRoot,
          initialContents: starter, confirmCreation: { _ in true })
      }
    }
    let physical = source.resolvingSymlinksInPath()
    let reviewed = try BoundedRegularFile.readUTF8(at: physical, maximumSize: 1_048_576)
    io.write("Personal \(provider.rawValue) input:\n\(reviewed)\n")
    for file in edit.files where file.changed {
      io.write(
        "Set \(provider.rawValue).configuration in \(file.physical.path); remove any legacy hook declaration, preserve other settings.\n"
      )
    }
    io.write(Self.notice(provider) + "\n")
    guard
      try io.confirm(
        "Save this connection and activate only this provider when the editor exits successfully? Saved files and intent remain on failure."
      )
    else { return nil }
    return try ActivationLock(root: context.stateRoot).withLock {
      try edit.validateBefore()
      guard source.resolvingSymlinksInPath() == physical,
        try BoundedRegularFile.readUTF8(at: physical, maximumSize: 1_048_576) == reviewed,
        try legacyUnchanged(),
        try provider.inputsMatchGeneration(
          profile: layered.profile, context: context,
          excludingPersonalConfiguration: declared != nil),
        try provider.managedGeneration(profile: layered.profile, context: context) == generation
      else {
        throw EnvironmentLifecycleError.blocked("reviewed connection changed; review again")
      }
      try edit.publish()
      return try MenuDesktopEditSession.begin(
        provider: provider, context: context, source: source, newConnection: true)
    }
  }

  static func notice(_ provider: DesktopPersonalProvider) -> String {
    let activation = provider == .yabai ? "restart yabai only" : "reload SketchyBar only"
    return
      "Saving does not activate. On successful editor exit, changed input is syntax-checked, then will \(activation). "
      + "Personal shell code is trusted; runtime failure cannot undo arbitrary side effects. "
      + (provider == .sketchybar
        ? "Theme changes also re-execute this configuration. Keep the canonical bar color and hidden ready marker. Native code must finish within three seconds; detached work is unsupported."
        : "Macarchy retains its wallpaper callback and completion signal. No scripting addition or SIP changes.")
  }

  static func starter(_ provider: DesktopPersonalProvider) -> String {
    """
    # Personal \(provider.rawValue) configuration; /bin/sh syntax, defaults run first.
    # Edit this file, not Macarchy's generated entry point.
    # \(notice(provider))
    \(provider == .yabai
      ? "# Example: \"$YABAI\" -m config window_gap 12\n# Example: \"$YABAI\" -m rule --remove macarchy-example"
      : "# Example: \"$SKETCHYBAR\" --bar height=36\n# Example: \"$SKETCHYBAR\" --set macarchy.clock position=left")

    """
  }
}

struct MenuDesktopEditSession {
  let provider: DesktopPersonalProvider
  let context: UnifiedSetupPlanContext
  let source: URL
  let target: URL
  let before: String
  let profileEdit: MenuNativeProfileEdit
  let generation: String
  let defaults: URL
  let defaultsPhysical: URL
  let defaultsBytes: Data
  let newConnection: Bool

  static func begin(
    provider: DesktopPersonalProvider, context: UnifiedSetupPlanContext,
    source: URL, newConnection: Bool
  ) throws -> Self {
    let edit = try MenuNativeProfileEdit.desktop(
      context: context, source: source, provider: provider)
    guard !edit.files.contains(where: \.changed),
      let target = try MenuProfileSource.prepare(
        source, stateRoot: context.stateRoot, confirmCreation: { _ in false })
    else {
      throw EnvironmentLifecycleError.blocked("personal connection is not ready for editing")
    }
    let defaults = context.desktopResourcesRoot.appending(
      path: "\(provider.rawValue)/defaults.toml")
    return Self(
      provider: provider, context: context, source: source, target: target,
      before: try BoundedRegularFile.readUTF8(at: target, maximumSize: 1_048_576),
      profileEdit: edit,
      generation: try provider.managedGeneration(profile: edit.profile, context: context),
      defaults: defaults, defaultsPhysical: defaults.resolvingSymlinksInPath(),
      defaultsBytes: try BoundedRegularFile.read(
        at: defaults.resolvingSymlinksInPath(), maximumSize: 65_536
      ).data,
      newConnection: newConnection)
  }

  func finish(runner: DesktopApplyCommandRunner = .live) throws -> ApplyResult? {
    try ActivationLock(root: context.stateRoot).withLock {
      let current = try BoundedRegularFile.readUTF8(at: target, maximumSize: 1_048_576)
      guard newConnection || current != before else { return nil }
      try validateFrozenInputs()
      if !newConnection,
        try !provider.inputsMatchGeneration(
          profile: profileEdit.profile, context: context,
          excludingPersonalConfiguration: true)
      {
        throw EnvironmentLifecycleError.blocked(
          "provider baseline differs or cannot be verified; saved edits remain, but review desktop apply before activation"
        )
      }
      let composition = try provider.compose(profile: profileEdit.profile, context: context)
      try validateFrozenInputs()
      guard try BoundedRegularFile.readUTF8(at: target, maximumSize: 1_048_576) == current else {
        throw EnvironmentLifecycleError.blocked(
          "personal input changed during validation; reopen Configure")
      }
      return try runner.applyPersonalConfigurationLocked(composition, context: context)
    }
  }

  private func validateFrozenInputs() throws {
    try profileEdit.validateBefore()
    guard source.resolvingSymlinksInPath() == target,
      try MenuProfileSource.prepare(
        source, stateRoot: context.stateRoot, confirmCreation: { _ in false }) == target,
      defaults.resolvingSymlinksInPath() == defaultsPhysical,
      try BoundedRegularFile.read(at: defaultsPhysical, maximumSize: 65_536).data == defaultsBytes,
      try provider.managedGeneration(profile: profileEdit.profile, context: context) == generation
    else {
      throw EnvironmentLifecycleError.blocked(
        "provider, source or defaults changed during editing; reopen Configure")
    }
  }
}
