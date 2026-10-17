import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct CodexPresetLifecycleTests {
  @Test
  func divergentSelectorAdoptionRestoresInsideTUIAfterProviderShiftsEarlierLines() async throws {
    let original =
      "model = \"gpt-5\"\r\n[tui]\r\ntheme = \"personal\" # keep\r\nanimations = true\r\n"
    let fixture = try CodexFixture(configuration: original)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == "model = \"gpt-5\"\r\n[tui]\r\ntheme = \"macarchy-current\"\r\nanimations = true\r\n"
    )
    let providerRewrite =
      "model = \"gpt-5.4\"\r\n"
      + "approval_policy = \"on-request\"\r\n"
      + "sandbox_mode = \"workspace-write\"\r\n"
      + "[tui]\r\ntheme = \"macarchy-current\"\r\nanimations = false\r\n"
    try providerRewrite.write(to: fixture.configuration, atomically: true, encoding: .utf8)

    #expect(try await fixture.teardown().succeeded)
    let expected =
      "model = \"gpt-5.4\"\r\n"
      + "approval_policy = \"on-request\"\r\n"
      + "sandbox_mode = \"workspace-write\"\r\n"
      + "[tui]\r\ntheme = \"personal\" # keep\r\nanimations = false\r\n"
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == expected)
  }

  @Test
  func restorationPreservesMultilineSelectorWithoutTerminalNewline() throws {
    let source = URL(filePath: "/tmp/codex-config.toml")
    let original = "[tui]\ntheme = '''personal\npalette'''"
    let ownership = try EnvironmentCodexDocument.ownership(for: original, source: source)
    let providerRewrite =
      "model = \"gpt-5.4\"\n[tui]\ntheme = \"macarchy-current\"\nanimations = false\n"

    let restored = try EnvironmentCodexDocument.restoringOriginal(
      in: providerRewrite, ownership: ownership, source: source)

    #expect(
      restored
        == "model = \"gpt-5.4\"\n[tui]\ntheme = '''personal\npalette'''\nanimations = false\n"
    )
    #expect(
      try EnvironmentCodexDocument.matchesOriginal(
        restored, ownership: ownership, source: source)
    )
  }

  @Test
  func absentTableAndFileAreRemovedOnlyWhenStillSafe() async throws {
    let ordinary = try CodexFixture(configuration: "model = \"gpt-5\"")
    defer { try? FileManager.default.removeItem(at: ordinary.root) }
    try ordinary.activateTheme()
    let digest = try #require(
      try jsonObject(ordinary.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await ordinary.apply(adopt: digest).succeeded)
    #expect(
      try String(contentsOf: ordinary.configuration, encoding: .utf8)
        == "model = \"gpt-5\"\n[tui]\ntheme = \"macarchy-current\"\n"
    )
    #expect(try await ordinary.teardown().succeeded)
    #expect(try String(contentsOf: ordinary.configuration, encoding: .utf8) == "model = \"gpt-5\"")

    let providerRewrite = try CodexFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: providerRewrite.root) }
    try providerRewrite.activateTheme()
    #expect(try await providerRewrite.apply().succeeded)
    try "[tui]\ntheme = \"macarchy-current\"\nanimations = false\n".write(
      to: providerRewrite.configuration, atomically: true, encoding: .utf8)
    #expect(try await providerRewrite.teardown().succeeded)
    #expect(
      try String(contentsOf: providerRewrite.configuration, encoding: .utf8)
        == "[tui]\nanimations = false\n"
    )
  }

  @Test
  func malformedNoncanonicalAndDuplicateSelectorsBlockWithoutMutation() async throws {
    for text in [
      "[tui\ntheme = \"personal\"\n",
      "tui.theme = \"personal\"\n",
      "[tui]\ntheme = \"one\"\ntheme = \"two\"\n",
    ] {
      let fixture = try CodexFixture(configuration: text)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      try fixture.activateTheme()
      let before = try Data(contentsOf: fixture.configuration)
      #expect(try !fixture.plan().succeeded)
      #expect(!(try await fixture.apply()).succeeded)
      #expect(try Data(contentsOf: fixture.configuration) == before)
      #expect(try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == nil)
    }
  }

  @Test
  func staleAdoptionEvidenceRevalidatesBeforeAnyGenerationOrProviderMutation() throws {
    let fixture = try CodexFixture(configuration: "[tui]\ntheme = \"personal\"\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let profile = try PortableProfileLoader().load(at: fixture.profile, required: true)
    let composition = try EnvironmentConfigurationComposer().compose(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profile: profile,
      stateRoot: fixture.state
    )
    let inspection = EnvironmentProviderInspector().inspect(
      composition: composition, homeDirectory: fixture.home, stateRoot: fixture.state)
    let digest = try #require(inspection.adoptionEvidenceDigest)
    try "[tui]\ntheme = \"changed\"\n".write(
      to: fixture.configuration, atomically: true, encoding: .utf8)

    #expect(throws: EnvironmentLifecycleError.self) {
      _ = try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home, stateRoot: fixture.state
      ).applyLocked(
        composition: composition,
        inspection: inspection,
        adoptionDigest: digest,
        themeBridges: EnvironmentThemeBridgeState(entries: [])
      )
    }
    #expect(try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8).contains("changed"))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appending(path: "environment/generations").path)
    )
  }

  @Test
  func exactPersonalStowTupleRemainsByteAndInodeExactThroughDisableAndTeardown() async throws {
    let fixture = try CodexFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.installPersonalExternalTuple(themeDestination: fixture.themeDestination)
    try fixture.activateTheme()
    let before = try fixture.externalSnapshot()

    let plan = try fixture.plan()
    #expect(plan.succeeded)
    let entries = try #require(try jsonObject(plan.output)["entries"] as? [[String: Any]])
    #expect(
      entries.filter { ($0["id"] as? String)?.hasPrefix("codex_") == true }
        .allSatisfy { $0["ownership"] as? String == "external_exact" }
    )
    #expect(try await fixture.apply().succeeded)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(ownership.codexEnabled && ownership.codex == nil)
    #expect(!ownership.records.contains { $0.id == .codexTheme })
    #expect(try fixture.externalSnapshot() == before)
    #expect((try await fixture.apply()).succeeded)
    #expect(try fixture.externalSnapshot() == before)

    try fixture.writeProfile(enabled: false)
    #expect(try await fixture.apply().succeeded)
    #expect(try fixture.externalSnapshot() == before)
    try fixture.writeProfile(enabled: true)
    #expect(try await fixture.apply().succeeded)
    #expect(try await fixture.teardown().succeeded)
    #expect(try fixture.externalSnapshot() == before)
  }

  @Test
  func partialExternalTupleBlocksBeforeAuthority() async throws {
    let partial = try CodexFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: partial.root) }
    try partial.installPersonalExternalTuple(
      themeDestination: partial.root.appending(path: "wrong"))
    try partial.activateTheme()
    #expect(try !partial.plan().succeeded)
    #expect(!(try await partial.apply()).succeeded)
    #expect(try EnvironmentStateStore(stateRoot: partial.state).readOwnership() == nil)
  }

  @Test
  func oldAppliedAuthorityBlocksLegacyTeardownUntilModernInventoryDisablesCodex() throws {
    let fixture = try CodexFixture(configuration: "[tui]\nanimations = false\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    let manager = SetupOwnershipManager()
    try fixture.writeLegacyOwnership([
      try fixture.legacyThemeLink(SetupOwnershipManager.codexThemeLinkID),
      try fixture.legacyFileRecord(
        SetupOwnershipManager.codexSelectorID,
        original: "[tui]\nanimations = false\n",
        installed: "[tui]\ntheme = \"macarchy-current\"\nanimations = false\n"),
    ])
    try fixture.writeProfile(enabled: false)
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state, homeDirectory: fixture.home
      ).contains(CodexAdapter.id)
    )

    let oldOwnership = EnvironmentOwnership(
      generationID: "e-\(UUID().uuidString.lowercased())",
      records: [],
      createdDirectories: [],
      originalThemeBridges: []
    )
    var oldShape = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(oldOwnership))
        as? [String: Any]
    )
    oldShape.removeValue(forKey: "codex")
    oldShape.removeValue(forKey: "codex_enabled")
    oldShape.removeValue(forKey: "enabled_theme_adapter_ids")
    #expect(oldShape["codex"] == nil)
    #expect(oldShape["codex_enabled"] == nil)
    #expect(oldShape["enabled_theme_adapter_ids"] == nil)
    let environmentDirectory = fixture.state.appending(path: "environment")
    try FileManager.default.createDirectory(
      at: environmentDirectory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: oldShape).write(
      to: environmentDirectory.appending(path: "ownership.json"))
    let decoded = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(!decoded.codexEnabled)
    #expect(decoded.enabledThemeAdapterIDs == nil)
    #expect(
      ThemeRuntimeSelection.appliedAdapterIDs(for: decoded).contains(CodexAdapter.id)
    )

    let teardown = try TeardownCommandRunner(ownershipManager: manager).execute(
      homeDirectory: fixture.home, dryRun: false, json: false)
    #expect(!teardown.succeeded)
    #expect(teardown.output.contains("[presets].codex = false"))
    #expect(try fixture.linkDestination() == fixture.themeDestination.path)
    #expect(
      Set(try manager.readRecords(context: context).map(\.id))
        .isSuperset(of: [
          SetupOwnershipManager.codexSelectorID,
          SetupOwnershipManager.codexThemeLinkID,
        ])
    )

    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(
      EnvironmentOwnership(
        generationID: "e-\(UUID().uuidString.lowercased())",
        records: [],
        createdDirectories: [],
        originalThemeBridges: [],
        enabledThemeAdapterIDs: []
      )
    )
    let disabled = try TeardownCommandRunner(ownershipManager: manager).execute(
      homeDirectory: fixture.home, dryRun: false, json: false)
    #expect(disabled.succeeded)
    #expect(
      Set(try manager.readRecords(context: context).map(\.id))
        .isDisjoint(with: [
          SetupOwnershipManager.codexSelectorID,
          SetupOwnershipManager.codexThemeLinkID,
        ])
    )
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state, homeDirectory: fixture.home
      ).contains(CodexAdapter.id)
    )
  }

}

