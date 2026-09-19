import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuNativeConfigurationSetupTests {
  @Test(arguments: [EnvironmentNativeSeed.Provider.atuin, .starship, .zsh, .kitty], [false, true])
  func initialConnectionSeedsAndReopensWithoutTouchingOtherProviders(
    provider: EnvironmentNativeSeed.Provider, external: Bool
  ) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let source =
      external
      ? fixture.root.appending(path: "personal.toml")
      : provider.standardURL(homeDirectory: fixture.home)
    if external {
      let original = try String(contentsOf: fixture.profile, encoding: .utf8)
      try (original + "\n[\(provider.rawValue)]\n\(provider.profileKey) = \"personal.toml\"\n")
        .write(to: fixture.profile, atomically: true, encoding: .utf8)
    }
    let setup = MenuNativeConfigurationSetup(
      provider: provider, context: context(fixture),
      io: GuidedSetupIO(read: { "yes" }, write: { _ in }))
    #expect(try setup.prepareForEditing()?.path == source.resolvingSymlinksInPath().path)
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let ownership = try #require(try store.readOwnership())
    #expect(ownership.enabledThemeAdapterIDs == (provider == .zsh ? [] : [provider.rawValue]))
    #expect(
      ownership.records.allSatisfy {
        $0.id == provider.entryID || (provider == .atuin && $0.id == .atuinTheme)
      })
    #expect(!store.transactionExists)
    if provider == .atuin {
      let theme = fixture.home.appending(path: ".config/atuin/themes/macarchy-current.toml")
      #expect(
        try Data(contentsOf: theme)
          == Data(contentsOf: fixture.state.appending(path: "current/generated/atuin.toml")))
    }
    let personal = try Data(contentsOf: source) + Data("\n# personal edit\n".utf8)
    try personal.write(to: source)
    let reopened = MenuNativeConfigurationSetup(
      provider: provider, context: context(fixture),
      io: GuidedSetupIO(
        read: {
          Issue.record("Reopen must not prompt")
          return "no"
        }, write: { _ in }))
    #expect(try reopened.prepareForEditing()?.path == source.resolvingSymlinksInPath().path)
    #expect(try Data(contentsOf: source) == personal)
    #expect(try store.readOwnership() == ownership)
    if provider == .atuin {
      try FileManager.default.removeItem(
        at: fixture.home.appending(path: ".config/atuin/themes/macarchy-current.toml"))
      #expect(throws: (any Error).self) { try reopened.prepareForEditing() }
      #expect(try Data(contentsOf: source) == personal)
    }
  }

  @Test(arguments: [EnvironmentNativeSeed.Provider.atuin, .starship, .zsh, .kitty], [false, true])
  func firstConnectionCancellationRetainsOnlyApprovedPersonalPreparation(
    provider: EnvironmentNativeSeed.Provider, acceptSeed: Bool
  ) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let before = try Data(contentsOf: fixture.profile)
    let answers = Mutex(acceptSeed ? ["yes", "no"] : ["no"])
    let setup = MenuNativeConfigurationSetup(
      provider: provider, context: context(fixture),
      io: GuidedSetupIO(read: { answers.withLock { $0.removeFirst() } }, write: { _ in }))
    #expect(try setup.prepareForEditing() == nil)
    #expect(try Data(contentsOf: fixture.profile) == before)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == nil)
    let source = provider.standardURL(homeDirectory: fixture.home)
    #expect(FileManager.default.fileExists(atPath: source.path) == acceptSeed)
    if acceptSeed {
      let personal = try Data(contentsOf: source) + Data("\n# retained edit before retry\n".utf8)
      try personal.write(to: source)
      let retry = MenuNativeConfigurationSetup(
        provider: provider, context: context(fixture),
        io: GuidedSetupIO(read: { "yes" }, write: { _ in }))
      #expect(try retry.prepareForEditing()?.path == source.resolvingSymlinksInPath().path)
      #expect(try Data(contentsOf: source) == personal)
    }
  }

  @Test(arguments: [EnvironmentNativeSeed.Provider.atuin, .starship])
  func legacyMigrationIsReviewedScopedAndReopensWithoutMutation(
    provider: EnvironmentNativeSeed.Provider
  ) async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    let context = context(fixture)
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let before = try #require(try store.readOwnership())
    let profileBefore = try Data(contentsOf: fixture.profile)
    let native = fixture.home.appending(path: ".config/\(provider.rawValue)-native.toml")
    let cancelled = try MenuNativeConfigurationSetup(
      provider: provider, context: context,
      io: GuidedSetupIO(read: { "no" }, write: { _ in })
    ).prepareForEditing()
    #expect(cancelled == nil)
    #expect(try store.readOwnership() == before)
    #expect(try Data(contentsOf: fixture.profile) == profileBefore)
    #expect(!FileManager.default.fileExists(atPath: native.path))

    let output = Mutex("")
    let target = try MenuNativeConfigurationSetup(
      provider: provider, context: context,
      io: GuidedSetupIO(read: { "yes" }, write: { line in output.withLock { $0 += line } })
    )
    .prepareForEditing()
    #expect(target?.path == native.resolvingSymlinksInPath().path)
    #expect(
      try store.readOwnership() == before.replacingTarget(for: provider.entryID, with: native.path))
    #expect(output.withLock { $0 }.contains("No full apply"))
    let personal = try Data(contentsOf: native) + Data("\n# personal edit\n".utf8)
    try personal.write(to: native)
    let profileAfter = try Data(contentsOf: fixture.profile)
    let reopened = try MenuNativeConfigurationSetup(
      provider: provider, context: context,
      io: GuidedSetupIO(
        read: {
          Issue.record("Reopen must not prompt")
          return "no"
        }, write: { _ in })
    )
    .prepareForEditing()
    #expect(reopened == target)
    #expect(try Data(contentsOf: native) == personal)
    #expect(try Data(contentsOf: fixture.profile) == profileAfter)
    #expect(!store.transactionExists)
  }

  @Test(arguments: [EnvironmentNativeSeed.Provider.atuin, .starship])
  func changedProfileConsentCannotMigrate(provider: EnvironmentNativeSeed.Provider) async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let before = try store.readOwnership()
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    let setup = MenuNativeConfigurationSetup(
      provider: provider, context: context(fixture),
      io: GuidedSetupIO(
        read: {
          try? (original + "\n# concurrent edit\n").write(
            to: fixture.profile, atomically: true, encoding: .utf8)
          return "yes"
        }, write: { _ in }))
    #expect(throws: (any Error).self) { try setup.prepareForEditing() }
    #expect(try store.readOwnership() == before)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/\(provider.rawValue)-native.toml").path))
    #expect(try String(contentsOf: fixture.profile, encoding: .utf8).contains("concurrent edit"))
  }

  @Test(arguments: [EnvironmentNativeSeed.Provider.atuin, .starship])
  func absentCustomSourceHasSeparateSeedAndConnectionConsent(
    provider: EnvironmentNativeSeed.Provider
  ) async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    let source = fixture.root.appending(path: "personal.toml")
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    try (original + "\n[\(provider.rawValue)]\n\(provider.profileKey) = \"personal.toml\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let before = try store.readOwnership()
    let answers = Mutex(["yes", "no"])
    let cancelled = try MenuNativeConfigurationSetup(
      provider: provider, context: context(fixture),
      io: GuidedSetupIO(read: { answers.withLock { $0.removeFirst() } }, write: { _ in })
    )
    .prepareForEditing()
    #expect(cancelled == nil)
    #expect(try store.readOwnership() == before)
    let seeded = try Data(contentsOf: source)
    let personal = seeded + Data("\n# retained personal edit\n".utf8)
    try personal.write(to: source)
    let connected = try MenuNativeConfigurationSetup(
      provider: provider, context: context(fixture),
      io: GuidedSetupIO(read: { "yes" }, write: { _ in })
    ).prepareForEditing()
    #expect(connected?.path == source.resolvingSymlinksInPath().path)
    #expect(try Data(contentsOf: source) == personal)
    #expect(
      try store.readOwnership() == before?.replacingTarget(for: provider.entryID, with: source.path)
    )
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
