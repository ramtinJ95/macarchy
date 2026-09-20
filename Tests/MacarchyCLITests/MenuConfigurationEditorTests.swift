import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuConfigurationEditorTests {
  @Test(arguments: [MenuConfigurationAction.zsh, .kitty])
  func managedNativeDefaultsOpenProfileWithoutMigration(action: MenuConfigurationAction)
    async throws
  {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let before = try store.readOwnership()
    let context = context(fixture)
    let selected = try MenuNativeConfigurationSetup(
      provider: action.nativeProvider!, context: context,
      io: GuidedSetupIO(
        read: {
          Issue.record("No migration expected")
          return nil
        }, write: { _ in })
    ).prepareForEditing()
    #expect(selected?.path == fixture.profile.resolvingSymlinksInPath().path)
    #expect(
      try MenuConfigurationValidate.validate(action, target: selected!, context: context)
        .contains("reviewed environment plan/apply is required"))
    #expect(try store.readOwnership() == before)
  }

  @Test(arguments: [MenuConfigurationAction.zsh, .kitty])
  func copiedNativeInputsKeepTheirShape(action: MenuConfigurationAction) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "personal-input")
    if action == .kitty {
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
      try "font_size 14\n".write(
        to: source.appending(path: "kitty.conf"), atomically: true, encoding: .utf8)
    } else {
      try "# personal hook\n".write(to: source, atomically: true, encoding: .utf8)
    }
    let key = action == .kitty ? "override" : "hook"
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    let profile = original + "\n[\(action.rawValue)]\n\(key) = \"personal-input\"\n"
    try profile.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let context = context(fixture)
    let selected = try MenuNativeConfigurationSetup(
      provider: action.nativeProvider!, context: context,
      io: GuidedSetupIO(
        read: {
          Issue.record("No setup review expected")
          return nil
        }, write: { _ in })
    ).prepareForEditing()
    #expect(selected?.path == source.resolvingSymlinksInPath().path)
    #expect(try MenuConfigurationEditor.target(action, context: context) == selected)
    let feedback = try MenuConfigurationValidate.validate(
      action, target: selected!, context: context)
    #expect(feedback.contains("reviewed environment plan/apply is required"))
    #expect(try String(contentsOf: fixture.profile, encoding: .utf8) == profile)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  @Test(arguments: [MenuConfigurationAction.starship, .atuin, .kitty, .zsh])
  func nativeFilesUsePhysicalDeclaredSourceWithoutRewriting(action: MenuConfigurationAction)
    async throws
  {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let file = fixture.root.appending(path: "personal-config")
    let alias = fixture.root.appending(path: "linked-config")
    let contents = "personal input needing repair\n"
    try fixture.activateTheme()
    let seed = EnvironmentNativeSeed(
      provider: action.nativeProvider!, destination: file,
      homeDirectory: fixture.home, stateRoot: fixture.state,
      resourcesRoot: repositoryRoot.appending(path: "Environment"))
    _ = try seed.seed(approval: seed.plan().approval)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
    let key = action.nativeProvider!.profileKey
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    try (original + "\n[\(action.rawValue)]\n\(key) = \"linked-config\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) {
      try MenuConfigurationEditor.target(action, context: context(fixture))
    }
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    let target = try MenuConfigurationEditor.target(action, context: context(fixture))
    #expect(target?.path == file.resolvingSymlinksInPath().path)
    #expect(try String(contentsOf: file, encoding: .utf8) == contents)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == file.path)
    let managed = fixture.state.appending(path: "private-input")
    try contents.write(to: managed, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: managed)
    #expect(throws: (any Error).self) {
      try MenuConfigurationEditor.target(action, context: context(fixture))
    }
  }

  @Test(arguments: [MenuConfigurationAction.starship, .atuin, .kitty, .zsh])
  func saveValidationIsReadOnlyAndReportsNativeLimits(action: MenuConfigurationAction) async throws
  {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let provider = action.nativeProvider!
    let destination = fixture.root.appending(path: "personal-\(action.rawValue)")
    let seed = EnvironmentNativeSeed(
      provider: provider, destination: destination, homeDirectory: fixture.home,
      stateRoot: fixture.state, resourcesRoot: repositoryRoot.appending(path: "Environment"))
    let preview = try seed.plan()
    _ = try seed.seed(approval: preview.approval)
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    try
      (original
      + "\n[\(action.rawValue)]\n\(provider.profileKey) = \"\(destination.lastPathComponent)\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
    let target = destination.resolvingSymlinksInPath()
    #expect(throws: (any Error).self) {
      try MenuConfigurationValidate.validate(action, target: target, context: context(fixture))
    }
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    let ownership = try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    let before = try Data(contentsOf: target)
    _ = try MenuConfigurationValidate.validate(
      action, target: target, context: context(fixture))
    #expect(try Data(contentsOf: target) == before)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == ownership)
    if action == .atuin || action == .starship {
      let invalid = "broken = [\n"
      try invalid.write(to: target, atomically: true, encoding: .utf8)
      #expect(throws: (any Error).self) {
        try MenuConfigurationValidate.validate(action, target: target, context: context(fixture))
      }
      #expect(try String(contentsOf: target, encoding: .utf8) == invalid)
      // Syntactically valid TOML still must preserve the theme seam.
      try "personal = true\n".write(to: target, atomically: true, encoding: .utf8)
      #expect(throws: (any Error).self) {
        try MenuConfigurationValidate.validate(action, target: target, context: context(fixture))
      }
    }
    let other = fixture.root.appending(path: "different-source")
    try before.write(to: other)
    try (original + "\n[\(action.rawValue)]\n\(provider.profileKey) = \"different-source\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) {
      try MenuConfigurationValidate.validate(action, target: target, context: context(fixture))
    }
    #expect(throws: (any Error).self) {
      // Matching the newly declared file alone must not prove an active wrapper/link.
      try MenuConfigurationValidate.validate(
        action, target: other.resolvingSymlinksInPath(),
        context: context(fixture))
    }
  }

  @Test(arguments: [MenuConfigurationAction.desktop, .bar])
  func managedSaveValidatesBothLayersWithoutApplying(action: MenuConfigurationAction) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n".write(to: fixture.profile, atomically: true, encoding: .utf8)
    let target = fixture.profile.resolvingSymlinksInPath()
    let setup = context(fixture)
    #expect(
      try MenuConfigurationValidate.validate(action, target: target, context: setup)
        .contains("No managed state was changed"))
    try "schema_version = 1\n[yabai]\nwindow_gap = -5\n"
      .write(to: setup.machineProfileURL, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) {
      try MenuConfigurationValidate.validate(action, target: target, context: setup)
    }
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  private func context(_ fixture: EnvironmentLifecycleFixture) -> UnifiedSetupPlanContext {
    UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes"),
      keybindingsResourcesRoot: repositoryRoot.appending(path: "Keybindings"),
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: fixture.profile, profileRequired: true,
      machineProfileURL: fixture.root.appending(path: "machine.toml"),
      machineProfileRequired: false,
      stateRoot: fixture.state, homeDirectory: fixture.home)
  }
}