private struct CodexFixture: LegacySetupOwnershipFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL
  let configuration: URL
  let themeLink: URL
  let themeDestination: URL

  init(configuration contents: String?) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-codex-preset-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = root.appending(path: "profile.toml")
    configuration = home.appending(path: ".codex/config.toml")
    themeLink = home.appending(path: ".codex/themes/macarchy-current.tmTheme")
    themeDestination = state.appending(path: "current/generated/bat.tmTheme")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    if let contents {
      try FileManager.default.createDirectory(
        at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: configuration, atomically: true, encoding: .utf8)
    }
    try writeProfile(enabled: true)
  }

  func writeProfile(enabled: Bool) throws {
    try presetTestProfile(presets: ["codex": enabled])
      .write(to: profile, atomically: true, encoding: .utf8)
  }

  func activateTheme() throws {
    try activateCatppuccinMocha(stateRoot: state)
  }

  private var lifecycle: PresetLifecycleTestHarness {
    PresetLifecycleTestHarness(profile: profile, state: state, home: home)
  }

  func plan() throws -> (output: String, succeeded: Bool) {
    try lifecycle.plan()
  }

  func apply(
    adopt: String? = nil,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
  ) async throws -> (output: String, succeeded: Bool) {
    try await lifecycle.apply(
      runner: EnvironmentApplyCommandRunner(
        prerequisites: .assumed,
        theme: themeController,
        verifier: .assumed,
        transactionFaultInjector: faultInjector
      ),
      consumerPaths: testConsumerPaths(),
      adopt: adopt
    )
  }

  func status() throws -> (output: String, succeeded: Bool) {
    try lifecycle.status(
      runner: EnvironmentStatusCommandRunner(
        prerequisites: .assumed, theme: themeController
      ),
      consumerPaths: testConsumerPaths()
    )
  }

  func teardown() async throws -> (output: String, succeeded: Bool) {
    try await lifecycle.teardown(consumerPaths: testConsumerPaths())
  }

  func linkDestination() throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: themeLink.path)
  }

  func installPersonalExternalTuple(themeDestination: URL) throws {
    let codex = root.appending(path: "dotfiles/codex", directoryHint: .isDirectory)
    let themes = root.appending(path: "dotfiles/codex-themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    try "model = \"gpt-5\"\n[tui]\ntheme = \"macarchy-current\"\n".write(
      to: codex.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: themes.appending(path: themeLink.lastPathComponent), withDestinationURL: themeDestination)
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: configuration.path, withDestinationPath: "../../dotfiles/codex/config.toml")
    try FileManager.default.createSymbolicLink(
      atPath: themeLink.deletingLastPathComponent().path,
      withDestinationPath: "../../dotfiles/codex-themes"
    )
  }

  func externalSnapshot() throws -> ExternalTupleSnapshot {
    try ExternalTupleSnapshot(
      [
        configuration,
        configuration.resolvingSymlinksInPath(),
        themeLink.deletingLastPathComponent(),
        themeLink,
        root.appending(path: "dotfiles/codex-themes", directoryHint: .isDirectory),
        root.appending(path: "dotfiles/codex-themes/\(themeLink.lastPathComponent)"),
      ],
      requireAll: true
    )
  }

  private var themeController: DesktopThemeController {
    let freshLaunch =
      "A fresh Codex TUI launch uses the active palette; running sessions are unchanged."
    return stubThemeController(
      reconciled: ("restart_required", freshLaunch), inspected: ("restart_required", freshLaunch))
  }
}

extension CodexFixture: PresetFileFixture {
  var presetFile: URL { configuration }

  var themeLinks: [(link: URL, destination: URL)] { [(themeLink, themeDestination)] }

  func setPresetEnabled(_ enabled: Bool) throws {
    try writeProfile(enabled: enabled)
  }

  func applyPreset(
    adopt: String?,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void
  ) async throws -> (output: String, succeeded: Bool) {
    try await apply(adopt: adopt, faultInjector: faultInjector)
  }
}

func makeCodexPresetFileFixture(configuration: String?) throws -> any PresetFileFixture {
  let fixture = try CodexFixture(configuration: configuration)
  do {
    try fixture.activateTheme()
  } catch {
    try? FileManager.default.removeItem(at: fixture.root)
    throw error
  }
  return fixture
}
