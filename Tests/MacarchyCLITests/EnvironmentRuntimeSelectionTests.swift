import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// The applied adapter inventory that selects which theme adapters run.
struct EnvironmentRuntimeSelectionTests {
  @Test func themeSetDryRunAndRuntimeUseOnlyTheAppliedScripts() async throws {
    let fixture = try RuntimeSelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let directory = try makeTrustedScriptDirectory()
    defer { removeTemporaryRoot(directory) }
    let script = directory.appending(path: "record")
    let recorded = directory.appending(path: "events")
    try "#!/bin/sh\necho $MACARCHY_EVENT >> \"$(dirname \"$0\")/events\"\n"
      .write(to: script, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(
      EnvironmentOwnership(
        generationID: "e-00000000-0000-0000-0000-000000000000", records: [],
        createdDirectories: [], originalThemeBridges: [], userScripts: [script.path],
        enabledThemeAdapterIDs: [UserScriptsAdapter.id]))
    let repository = ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes"))
    let paths = testConsumerPaths(homeDirectory: fixture.home)
    let preview = try await ThemeActivationService.live.execute(
      repository: repository,
      themeID: "catppuccin-mocha", stateRoot: fixture.state, consumerPaths: paths,
      dryRun: true, json: false)
    #expect(preview.succeeded, "\(preview.output)")
    #expect(preview.output.contains("user-scripts"))
    #expect(!FileManager.default.fileExists(atPath: recorded.path))
    let applied = try await ThemeActivationService.live.execute(
      repository: repository,
      themeID: "catppuccin-mocha", stateRoot: fixture.state, consumerPaths: paths,
      dryRun: false, json: false)
    #expect(applied.succeeded, "\(applied.output)")
    #expect(applied.output.contains("record succeeded"))
    #expect(try String(contentsOf: recorded, encoding: .utf8) == "apply\n")
  }

  @Test
  func malformedAndUnknownAppliedAdapterInventoriesBlockRuntimeSelection() throws {
    let fixture = try RuntimeSelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = EnvironmentStateStore(stateRoot: fixture.state)

    for ownership in [
      EnvironmentOwnership(
        generationID: "e-00000000-0000-0000-0000-000000000000",
        records: [],
        createdDirectories: [],
        originalThemeBridges: [],
        tuicrEnabled: true,
        enabledThemeAdapterIDs: [TuicrAdapter.id, TuicrAdapter.id]
      ),
      EnvironmentOwnership(
        generationID: "e-00000000-0000-0000-0000-000000000000",
        records: [],
        createdDirectories: [],
        originalThemeBridges: [],
        enabledThemeAdapterIDs: ["unknown-adapter"]
      ),
    ] {
      try store.writeOwnership(ownership)
      #expect(throws: (any Error).self) {
        try ThemeRuntimeSelection.enabledAdapterIDs(
          stateRoot: fixture.state,
          homeDirectory: fixture.home
        )
      }
    }
  }

  @Test
  func ownershipWithoutAppliedAdapterInventoryDecodesWithLegacySelection() throws {
    let fixture = try RuntimeSelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let legacy = EnvironmentOwnership(
      generationID: "e-00000000-0000-0000-0000-000000000000",
      records: [],
      createdDirectories: [],
      originalThemeBridges: [],
      tuicrEnabled: true
    )
    let data = try JSONEncoder().encode(legacy)
    #expect(!String(decoding: data, as: UTF8.self).contains("enabled_theme_adapter_ids"))
    let decoded = try JSONDecoder().decode(EnvironmentOwnership.self, from: data)
    #expect(decoded.enabledThemeAdapterIDs == nil)
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(decoded)

    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      )
        == Set(ThemeActivationCoordinator.adapterRequirements.keys).subtracting([
          ZedAdapter.id, AlacrittyAdapter.id, GhosttyAdapter.id, BordersAdapter.id,
          BordersAdapter.leanID,
          UserScriptsAdapter.id, MacOSAccentAdapter.id,
          SpicetifyAdapter.id,
        ])
    )
  }

  private struct RuntimeSelectionFixture {
    let root: URL
    let home: URL
    let state: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: "macarchy-runtime-selection-\(UUID().uuidString)", directoryHint: .isDirectory)
      home = root.appending(path: "home", directoryHint: .isDirectory)
      state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }
  }
}
