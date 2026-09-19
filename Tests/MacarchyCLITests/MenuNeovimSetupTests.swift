import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuNeovimSetupTests {
  @Test func absentStarterReviewConnectsAndReopenRequiresNoMutation() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    try FileManager.default.removeItem(at: fixture.profile)
    let context = context(fixture)
    let output = Mutex("")
    let questions = Mutex(0)
    let setup = MenuNeovimSetup(
      context: context, homeDirectory: fixture.home,
      resourcesRoot: context.environmentResourcesRoot,
      io: GuidedSetupIO(
        read: {
          questions.withLock { $0 += 1 }
          return "yes"
        }, write: { text in output.withLock { $0 += text } }))
    let target = try #require(try setup.prepareForEditing())
    #expect(target.declaredRoot.path == fixture.home.appending(path: ".config/nvim").path)
    #expect(target.notice.contains("next instance"))
    #expect(questions.withLock { $0 } == 2)
    #expect(output.withLock { $0.contains("No plugin restore") })
    #expect(!FileManager.default.fileExists(atPath: context.machineProfileURL.path))
    let source = try String(contentsOf: fixture.profile, encoding: .utf8)
    #expect(!source.contains(fixture.root.path))
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let before = try store.readOwnership()
    let reopened = try MenuNeovimSetup(
      context: context, homeDirectory: fixture.home,
      resourcesRoot: context.environmentResourcesRoot,
      io: GuidedSetupIO(
        read: {
          Issue.record("connected source should not prompt")
          return "no"
        }, write: { _ in })
    ).prepareForEditing()
    #expect(reopened?.physicalRoot == target.physicalRoot)
    #expect(try store.readOwnership() == before)
    #expect(try String(contentsOf: fixture.profile, encoding: .utf8) == source)
  }

  @Test(arguments: [false, true]) func cancellationDoesNotGrantConnection(acceptSeed: Bool) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n".write(to: fixture.profile, atomically: true, encoding: .utf8)
    try fixture.activateTheme()
    let context = context(fixture)
    let answers = Mutex(acceptSeed ? ["yes", "no"] : ["no"])
    let result = try MenuNeovimSetup(
      context: context, homeDirectory: fixture.home,
      resourcesRoot: context.environmentResourcesRoot,
      io: GuidedSetupIO(read: { answers.withLock { $0.removeFirst() } }, write: { _ in })
    ).prepareForEditing()
    #expect(result == nil)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/nvim/init.lua").path) == acceptSeed)
    #expect(try String(contentsOf: fixture.profile, encoding: .utf8) == "schema_version = 1\n")
  }

  @Test func machineSelectedCustomTreePreservesProfilesLuaAndLock() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let context = context(fixture)
    let source = fixture.root.appending(path: "personal")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let initial = Data("-- arbitrary personal Lua, never evaluated by setup\n".utf8)
    let lock = Data("{\"personal-plugin\": {\"commit\": \"keep-me\"}}\n".utf8)
    try initial.write(to: source.appending(path: "init.lua"))
    try lock.write(to: source.appending(path: "lazy-lock.json"))
    let portable = "schema_version = 1\n[neovim]\nnative_configuration = \"unused-portable\"\n"
    let machine = "schema_version = 1\n[neovim]\nnative_configuration = \"personal\"\n"
    try portable.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let physical = fixture.root.appending(path: "real-machine.toml")
    try machine.write(to: physical, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: context.machineProfileURL, withDestinationURL: physical)
    let target = try MenuNeovimSetup(
      context: context, homeDirectory: fixture.home,
      resourcesRoot: context.environmentResourcesRoot,
      io: GuidedSetupIO(read: { "yes" }, write: { _ in })
    ).prepareForEditing()
    #expect(target?.physicalRoot.path == source.resolvingSymlinksInPath().path)
    #expect(try Data(contentsOf: source.appending(path: "init.lua")) == initial)
    #expect(try Data(contentsOf: source.appending(path: "lazy-lock.json")) == lock)
    #expect(try String(contentsOf: fixture.profile, encoding: .utf8) == portable)
    #expect(try String(contentsOf: physical, encoding: .utf8) == machine)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: context.machineProfileURL.path)
        == physical.path)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.home.appending(path: ".config/nvim").path) == source.path)
  }

  @Test func copiedProfileConversionPreservesLayersAndRejectsStaleEdits() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = context(fixture)
    let original =
      "schema_version = 1\n# keep this comment\n[neovim]\nconfiguration = \"personal\"\n[keybindings]\ndisabled = []\n"
    let physical = fixture.root.appending(path: "real-profile.toml")
    try original.write(to: physical, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: fixture.profile)
    try FileManager.default.createSymbolicLink(at: fixture.profile, withDestinationURL: physical)
    let source = fixture.root.appending(path: "personal")
    let edit = try MenuNativeProfileEdit.prepare(context: context, source: source)
    try edit.publish()
    let changed = try String(contentsOf: physical, encoding: .utf8)
    #expect(changed.contains("# keep this comment"))
    #expect(changed.contains("[keybindings]\ndisabled = []"))
    #expect(changed.contains("native_configuration = \"personal\""))
    #expect(!changed.contains("\nconfiguration ="))
    #expect(!FileManager.default.fileExists(atPath: context.machineProfileURL.path))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.profile.path)
        == physical.path)
    let stale = try MenuNativeProfileEdit.prepare(
      context: context, source: fixture.root.appending(path: "other"))
    try (changed + "# subsequent user edit\n").write(
      to: physical, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try stale.publish() }
    #expect(try String(contentsOf: physical, encoding: .utf8).hasSuffix("# subsequent user edit\n"))
  }

  @Test func legacyMenuMigrationReusesExistingCutovers() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n[focus_ring]\nprovider = \"disabled\"\n".write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    try fixture.activateTheme()
    let applied = try await fixture.apply(adopt: nil)
    try #require(applied.succeeded)
    let context = context(fixture)
    let questions = Mutex(0)
    let target = try MenuNeovimSetup(
      context: context, homeDirectory: fixture.home,
      resourcesRoot: context.environmentResourcesRoot,
      io: GuidedSetupIO(
        read: {
          questions.withLock { $0 += 1 }
          return "yes"
        }, write: { _ in })
    ).prepareForEditing()
    #expect(target?.declaredRoot.path == fixture.home.appending(path: ".config/nvim").path)
    #expect(questions.withLock { $0 } == 2)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/nvim-native").path))
    #expect(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.standardNativeEntries?
        .contains(.neovim) == true)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
  }

  private func context(_ fixture: EnvironmentLifecycleFixture) -> UnifiedSetupPlanContext {
    UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes"),
      keybindingsResourcesRoot: repositoryRoot.appending(path: "Keybindings"),
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: fixture.profile, profileRequired: false,
      machineProfileURL: fixture.root.appending(path: "machine.toml"),
      machineProfileRequired: false,
      stateRoot: fixture.state, homeDirectory: fixture.home)
  }
}
