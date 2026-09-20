import Foundation
import ThemeCore

/// Connect one personal skhd input to the already-managed keybinding lifecycle.
/// Profile publication is reviewed intent, not an aggregate setup authorization.
struct MenuKeybindingSetup {
  let context: UnifiedSetupPlanContext
  var runner: KeybindingsApplyCommandRunner = .live
  var io: GuidedSetupIO = .live

  static let starter = """
    # Personal skhd bindings. Macarchy loads packaged defaults first.
    # Add a chord or replace its default command here, for example:
    # alt - return : open -a kitty
    # Disable defaults with [keybindings] disabled in the profile.
    # Only Macarchy's supported skhd binding syntax is accepted (no modes/includes).
    # Menu saves validate and reload keybindings only; invalid edits remain saved.

    """

  func prepareForEditing() throws -> URL? {
    let layered = try MenuNativeProfileEdit.load(context)
    let source =
      layered.profile.keybindings.overrideURL
      ?? context.profileURL.resolvingSymlinksInPath().deletingLastPathComponent()
      .appending(path: "overrides/keybindings.skhdrc")
    let existing = try MenuProfileSource.prepare(
      source, stateRoot: context.stateRoot, confirmCreation: { _ in false })
    // An existing declaration remains repairable even when its bytes are invalid
    // or pending. The editor separately grants save authority only if converged.
    if layered.profile.keybindings.overrideURL != nil, let existing { return existing }

    let edit = try MenuNativeProfileEdit.keybindings(context: context, source: source)
    if layered.profile.keybindings.overrideURL == nil {
      // Do not fold pre-existing keybinding drift into a first connection.
      _ = try MenuKeybindingSaveSession.begin(
        portableURL: context.profileURL, machineURL: context.machineProfileURL,
        target: context.profileURL.resolvingSymlinksInPath(),
        resourcesRoot: context.keybindingsResourcesRoot, homeDirectory: context.homeDirectory,
        portableRequired: context.profileRequired, machineRequired: context.machineProfileRequired,
        planner: runner.planner)
    }
    if existing == nil {
      io.write("Create personal keybindings at \(source.path):\n\(Self.starter)\n")
      guard try confirm("Create this absent file? It remains if connection is cancelled.") else {
        return nil
      }
      try ActivationLock(root: context.stateRoot).withLock {
        try edit.validateBefore()
        guard
          try MenuProfileSource.prepare(
            source, stateRoot: context.stateRoot, confirmCreation: { _ in false }) == nil
        else {
          throw EnvironmentLifecycleError.blocked("keybinding source appeared; review again")
        }
        _ = try MenuProfileSource.prepare(
          source, stateRoot: context.stateRoot, initialContents: Self.starter,
          confirmCreation: { _ in true })
      }
    }
    let physical = source.resolvingSymlinksInPath()
    let plan = try prepare(edit.profile)
    let digest = try reviewedDigest(plan, profile: edit.profile)
    io.write("Personal keybinding source: \(physical.path)\n")
    for file in edit.files where file.changed {
      io.write("Set keybindings.override in \(file.physical.path); preserve all other fields.\n")
    }
    io.write(
      "Proposed effective skhd configuration:\n\(plan.composition?.renderedConfiguration ?? "")\n")
    guard
      try confirm(
        "Save this source connection and reload only managed keybindings? Saved intent remains on failure. No adoption, installation or other provider apply."
      )
    else { return nil }
    try ActivationLock(root: context.stateRoot).withLock {
      try edit.validateBefore()
      let current = try prepare(edit.profile)
      guard source.resolvingSymlinksInPath() == physical,
        try reviewedDigest(current, profile: edit.profile) == digest,
        current.generation.generationID == plan.generation.generationID
      else {
        throw EnvironmentLifecycleError.blocked("keybinding connection changed; review again")
      }
      try edit.publish()
      let result = try runner.applyIntegrationLocked(
        resourcesRoot: context.keybindingsResourcesRoot, profileURL: context.profileURL,
        profileRequired: context.profileRequired, stateRoot: context.stateRoot,
        homeDirectory: context.homeDirectory, adopt: nil, deferFinalization: false,
        profile: edit.profile, approvedInputDigest: digest)
      io.write(result.message + "\n")
    }
    return physical
  }

  private func prepare(_ profile: PortableProfile) throws -> KeybindingsPlanPreparation {
    try runner.planner.prepare(
      resourcesRoot: context.keybindingsResourcesRoot, profileURL: context.profileURL,
      profileRequired: context.profileRequired, stateRoot: context.stateRoot,
      homeDirectory: context.homeDirectory, profile: profile)
  }

  private func reviewedDigest(_ plan: KeybindingsPlanPreparation, profile: PortableProfile) throws
    -> String
  {
    guard profile.desktop.provider == .yabaiSkhd, plan.outcome != "blocked",
      plan.provider.status == .managed, plan.effectiveBehavior.transaction.status == .clear,
      plan.generation.generationID != nil, let digest = plan.composition?.inputDigest
    else {
      throw EnvironmentLifecycleError.blocked(
        "keybindings require an existing managed, recoverable connection: "
          + plan.blockingMessages.joined(separator: "; "))
    }
    return digest
  }

  private func confirm(_ question: String) throws -> Bool {
    let approved = try io.confirm(question)
    if !approved { io.write("Cancelled. Earlier approved personal files remain.\n") }
    return approved
  }
}
