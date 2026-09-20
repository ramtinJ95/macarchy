import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuKeybindingSaveTests {
  @Test func nativeSavePreservesStowLinkAndRejectsInvalidInputAndScopeDrift() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = fixture.root.appending(path: "personal.skhdrc")
    let physical = fixture.root.appending(path: "dotfiles.skhdrc")
    let machine = fixture.stateRoot.appending(path: "machine.toml")
    try "# Personal bindings\n".write(to: physical, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: native, withDestinationURL: physical)
    let original = "schema_version = 1\n[keybindings]\noverride = \"personal.skhdrc\"\n"
    try original.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    var session = try MenuKeybindingSaveSession.begin(
      portableURL: fixture.profile, machineURL: machine, target: physical,
      resourcesRoot: fixture.resources, homeDirectory: fixture.home, planner: runner.planner
    ).session
    session = try JSONDecoder().decode(
      MenuKeybindingSaveSession.self, from: JSONEncoder().encode(session))
    let initial = session.generationID
    lifecycle.calls.withLock { $0 = [] }
    try "alt - j : personal command\nalt - k : another command\n".write(
      to: physical, atomically: true, encoding: .utf8)
    _ = try session.apply(runner: runner)
    #expect(session.generationID != initial)
    #expect(lifecycle.calls.withLock { $0.contains("reload") && !$0.contains("restart") })
    let generated = try String(
      contentsOf: fixture.stateRoot.appending(path: "keybindings/current/skhdrc"), encoding: .utf8)
    #expect(generated.contains("personal command") && generated.contains("another command"))
    #expect(!generated.contains("focus south"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: native.path) == physical.path)
    let active = session.generationID
    lifecycle.calls.withLock { $0 = [] }
    try ".load \"other.skhdrc\"\n".write(to: physical, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    #expect(try String(contentsOf: physical, encoding: .utf8).contains(".load"))
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID == active)
    #expect(lifecycle.calls.withLock { $0.isEmpty })
    try "alt - j : recovered\n".write(to: physical, atomically: true, encoding: .utf8)
    _ = try session.apply(runner: runner)
    lifecycle.calls.withLock { $0 = [] }
    // Native sessions freeze both profile layers, including disabled-list edits.
    try (original + "disabled = [\"alt-j\"]\n").write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    try original.write(to: fixture.profile, atomically: true, encoding: .utf8)
    try "schema_version = 1\n".write(to: machine, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    try FileManager.default.removeItem(at: machine)
    let other = fixture.root.appending(path: "retargeted.skhdrc")
    try FileManager.default.copyItem(at: physical, to: other)
    try FileManager.default.removeItem(at: native)
    try FileManager.default.createSymbolicLink(at: native, withDestinationURL: other)
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    #expect(lifecycle.calls.withLock { $0.isEmpty })
  }

  @Test func authorizedSaveUsesExistingReloadAndInvalidSaveRetainsGeneration() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n".write(to: fixture.profile, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    var session = try MenuKeybindingSaveSession.begin(
      portableURL: fixture.profile, machineURL: fixture.stateRoot.appending(path: "machine.toml"),
      target: fixture.profile, resourcesRoot: fixture.resources, homeDirectory: fixture.home,
      planner: runner.planner
    ).session
    // The real save helper decodes this snapshot in a different process.
    session = try JSONDecoder().decode(
      MenuKeybindingSaveSession.self, from: JSONEncoder().encode(session))
    let initial = session.generationID
    lifecycle.calls.withLock { $0 = [] }
    try "schema_version = 1\n[keybindings]\ndisabled = [\"alt-j\"]\n".write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    _ = try session.apply(runner: runner)
    #expect(session.generationID != initial)
    #expect(lifecycle.calls.withLock { $0.contains("reload") && !$0.contains("restart") })
    let active = session.generationID
    lifecycle.calls.withLock { $0 = [] }
    try "schema_version = 1\n[keybindings]\ndisabled = [\"alt-unknown\"]\n".write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID == active)
    #expect(lifecycle.calls.withLock { $0.isEmpty })
    #expect(try String(contentsOf: fixture.profile, encoding: .utf8).contains("alt-unknown"))
    try "schema_version = 1\n[keybindings]\ndisabled = []\n".write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    _ = try session.apply(runner: runner)
    #expect(session.generationID != active)
  }

  @Test func unrelatedAndInvalidChangesCannotApply() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n".write(to: fixture.profile, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    var session = try MenuKeybindingSaveSession.begin(
      portableURL: fixture.profile, machineURL: fixture.stateRoot.appending(path: "machine.toml"),
      target: fixture.profile, resourcesRoot: fixture.resources, homeDirectory: fixture.home,
      planner: runner.planner
    ).session
    lifecycle.calls.withLock { $0 = [] }
    for edit in [
      "[desktop]\nprovider = \"disabled\"",
      "[top_bar]\nprovider = \"disabled\"",
      "[packages]\nexclude_formulae = [\"bat\"]",
      "[macos_preferences]\nenabled = true\ndock_autohide = true",
      "[keybindings]\noverride = \"new.skhdrc\"",
      "[keybindings]\ndisabled = [",
    ] {
      try ("schema_version = 1\n" + edit + "\n").write(
        to: fixture.profile, atomically: true, encoding: .utf8)
      #expect(throws: (any Error).self) { try session.validatedProfile() }
    }
    // One end-to-end scope rejection proves the mutator does not run.
    try "schema_version = 1\n[desktop]\nprovider = \"disabled\"\n".write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    #expect(lifecycle.calls.withLock { $0.isEmpty })
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
        == session.generationID)
  }

  @Test func machineLayerSavePreservesPortableStowLinkAndRejectsOtherSourceChanges() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let physical = fixture.root.appending(path: "dotfiles.toml")
    let machine = fixture.stateRoot.appending(path: "machine.toml")
    try "schema_version = 1\n".write(to: physical, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: fixture.profile.path, withDestinationPath: physical.path)
    try "schema_version = 1\n[keybindings]\ndisabled = []\n".write(
      to: machine, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    let layered = try PortableProfileLoader().load(
      portableAt: fixture.profile, portableRequired: true, machineAt: machine, machineRequired: true
    )
    _ = try runner.applyIntegrationLocked(
      resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: true,
      stateRoot: fixture.stateRoot, homeDirectory: fixture.home, adopt: nil,
      deferFinalization: false, profile: layered.profile)
    var session = try MenuKeybindingSaveSession.begin(
      portableURL: fixture.profile, machineURL: machine, target: machine,
      resourcesRoot: fixture.resources, homeDirectory: fixture.home, planner: runner.planner
    ).session
    try "schema_version = 1\n[keybindings]\ndisabled = [\"alt-j\"]\n".write(
      to: machine, atomically: true, encoding: .utf8)
    _ = try session.apply(runner: runner)
    let generated = fixture.stateRoot.appending(path: "keybindings/current/skhdrc")
    #expect(!(try String(contentsOf: generated, encoding: .utf8)).contains("focus south"))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.profile.path)
        == physical.path)
    #expect(try String(contentsOf: physical, encoding: .utf8) == "schema_version = 1\n")
    try "schema_version = 1\n[top_bar]\nprovider = \"disabled\"\n".write(
      to: physical, atomically: true, encoding: .utf8)
    lifecycle.calls.withLock { $0 = [] }
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    #expect(lifecycle.calls.withLock { $0.isEmpty })
  }

  @Test func staleGenerationAndUnmanagedEntryCannotAcquireSaveAuthority() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n".write(to: fixture.profile, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    func begin(machineRequired: Bool = false) throws -> MenuKeybindingSaveSession {
      try MenuKeybindingSaveSession.begin(
        portableURL: fixture.profile, machineURL: fixture.stateRoot.appending(path: "machine.toml"),
        target: fixture.profile, resourcesRoot: fixture.resources, homeDirectory: fixture.home,
        machineRequired: machineRequired, planner: runner.planner
      ).session
    }
    #expect(throws: (any Error).self) { try begin() }
    #expect(lifecycle.calls.withLock { $0.isEmpty })
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    #expect(throws: (any Error).self) { try begin(machineRequired: true) }
    var session = try begin()
    try "schema_version = 1\n[keybindings]\ndisabled = [\"alt-j\"]\n".write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    let active = KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    lifecycle.calls.withLock { $0 = [] }
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID == active)
    #expect(lifecycle.calls.withLock { $0.isEmpty })
  }

  @Test func externalNativeOverrideChangesRequireReview() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = fixture.root.appending(path: "personal.skhdrc")
    try "alt - k : focus north\n".write(to: native, atomically: true, encoding: .utf8)
    try "schema_version = 1\n[keybindings]\noverride = \"personal.skhdrc\"\n".write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    var session = try MenuKeybindingSaveSession.begin(
      portableURL: fixture.profile, machineURL: fixture.stateRoot.appending(path: "machine.toml"),
      target: fixture.profile, resourcesRoot: fixture.resources, homeDirectory: fixture.home,
      planner: runner.planner
    ).session
    let approvedDigest = try #require(
      try runner.planner.prepare(
        resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: true,
        stateRoot: fixture.stateRoot, homeDirectory: fixture.home
      ).composition?.inputDigest)
    try "alt - k : changed outside session\n".write(to: native, atomically: true, encoding: .utf8)
    lifecycle.calls.withLock { $0 = [] }
    #expect(throws: (any Error).self) { try session.apply(runner: runner) }
    #expect(lifecycle.calls.withLock { $0.isEmpty })
    // The lifecycle also checks its newly read composition, rather than trusting
    // an earlier caller-side preview when a native input has since changed.
    #expect(throws: (any Error).self) {
      try runner.applyIntegrationLocked(
        resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: true,
        stateRoot: fixture.stateRoot, homeDirectory: fixture.home, adopt: nil,
        deferFinalization: false, approvedInputDigest: approvedDigest)
    }
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
        == session.generationID)
    #expect(lifecycle.calls.withLock { !$0.contains("reload") && !$0.contains("restart") })
  }
}
