import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct NeovimStarshipSetupTests {
  @Test
  func ownedLinksRoundTripWithoutOwningBehaviorOrGeneratedBridge() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.createNeovimStarshipPrerequisites()
    try FileManager.default.createDirectory(
      at: fixture.starshipBridge.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let bridge = Data("generated bridge survives teardown\n".utf8)
    try bridge.write(to: fixture.starshipBridge)
    let watcher = try Data(contentsOf: fixture.neovimWatcherConfiguration)
    let behavior = try Data(contentsOf: fixture.starshipBehavior)
    try fixture.tearDownLegacyOwnership(
      [
        fixture.legacyThemeLink(SetupOwnershipManager.neovimThemeLinkID),
        fixture.legacyThemeLink(SetupOwnershipManager.starshipConfigurationLinkID),
      ],
      expectingRemoved: ["neovim.theme-link", "starship.configuration-link"])
    #expect(!FileManager.default.fileExists(atPath: fixture.neovimThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.starshipConfigurationLink.path))
    #expect(try Data(contentsOf: fixture.neovimWatcherConfiguration) == watcher)
    #expect(try Data(contentsOf: fixture.starshipBehavior) == behavior)
    #expect(try Data(contentsOf: fixture.starshipBridge) == bridge)
  }
}

extension Fixture {
  var neovimWatcherConfiguration: URL {
    home.appending(path: ".config/nvim/lua/plugins/colorscheme.lua")
  }

  var neovimThemeLink: URL {
    home.appending(path: ".config/nvim/lua/macarchy/current.lua")
  }

  var starshipBehavior: URL {
    home.appending(path: ".config/starship/behavior.toml")
  }

  var starshipConfigurationLink: URL {
    home.appending(path: ".config/starship.toml")
  }

  var starshipBridge: URL {
    stateRoot.appending(path: StarshipAdapter.bridgePath)
  }

  func createNeovimStarshipPrerequisites() throws {
    try FileManager.default.createDirectory(
      at: neovimWatcherConfiguration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(
      "local macarchy = require(\"config.macarchy-theme\")\n\(NeovimAdapter.integrationDirective)\n"
        .utf8
    ).write(to: neovimWatcherConfiguration)
    try FileManager.default.createDirectory(
      at: starshipBehavior.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("format = \"$directory$character\"\n".utf8).write(to: starshipBehavior)
  }
}
