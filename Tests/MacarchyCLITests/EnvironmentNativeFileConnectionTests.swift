import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentNativeFileConnectionTests {
  @Test(arguments: [EnvironmentNativeSeed.Provider.atuin, .starship, .zsh, .kitty])
  func staleSourceConsentAndForeignEntriesCannotConnect(
    provider: EnvironmentNativeSeed.Provider
  ) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let seedProvider = provider
    let source = fixture.root.appending(path: "personal.toml")
    let seed = EnvironmentNativeSeed(
      provider: seedProvider, destination: source, homeDirectory: fixture.home,
      stateRoot: fixture.state, resourcesRoot: repositoryRoot.appending(path: "Environment"))
    _ = try seed.seed(approval: seed.plan().approval)
    if provider == .atuin {
      try FileManager.default.createDirectory(
        at: fixture.home.appending(path: ".config/atuin/themes"), withIntermediateDirectories: true)
    }
    if provider == .kitty { try KittyAdapter.prepareBridge(root: fixture.state) }
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[\(seedProvider.rawValue)]\n\(provider.profileKey) = \"personal.toml\"\n",
      source: fixture.profile)
    let connection = EnvironmentNativeFileConnection(
      provider: seedProvider, homeDirectory: fixture.home, stateRoot: fixture.state, source: source,
      resourcesRoot: repositoryRoot.appending(path: "Environment"))
    let plan = try connection.plan(profile: profile)
    let personal = try Data(contentsOf: source) + Data("\n# concurrent edit\n".utf8)
    try personal.write(to: source)
    #expect(throws: (any Error).self) {
      try connection.connectLocked(profile: profile, approval: plan.approval)
    }
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == nil)
    let foreign = provider == .atuin ? connection.themeURL : connection.publicURL
    try Data("personal incumbent\n".utf8).write(to: foreign)
    #expect(throws: (any Error).self) { try connection.plan(profile: profile) }
    #expect(try Data(contentsOf: foreign) == Data("personal incumbent\n".utf8))
    #expect(try Data(contentsOf: source) == personal)
  }
}
