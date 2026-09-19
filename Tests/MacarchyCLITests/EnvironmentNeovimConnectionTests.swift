import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentNeovimConnectionTests {
  @Test(arguments: [true, false]) func connectsPreparedSourceWithoutOtherProviders(standard: Bool)
    throws
  {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source =
      standard
      ? fixture.home.appending(path: ".config/nvim") : fixture.root.appending(path: "personal")
    let connection = try preparedConnection(fixture, source: source)
    let initial = try Data(contentsOf: source.appending(path: "init.lua"))
    let lock = try Data(contentsOf: source.appending(path: "lazy-lock.json"))
    let plan = try connection.plan()
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    #expect(try store.readOwnership() == nil)
    try connection.connectLocked(approval: plan.approval)
    let ownership = try #require(try store.readOwnership())
    #expect(ownership.enabledThemeAdapterIDs == ["neovim"])
    #expect(ownership.records.count == (standard ? 0 : 1))
    #expect(ownership.standardNativeEntries?.contains(.neovim) == (standard ? true : nil))
    #expect(!store.transactionExists)
    #expect(try Data(contentsOf: source.appending(path: "init.lua")) == initial)
    #expect(try Data(contentsOf: source.appending(path: "lazy-lock.json")) == lock)
    let manifest = try #require(
      try EnvironmentGenerationStore(stateRoot: fixture.state).currentManifest())
    #expect(manifest.artifacts.keys.allSatisfy { $0.hasPrefix("neovim/") })
    #expect(throws: (any Error).self) { try connection.plan() }
  }

  @Test func staleConsentAndFailurePreserveSourceAndRestoreAbsentConnection() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "personal")
    let connection = try preparedConnection(fixture, source: source)
    let plan = try connection.plan()
    try Data("-- user changed this\n".utf8).write(to: source.appending(path: "init.lua"))
    #expect(throws: (any Error).self) { try connection.connectLocked(approval: plan.approval) }
    let reviewed = try connection.plan()
    #expect(throws: (any Error).self) {
      try connection.connectLocked(approval: reviewed.approval) { _ in
        throw EnvironmentLifecycleError.blocked("injected publication failure")
      }
    }
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(!FileManager.default.fileExists(atPath: connection.publicURL.path))
    #expect(
      try String(contentsOf: source.appending(path: "init.lua"), encoding: .utf8)
        == "-- user changed this\n")
  }

  private func preparedConnection(_ fixture: EnvironmentLifecycleFixture, source: URL) throws
    -> EnvironmentNeovimConnection
  {
    try fixture.activateTheme()
    let resources = repositoryRoot.appending(path: "Environment")
    let seed = EnvironmentNativeSeed(
      provider: .neovim, destination: source,
      homeDirectory: fixture.home, stateRoot: fixture.state, resourcesRoot: resources)
    _ = try seed.seed(approval: seed.plan().approval)
    return EnvironmentNeovimConnection(
      homeDirectory: fixture.home, stateRoot: fixture.state,
      source: source, resourcesRoot: resources)
  }
}
