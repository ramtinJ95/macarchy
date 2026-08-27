import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct BtopYaziAtuinSetupTests {
  @Test
  func exactExternalSeamsRemainUnclaimedInCentralOrder() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try Data(
      "[flavor]\nlayout = [\n  [\"name\"]\n]\ndark = \"macarchy-current\"\n".utf8
    ).write(to: fixture.yaziConfiguration)

    let results = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)

    #expect(
      results.map(\.id)
        == [
          "kitty.include",
          "bat.selector",
          "bat.theme-link",
          "eza.environment",
          "eza.theme-link",
          "btop.selector",
          "btop.theme-link",
          "yazi.selector",
          "yazi.flavor-link",
          "yazi.syntax-link",
          "atuin.selector",
          "atuin.theme-link",
          "neovim.watcher",
          "neovim.theme-link",
          "starship.behavior",
          "starship.configuration-link",
          "pi.selector",
          "pi.theme-link",
          "herdr.selector",
          "tuicr.selector",
          "tuicr.theme-link",
          "tuicr.syntax-link",
          "codex.selector",
          "codex.theme-link",
          "spicetify.selectors",
          "spicetify.color-link",
        ]
    )
    #expect(results.prefix(24).allSatisfy { $0.status == .external && !$0.mutationAttempted })
    #expect(results.suffix(2).allSatisfy { $0.status == .disabled && !$0.mutationAttempted })
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func ownedBatchPreservesUnrelatedConfigurationAndRoundTrips() throws {
    let fixture = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let btop = "# personal btop settings\n\(BtopAdapter.themeDirective)\n"
    let yazi = "[mgr]\r\nratio = [1, 2, 3]\r\n\r\n[flavor]\r\nlight = \"default\"\r\n"
    let atuin = "sync_address = \"https://api.atuin.sh\"\n"
    try fixture.createLocalBtopYaziAtuinConfigurations(btop: btop, yazi: yazi, atuin: atuin)

    let preview = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    #expect(preview.prefix(5).allSatisfy { $0.status == .external })
    #expect(
      preview[5..<12].map(\.status)
        == [.external, .planned, .planned, .planned, .planned, .planned, .planned]
    )
    #expect(preview[12..<24].allSatisfy { $0.status == .external })
    #expect(preview.suffix(2).allSatisfy { $0.status == .disabled })
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))

    let setup = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)

    #expect(setup.prefix(5).allSatisfy { $0.status == .external })
    #expect(
      setup[5..<12].map(\.status)
        == [.external, .owned, .owned, .owned, .owned, .owned, .owned]
    )
    #expect(setup[12..<24].allSatisfy { $0.status == .external })
    #expect(setup.suffix(2).allSatisfy { $0.status == .disabled })
    #expect(try String(contentsOf: fixture.btopConfiguration, encoding: .utf8) == btop)
    #expect(
      try String(contentsOf: fixture.yaziConfiguration, encoding: .utf8)
        == "[mgr]\r\nratio = [1, 2, 3]\r\n\r\n[flavor]\r\ndark = \"macarchy-current\"\r\nlight = \"default\"\r\n"
    )
    #expect(
      try String(contentsOf: fixture.atuinConfiguration, encoding: .utf8)
        == atuin + "[theme]\nname = \"macarchy-current\"\n"
    )
    #expect(try fixture.linkDestination(fixture.btopThemeLink) == fixture.btopThemeDestination.path)
    #expect(
      try fixture.linkDestination(fixture.yaziFlavorLink) == fixture.yaziFlavorDestination.path)
    #expect(
      try fixture.linkDestination(fixture.yaziSyntaxLink) == fixture.yaziSyntaxDestination.path)
    #expect(
      try fixture.linkDestination(fixture.atuinThemeLink) == fixture.atuinThemeDestination.path)
    #expect(try fixture.permissions(at: fixture.yaziSelectorBackup) == 0o600)
    #expect(try fixture.permissions(at: fixture.atuinSelectorBackup) == 0o600)

    let teardown = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)

    #expect(teardown.prefix(5).allSatisfy { $0.status == .none })
    #expect(
      teardown[5..<12].map(\.status)
        == [.none, .removed, .removed, .removed, .removed, .removed, .removed]
    )
    #expect(teardown.dropFirst(12).allSatisfy { $0.status == .none })
    #expect(try String(contentsOf: fixture.btopConfiguration, encoding: .utf8) == btop)
    #expect(try String(contentsOf: fixture.yaziConfiguration, encoding: .utf8) == yazi)
    #expect(try String(contentsOf: fixture.atuinConfiguration, encoding: .utf8) == atuin)
    #expect(!FileManager.default.fileExists(atPath: fixture.btopThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.yaziFlavorLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.yaziSyntaxLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.atuinThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func tomlSelectorsRejectWrongAndDuplicateAssignmentsWithoutMutation() throws {
    let wrong = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { wrong.remove() }
    try wrong.writeKittyConfiguration("\(wrong.includeDirective)\n")
    let wrongYazi = "[flavor]\ndark = \"catppuccin\"\n"
    try wrong.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: wrongYazi,
      atuin: "[theme]\nname = \"macarchy-current\"\n"
    )

    do {
      _ = try SetupOwnershipManager().setup(homeDirectory: wrong.home, dryRun: true)
      Issue.record("Expected the conflicting Yazi selector to fail")
    } catch let error as SetupOwnershipError {
      #expect(error == .conflictingDirective("yazi.selector", wrong.yaziConfiguration))
    }
    #expect(try String(contentsOf: wrong.yaziConfiguration, encoding: .utf8) == wrongYazi)
    #expect(!FileManager.default.fileExists(atPath: wrong.manifest.path))

    let duplicate = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { duplicate.remove() }
    try duplicate.writeKittyConfiguration("\(duplicate.includeDirective)\n")
    let duplicateAtuin = "[theme]\nname = \"macarchy-current\"\nname = \"other\"\n"
    try duplicate.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: "[flavor]\ndark = \"macarchy-current\"\n",
      atuin: duplicateAtuin
    )

    do {
      _ = try SetupOwnershipManager().setup(homeDirectory: duplicate.home, dryRun: true)
      Issue.record("Expected duplicate Atuin TOML keys to fail")
    } catch SetupOwnershipError.invalidConfiguration(let id, let target, _) {
      #expect(id == "atuin.selector")
      #expect(target == duplicate.atuinConfiguration)
    }
    #expect(try String(contentsOf: duplicate.atuinConfiguration, encoding: .utf8) == duplicateAtuin)
    #expect(!FileManager.default.fileExists(atPath: duplicate.manifest.path))

    let dotted = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { dotted.remove() }
    try dotted.writeKittyConfiguration("\(dotted.includeDirective)\n")
    let dottedYazi = "flavor.dark = \"macarchy-current\"\n"
    try dotted.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: dottedYazi,
      atuin: "[theme]\nname = \"macarchy-current\"\n"
    )

    do {
      _ = try SetupOwnershipManager().setup(homeDirectory: dotted.home, dryRun: true)
      Issue.record("Expected a noncanonical Yazi selector to fail")
    } catch let error as SetupOwnershipError {
      #expect(error == .conflictingDirective("yazi.selector", dotted.yaziConfiguration))
    }
    #expect(try String(contentsOf: dotted.yaziConfiguration, encoding: .utf8) == dottedYazi)
    #expect(!FileManager.default.fileExists(atPath: dotted.manifest.path))
  }

  @Test
  func btopSelectorMustRemainExternallyOwned() throws {
    let fixture = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBtopYaziAtuinConfigurations(
      btop: "update_ms = 1500\n",
      yazi: "[flavor]\ndark = \"macarchy-current\"\n",
      atuin: "[theme]\nname = \"macarchy-current\"\n"
    )

    #expect(
      throws: SetupOwnershipError.missingExternalDirective(
        "btop.selector",
        fixture.btopConfiguration
      )
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(
      try String(contentsOf: fixture.btopConfiguration, encoding: .utf8) == "update_ms = 1500\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func missingYaziFlavorDirectoryFailsAsAnExternalPrerequisite() throws {
    let fixture = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: "[flavor]\ndark = \"macarchy-current\"\n",
      atuin: "[theme]\nname = \"macarchy-current\"\n"
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.btopThemeLink,
      withDestinationURL: fixture.btopThemeDestination
    )
    let flavorDirectory = fixture.yaziFlavorLink.deletingLastPathComponent()
    try FileManager.default.removeItem(at: flavorDirectory)

    do {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
      Issue.record("Expected the missing Yazi flavor directory to fail")
    } catch SetupOwnershipError.missingIntegrationParent(let id, let url) {
      #expect(id == "yazi.flavor-link")
      #expect(url.path == flavorDirectory.path)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func selectorInsertionCannotExceedTheReadableConfigurationLimit() throws {
    let fixture = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let prefix = "[flavor]\n#"
    let yazi = prefix + String(repeating: "x", count: 1_048_576 - prefix.utf8.count)
    try fixture.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: yazi,
      atuin: "[theme]\nname = \"macarchy-current\"\n"
    )
    try fixture.createBtopYaziAtuinThemeLinks()

    #expect(
      throws: SetupOwnershipError.installedConfigurationTooLarge(
        "yazi.selector",
        fixture.yaziConfiguration
      )
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(try Data(contentsOf: fixture.yaziConfiguration).count == 1_048_576)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func interruptedTOMLSelectorReproducesAndResumesFromBackup() throws {
    let fixture = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: "[flavor]\nlight = \"default\"\n",
      atuin: "[theme]\nname = \"macarchy-current\"\n"
    )
    try fixture.createBtopYaziAtuinThemeLinks()
    let interrupted = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
    }
    let resumed = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)

    #expect(
      resumed[5..<12].map(\.status)
        == [.external, .external, .owned, .external, .external, .external, .external]
    )
    #expect(resumed[12..<24].allSatisfy { $0.status == .external })
    #expect(resumed.suffix(2).allSatisfy { $0.status == .disabled })
    #expect(
      try String(contentsOf: fixture.yaziConfiguration, encoding: .utf8)
        == "[flavor]\ndark = \"macarchy-current\"\nlight = \"default\"\n"
    )
  }

  @Test
  func teardownPreflightsTheWholeBatchBeforeRemovingAnySeam() throws {
    let fixture = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: "[flavor]\nlight = \"default\"\n",
      atuin: "sync_frequency = \"5m\"\n"
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try Data("user changed this file\n".utf8).write(
      to: fixture.yaziConfiguration,
      options: .atomic
    )

    #expect(throws: SetupOwnershipError.ownershipDrift(fixture.yaziConfiguration)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try fixture.linkDestination(fixture.atuinThemeLink) == fixture.atuinThemeDestination.path)
    #expect(try fixture.linkDestination(fixture.btopThemeLink) == fixture.btopThemeDestination.path)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }
}
