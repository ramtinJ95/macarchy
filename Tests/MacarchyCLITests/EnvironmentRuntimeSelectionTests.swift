import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// The applied adapter inventory that selects which theme adapters run.
struct EnvironmentRuntimeSelectionTests {
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
          BordersAdapter.id, BordersAdapter.leanID, SpicetifyAdapter.id,
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
