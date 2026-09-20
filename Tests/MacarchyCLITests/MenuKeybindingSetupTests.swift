import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuKeybindingSetupTests {
  @Test(arguments: [0, 1, 2])
  func firstConnectionReviewsSeedAndScopedReloadThenReopensWithoutMutation(approvals: Int) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let physicalProfile = fixture.root.appending(path: "dotfiles.toml")
    let original = "schema_version = 1\n# preserve personal settings\n"
    try original.write(to: physicalProfile, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: fixture.profile, withDestinationURL: physicalProfile)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    let generation = KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot)
      .generationID
    lifecycle.calls.withLock { $0 = [] }
    let answers = Mutex(Array(repeating: "y", count: approvals) + ["n"])
    let setup = MenuKeybindingSetup(
      context: context(fixture), runner: runner,
      io: GuidedSetupIO(read: { answers.withLock { $0.removeFirst() } }, write: { _ in }))
    let result = try setup.prepareForEditing()
    let source = fixture.root.appending(path: "overrides/keybindings.skhdrc")
    #expect(FileManager.default.fileExists(atPath: source.path) == (approvals > 0))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.profile.path)
        == physicalProfile.path)
    if approvals < 2 {
      #expect(result == nil)
      #expect(try String(contentsOf: physicalProfile, encoding: .utf8) == original)
      #expect(lifecycle.calls.withLock { $0.isEmpty })
      #expect(
        KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
          == generation)
      if approvals == 1 {
        let personal = "alt - j : retained personal command\n"
        try personal.write(to: source, atomically: true, encoding: .utf8)
        var retry = setup
        let prompts = Mutex(0)
        retry.io = GuidedSetupIO(
          read: {
            prompts.withLock { $0 += 1 }
            return "y"
          }, write: { _ in })
        #expect(try retry.prepareForEditing() == source.resolvingSymlinksInPath())
        #expect(prompts.withLock { $0 } == 1)
        #expect(try String(contentsOf: source, encoding: .utf8) == personal)
        #expect(lifecycle.calls.withLock { $0.contains("reload") && !$0.contains("restart") })
      }
      return
    }
    #expect(result == source.resolvingSymlinksInPath())
    // A comment-only override does not alter canonical effective bindings.
    let calls = lifecycle.calls.withLock { $0 }
    #expect(calls.contains("verify"))
    #expect(!calls.contains("reload") && !calls.contains("restart"))
    #expect(
      try String(contentsOf: physicalProfile, encoding: .utf8).contains(
        "override = \"overrides/keybindings.skhdrc\""))
    #expect(
      try MenuNativeProfileEdit.load(context(fixture)).profile.keybindings.overrideURL?.path
        == source.path)
    lifecycle.calls.withLock { $0 = [] }
    var reopen = setup
    reopen.io = GuidedSetupIO(
      read: {
        Issue.record("Connected reopen must not prompt")
        return "n"
      }, write: { _ in })
    #expect(try reopen.prepareForEditing() == result)
    #expect(lifecycle.calls.withLock { $0.isEmpty })
    // The actual native save path accepts the newly connected input.
    _ = try MenuKeybindingSaveSession.begin(
      portableURL: fixture.profile, machineURL: context(fixture).machineProfileURL,
      target: source, resourcesRoot: fixture.resources, homeDirectory: fixture.home,
      planner: runner.planner)
  }

  @Test(arguments: ["profile", "source"])
  func staleConnectionConsentRetainsPreparationWithoutPublishingOrReloading(change: String) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n".write(to: fixture.profile, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    lifecycle.calls.withLock { $0 = [] }
    let source = fixture.root.appending(path: "overrides/keybindings.skhdrc")
    let count = Mutex(0)
    let setup = MenuKeybindingSetup(
      context: context(fixture), runner: runner,
      io: GuidedSetupIO(
        read: {
          let number = count.withLock {
            $0 += 1
            return $0
          }
          if number == 2 {
            do {
              let target = change == "profile" ? fixture.profile : source
              let contents =
                change == "profile"
                ? "schema_version = 1\n# concurrent edit\n" : "alt - j : changed after review\n"
              try contents.write(to: target, atomically: true, encoding: .utf8)
            } catch { Issue.record("Fixture edit failed: \(error)") }
          }
          return "y"
        }, write: { _ in }))
    #expect(throws: (any Error).self) { try setup.prepareForEditing() }
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!(try String(contentsOf: fixture.profile, encoding: .utf8)).contains("override ="))
    #expect(lifecycle.calls.withLock { $0.isEmpty })
  }

  @Test func machineOverrideWinsAndUnmanagedConnectionDoesNotSeed() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n".write(to: fixture.profile, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    let setup = MenuKeybindingSetup(
      context: context(fixture), runner: runner,
      io: GuidedSetupIO(
        read: {
          Issue.record("Unmanaged setup must not offer mutation")
          return "n"
        }, write: { _ in }))
    #expect(throws: (any Error).self) { try setup.prepareForEditing() }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "overrides").path))
    let machineSource = fixture.stateRoot.appending(path: "personal.skhdrc")
    try "invalid but repairable\n".write(to: machineSource, atomically: true, encoding: .utf8)
    try "schema_version = 1\n[keybindings]\noverride = \"personal.skhdrc\"\n".write(
      to: setup.context.machineProfileURL, atomically: true, encoding: .utf8)
    #expect(try setup.prepareForEditing() == machineSource.resolvingSymlinksInPath())
    #expect(lifecycle.calls.withLock { $0.isEmpty })
  }

  private func context(_ fixture: KeybindingsApplyFixture) -> UnifiedSetupPlanContext {
    UnifiedSetupPlanContext(
      themesRoot: fixture.resources, keybindingsResourcesRoot: fixture.resources,
      desktopResourcesRoot: fixture.resources, environmentResourcesRoot: fixture.resources,
      profileURL: fixture.profile, profileRequired: true,
      machineProfileURL: fixture.stateRoot.appending(path: "machine.toml"),
      machineProfileRequired: false,
      stateRoot: fixture.stateRoot, homeDirectory: fixture.home)
  }
}
