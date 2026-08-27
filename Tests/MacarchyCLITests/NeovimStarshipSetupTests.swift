import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct NeovimStarshipSetupTests {
  @Test
  func exactExternalSeamsIncludingTheRealTwoHopShapeRemainUnclaimed() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try FileManager.default.createDirectory(
      at: fixture.starshipBridge.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("existing generated bridge\n".utf8).write(to: fixture.starshipBridge)

    let results = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let group = Array(results[12..<16])

    #expect(
      group.map(\.id)
        == [
          "neovim.watcher",
          "neovim.theme-link",
          "starship.behavior",
          "starship.configuration-link",
        ]
    )
    #expect(group.allSatisfy { $0.status == .external && !$0.mutationAttempted })
    #expect(
      try fixture.linkDestination(fixture.starshipConfigurationLink)
        == fixture.starshipFirstHopDestination
    )
    #expect(
      try fixture.linkDestination(fixture.starshipStowLink)
        == fixture.starshipSecondHopDestination
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func ownedLinksRoundTripWithoutOwningBehaviorOrGeneratedBridge() throws {
    let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createNeovimStarshipPrerequisites()
    try FileManager.default.createDirectory(
      at: fixture.starshipBridge.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let bridge = Data("generated bridge survives teardown\n".utf8)
    try bridge.write(to: fixture.starshipBridge)
    let watcher = try Data(contentsOf: fixture.neovimWatcherConfiguration)
    let behavior = try Data(contentsOf: fixture.starshipBehavior)

    let preview = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    #expect(
      preview[12..<16].map(\.status)
        == [.external, .planned, .external, .planned]
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))

    let setup = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let manifest = try JSONDecoder().decode(
      NeovimStarshipManifest.self,
      from: Data(contentsOf: fixture.manifest)
    )

    #expect(
      setup[12..<16].map(\.status)
        == [.external, .owned, .external, .owned]
    )
    #expect(
      manifest.records.map(\.id)
        == ["neovim.theme-link", "starship.configuration-link"]
    )
    #expect(
      try fixture.linkDestination(fixture.neovimThemeLink)
        == fixture.neovimThemeDestination.path
    )
    #expect(
      try fixture.linkDestination(fixture.starshipConfigurationLink)
        == fixture.starshipBridge.path
    )
    #expect(try Data(contentsOf: fixture.neovimWatcherConfiguration) == watcher)
    #expect(try Data(contentsOf: fixture.starshipBehavior) == behavior)
    #expect(try Data(contentsOf: fixture.starshipBridge) == bridge)

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(teardown[12..<16].map(\.status) == [.none, .removed, .none, .removed])
    #expect(!FileManager.default.fileExists(atPath: fixture.neovimThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.starshipConfigurationLink.path))
    #expect(try Data(contentsOf: fixture.neovimWatcherConfiguration) == watcher)
    #expect(try Data(contentsOf: fixture.starshipBehavior) == behavior)
    #expect(try Data(contentsOf: fixture.starshipBridge) == bridge)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func watcherMustContainTheExactExternalPrerequisite() throws {
    let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createNeovimStarshipPrerequisites(
      watcher: "local current = require('config.macarchy-theme')\n"
    )

    #expect(
      throws: SetupOwnershipError.missingExternalDirective(
        "neovim.watcher",
        fixture.neovimWatcherConfiguration
      )
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func watcherLineRecognitionMatchesTheAdapterForCRLF() throws {
    let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let watcher =
      "local macarchy = require(\"config.macarchy-theme\")\r\n"
      + "\(NeovimAdapter.integrationDirective)\r\n"
    try fixture.createNeovimStarshipPrerequisites(watcher: watcher)
    try fixture.createExternalNeovimThemeLink()
    try fixture.createExternalTwoHopStarshipLink()

    let results = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)

    #expect(NeovimAdapter.containsIntegrationDirective(in: watcher))
    #expect(results[12..<16].allSatisfy { $0.status == .external })
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func prerequisitesDoNotFollowFinalSymlinksLikeTheAdapters() throws {
    let neovim = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { neovim.remove() }
    try neovim.writeKittyConfiguration("\(neovim.includeDirective)\n")
    try neovim.createNeovimStarshipPrerequisites()
    let watcherSource = neovim.root.appending(path: "external-watcher.lua")
    try FileManager.default.moveItem(
      at: neovim.neovimWatcherConfiguration,
      to: watcherSource
    )
    try FileManager.default.createSymbolicLink(
      at: neovim.neovimWatcherConfiguration,
      withDestinationURL: watcherSource
    )

    do {
      _ = try SetupOwnershipManager().setup(homeDirectory: neovim.home, dryRun: true)
      Issue.record("Expected the final Neovim watcher symlink to fail")
    } catch SetupOwnershipError.invalidConfiguration(let id, let target, _) {
      #expect(id == "neovim.watcher")
      #expect(target == neovim.neovimWatcherConfiguration)
    }
    #expect(!FileManager.default.fileExists(atPath: neovim.manifest.path))

    let starship = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { starship.remove() }
    try starship.writeKittyConfiguration("\(starship.includeDirective)\n")
    try starship.createNeovimStarshipPrerequisites()
    try starship.createExternalNeovimThemeLink()
    let behaviorSource = starship.root.appending(path: "external-starship.toml")
    try FileManager.default.moveItem(
      at: starship.starshipBehavior,
      to: behaviorSource
    )
    try FileManager.default.createSymbolicLink(
      at: starship.starshipBehavior,
      withDestinationURL: behaviorSource
    )

    do {
      _ = try SetupOwnershipManager().setup(homeDirectory: starship.home, dryRun: true)
      Issue.record("Expected the final Starship behavior symlink to fail")
    } catch SetupOwnershipError.invalidConfiguration(let id, let target, _) {
      #expect(id == "starship.behavior")
      #expect(target == starship.starshipBehavior)
    }
    #expect(!FileManager.default.fileExists(atPath: starship.manifest.path))
  }

  @Test
  func starshipBehaviorRejectsThemeOwnershipAndMalformedToml() throws {
    for behavior in [
      "format = \"$directory\"\npalette = \"user-owned\"\n",
      "[palettes.user-owned]\nblue = \"#89b4fa\"\n",
      "format = [\n",
    ] {
      let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
      defer { fixture.remove() }
      try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
      try fixture.createNeovimStarshipPrerequisites(behavior: behavior)
      try fixture.createExternalNeovimThemeLink()

      do {
        _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
        Issue.record("Expected Starship behavior validation to fail")
      } catch SetupOwnershipError.invalidConfiguration(let id, let target, _) {
        #expect(id == "starship.behavior")
        #expect(target == fixture.starshipBehavior)
      } catch {
        Issue.record("Expected invalid Starship behavior, got \(error)")
      }
      #expect(try String(contentsOf: fixture.starshipBehavior, encoding: .utf8) == behavior)
      #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    }
  }

  @Test
  func starshipRecognitionDoesNotGeneralizeBeyondTheExactTwoHopChain() throws {
    let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createNeovimStarshipPrerequisites()
    try fixture.createExternalNeovimThemeLink()
    try fixture.createThreeHopStarshipLink()

    #expect(
      throws: SetupOwnershipError.conflictingThemeLink(
        "starship.configuration-link",
        fixture.starshipConfigurationLink
      )
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func starshipRecognitionRejectsAnUnallowlistedTwoHopRelay() throws {
    let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createNeovimStarshipPrerequisites()
    try fixture.createExternalNeovimThemeLink()
    try fixture.createUnallowlistedTwoHopStarshipLink()

    #expect(
      throws: SetupOwnershipError.conflictingThemeLink(
        "starship.configuration-link",
        fixture.starshipConfigurationLink
      )
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func starshipRecognitionRejectsTrailingSeparatorsInEitherHop() throws {
    for malformedHop in 0..<2 {
      let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
      defer { fixture.remove() }
      try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
      try fixture.createNeovimStarshipPrerequisites()
      try fixture.createExternalNeovimThemeLink()
      try fixture.createTwoHopStarshipLink(
        firstDestination:
          fixture.starshipFirstHopDestination + (malformedHop == 0 ? "/" : ""),
        secondDestination:
          fixture.starshipSecondHopDestination + (malformedHop == 1 ? "/" : "")
      )

      #expect(
        throws: SetupOwnershipError.conflictingThemeLink(
          "starship.configuration-link",
          fixture.starshipConfigurationLink
        )
      ) {
        _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    }
  }

  @Test
  func ownedLinksResumeAtTheirRecordedCreationBoundaries() throws {
    let neovim = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { neovim.remove() }
    try neovim.writeKittyConfiguration("\(neovim.includeDirective)\n")
    try neovim.createNeovimStarshipPrerequisites()
    let interruptedNeovim = SetupOwnershipManager { checkpoint in
      if checkpoint == .targetWritten { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedNeovim.setup(homeDirectory: neovim.home, dryRun: false)
    }
    let resumedNeovim = try SetupOwnershipManager().setup(
      homeDirectory: neovim.home,
      dryRun: false
    )
    #expect(
      resumedNeovim[12..<16].map(\.status)
        == [.external, .owned, .external, .owned]
    )

    let starship = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { starship.remove() }
    try starship.writeKittyConfiguration("\(starship.includeDirective)\n")
    try starship.createNeovimStarshipPrerequisites()
    try starship.createExternalNeovimThemeLink()
    let interruptedStarship = SetupOwnershipManager { checkpoint in
      if checkpoint == .manifestPrepared { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedStarship.setup(homeDirectory: starship.home, dryRun: false)
    }
    let resumedStarship = try SetupOwnershipManager().setup(
      homeDirectory: starship.home,
      dryRun: false
    )
    #expect(
      resumedStarship[12..<16].map(\.status)
        == [.external, .external, .external, .owned]
    )
  }

  @Test
  func teardownPreflightsBothOwnedLinksBeforeRemovingEither() throws {
    let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createNeovimStarshipPrerequisites()
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try FileManager.default.removeItem(at: fixture.neovimThemeLink)
    try Data("user-owned configuration\n".utf8).write(
      to: fixture.neovimThemeLink
    )

    #expect(throws: SetupOwnershipError.ownershipDrift(fixture.neovimThemeLink)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try fixture.linkDestination(fixture.starshipConfigurationLink)
        == fixture.starshipBridge.path
    )
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }
}

extension Fixture {
  var neovimWatcherConfiguration: URL {
    home.appending(path: ".config/nvim/lua/plugins/colorscheme.lua")
  }

  var neovimThemeLink: URL {
    home.appending(path: ".config/nvim/lua/macarchy/current.lua")
  }

  var neovimThemeDestination: URL {
    stateRoot.appending(path: "current/\(NeovimAdapter.outputPath)")
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

  var starshipStowLink: URL {
    home.appending(path: SetupOwnershipManager.starshipStowConfigurationRelativePath)
  }

  var starshipFirstHopDestination: String {
    SetupOwnershipManager.starshipStowFirstDestination
  }

  var starshipSecondHopDestination: String {
    SetupOwnershipManager.starshipStowSecondDestination
  }

  func createExternalNeovimStarshipSeams() throws {
    try createNeovimStarshipPrerequisites()
    try createExternalNeovimThemeLink()
    try createExternalTwoHopStarshipLink()
  }

  func createNeovimStarshipPrerequisites(
    watcher: String =
      "local macarchy = require(\"config.macarchy-theme\")\n"
      + "\(NeovimAdapter.integrationDirective)\n",
    behavior: String = "format = \"$directory$character\"\n"
  ) throws {
    try FileManager.default.createDirectory(
      at: neovimWatcherConfiguration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(watcher.utf8).write(to: neovimWatcherConfiguration)
    try FileManager.default.createDirectory(
      at: neovimThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: starshipBehavior.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(behavior.utf8).write(to: starshipBehavior)
  }

  func createExternalNeovimThemeLink() throws {
    try FileManager.default.createSymbolicLink(
      at: neovimThemeLink,
      withDestinationURL: neovimThemeDestination
    )
  }

  func createExternalTwoHopStarshipLink() throws {
    try createTwoHopStarshipLink(
      firstDestination: starshipFirstHopDestination,
      secondDestination: starshipSecondHopDestination
    )
  }

  func createTwoHopStarshipLink(
    firstDestination: String,
    secondDestination: String
  ) throws {
    try FileManager.default.createDirectory(
      at: starshipStowLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: starshipStowLink.path,
      withDestinationPath: secondDestination
    )
    try FileManager.default.createSymbolicLink(
      atPath: starshipConfigurationLink.path,
      withDestinationPath: firstDestination
    )
  }

  func createThreeHopStarshipLink() throws {
    let relay = starshipStowLink.deletingLastPathComponent()
      .appending(path: "starship-relay.toml")
    try FileManager.default.createDirectory(
      at: starshipStowLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: relay, withDestinationURL: starshipBridge)
    try FileManager.default.createSymbolicLink(
      at: starshipStowLink,
      withDestinationURL: relay
    )
    try FileManager.default.createSymbolicLink(
      atPath: starshipConfigurationLink.path,
      withDestinationPath: starshipFirstHopDestination
    )
  }

  func createUnallowlistedTwoHopStarshipLink() throws {
    let relay = home.appending(path: "unrelated/starship.toml")
    try FileManager.default.createDirectory(
      at: relay.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: relay,
      withDestinationURL: starshipBridge
    )
    try FileManager.default.createSymbolicLink(
      at: starshipConfigurationLink,
      withDestinationURL: relay
    )
  }
}

private struct NeovimStarshipManifest: Decodable {
  let records: [Record]

  struct Record: Decodable {
    let id: String
  }
}
