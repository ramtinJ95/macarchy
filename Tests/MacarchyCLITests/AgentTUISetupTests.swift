import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct AgentTUISetupTests {
  private let integrationIDs = [
    "pi.selector",
    "pi.theme-link",
    "herdr.selector",
    "tuicr.selector",
    "tuicr.theme-link",
    "tuicr.syntax-link",
    "codex.selector",
    "codex.theme-link",
  ]
  private let ownedIntegrationIDs = [
    "pi.selector",
    "pi.theme-link",
    "tuicr.selector",
    "tuicr.theme-link",
    "tuicr.syntax-link",
    "codex.selector",
    "codex.theme-link",
  ]

  @Test
  func exactSymlinkOwnedSeamsRemainExternalAndUnclaimed() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")

    let results = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let agentResults = Array(results.dropLast(2).suffix(integrationIDs.count))

    #expect(agentResults.map(\.id) == integrationIDs)
    #expect(agentResults.allSatisfy { $0.status == .external && !$0.mutationAttempted })
    #expect(try fixture.linkDestination(fixture.piThemeLink) == fixture.piThemeDestination.path)
    #expect(
      try fixture.linkDestination(fixture.tuicrThemeLink)
        == fixture.tuicrThemeDestination.path)
    #expect(
      try fixture.linkDestination(fixture.tuicrSyntaxLink)
        == fixture.tuicrSyntaxDestination.path)
    #expect(
      try fixture.linkDestination(fixture.codexThemeLink)
        == fixture.codexThemeDestination.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func ownedSeamsPreserveUnrelatedBytesAndRoundTripAsOneManifestGroup() throws {
    let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let pi =
      "{\r\n  \"provider\": \"openai\",\r\n  \"nested\": {\"theme\": \"preserve\"}\r\n}\r\n"
    let tuicr = "show_help = true\r\n"
    let codex = "model = \"gpt-5\"\r\n\r\n[tui]\r\nanimations = false\r\n"
    try fixture.createLocalAgentTUIConfigurations(pi: pi, tuicr: tuicr, codex: codex)

    let preview = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    #expect(preview.prefix(12).allSatisfy { $0.status == .external })
    #expect(
      preview.dropLast(2).suffix(8).map(\.status)
        == [.planned, .planned, .external, .planned, .planned, .planned, .planned, .planned]
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))

    let setup = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let manifest = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest))
        as? [String: Any]
    )
    let records = try #require(manifest["records"] as? [[String: Any]])

    #expect(setup.prefix(12).allSatisfy { $0.status == .external })
    #expect(
      setup.dropLast(2).suffix(8).map(\.status)
        == [.owned, .owned, .external, .owned, .owned, .owned, .owned, .owned]
    )
    #expect(
      setup.dropLast(2).suffix(8).filter { $0.id != "herdr.selector" }.allSatisfy {
        $0.mutationAttempted
      }
    )
    #expect(manifest["schema_version"] as? Int == 1)
    #expect(Set(records.compactMap { $0["id"] as? String }) == Set(ownedIntegrationIDs))
    let piRecord = try #require(records.first { $0["id"] as? String == "pi.selector" })
    #expect(piRecord["kind"] as? String == "json_selector")
    #expect(piRecord["backup_path"] == nil)
    #expect(
      try String(contentsOf: fixture.piConfiguration, encoding: .utf8)
        == "{\r\n  \"theme\": \"macarchy-current\",\r\n  \"provider\": \"openai\",\r\n  \"nested\": {\"theme\": \"preserve\"}\r\n}\r\n"
    )
    #expect(
      try String(contentsOf: fixture.tuicrConfiguration, encoding: .utf8)
        == "theme = \"macarchy-current\"\r\n" + tuicr
    )
    #expect(
      try String(contentsOf: fixture.codexConfiguration, encoding: .utf8)
        == "model = \"gpt-5\"\r\n\r\n[tui]\r\ntheme = \"macarchy-current\"\r\nanimations = false\r\n"
    )
    #expect(try fixture.linkDestination(fixture.piThemeLink) == fixture.piThemeDestination.path)
    #expect(
      try fixture.linkDestination(fixture.tuicrThemeLink)
        == fixture.tuicrThemeDestination.path)
    #expect(
      try fixture.linkDestination(fixture.tuicrSyntaxLink)
        == fixture.tuicrSyntaxDestination.path)
    #expect(
      try fixture.linkDestination(fixture.codexThemeLink)
        == fixture.codexThemeDestination.path)
    #expect(try fixture.permissions(at: fixture.tuicrSelectorBackup) == 0o600)
    #expect(try fixture.permissions(at: fixture.codexSelectorBackup) == 0o600)

    let providerRewrite =
      "{\n  \"lastChangelogVersion\": \"9.9.9\",\n  \"theme\": \"macarchy-current\",\n  \"provider\": \"anthropic\"\n}\n"
    try Data(providerRewrite.utf8).write(to: fixture.piConfiguration, options: .atomic)
    let repeated = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    #expect(
      repeated.dropLast(2).suffix(8).map(\.status)
        == [.owned, .owned, .external, .owned, .owned, .owned, .owned, .owned]
    )
    #expect(!repeated.dropLast(2).suffix(8).contains { $0.mutationAttempted })

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(teardown.prefix(12).allSatisfy { $0.status == .none })
    #expect(
      teardown.dropLast(2).suffix(8).map(\.status)
        == [.removed, .removed, .none, .removed, .removed, .removed, .removed, .removed]
    )
    #expect(
      try String(contentsOf: fixture.piConfiguration, encoding: .utf8)
        == "{\n  \"lastChangelogVersion\": \"9.9.9\",\n  \"provider\": \"anthropic\"\n}\n"
    )
    #expect(try String(contentsOf: fixture.tuicrConfiguration, encoding: .utf8) == tuicr)
    #expect(try String(contentsOf: fixture.codexConfiguration, encoding: .utf8) == codex)
    #expect(try fixture.pathIsMissing(fixture.piThemeLink))
    #expect(try fixture.pathIsMissing(fixture.tuicrThemeLink))
    #expect(try fixture.pathIsMissing(fixture.tuicrSyntaxLink))
    #expect(try fixture.pathIsMissing(fixture.codexThemeLink))
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func piSelectorRejectsDuplicateTopLevelKeysWithoutMutation() throws {
    let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let pi =
      "{\n  \"theme\": \"macarchy-current\",\n  \"theme\": \"macarchy-current\"\n}\n"
    try fixture.createLocalAgentTUIConfigurations(
      pi: pi,
      tuicr: "theme = \"macarchy-current\"\n",
      codex: "[tui]\ntheme = \"macarchy-current\"\n"
    )
    try fixture.createAgentTUIThemeLinks()

    do {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
      Issue.record("Expected duplicate Pi keys to fail")
    } catch SetupOwnershipError.invalidConfiguration(let id, let target, let reason) {
      #expect(id == "pi.selector")
      #expect(target == fixture.piConfiguration)
      #expect(reason == "duplicate top-level JSON key \"theme\"")
    }
    #expect(try String(contentsOf: fixture.piConfiguration, encoding: .utf8) == pi)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func piSelectorResumesInterruptedKeyInsertionAndRemoval() throws {
    let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let original = "{\n  \"provider\": \"openai\"\n}\n"
    try fixture.createLocalAgentTUIConfigurations(
      pi: original,
      tuicr: "theme = \"macarchy-current\"\n",
      codex: "[tui]\ntheme = \"macarchy-current\"\n"
    )
    try fixture.createAgentTUIThemeLinks()
    let interruptedSetup = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedSetup.setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try fixture.pathIsMissing(fixture.piSelectorReplacement) == false)

    let resumed = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    #expect(resumed.first { $0.id == "pi.selector" }?.status == .owned)
    #expect(try fixture.pathIsMissing(fixture.piSelectorReplacement))

    let interruptedTeardown = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw FixtureError.interrupted }
    }
    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedTeardown.teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try fixture.pathIsMissing(fixture.piSelectorReplacement) == false)

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )
    #expect(teardown.first { $0.id == "pi.selector" }?.status == .removed)
    #expect(try String(contentsOf: fixture.piConfiguration, encoding: .utf8) == original)
    #expect(try fixture.pathIsMissing(fixture.piSelectorReplacement))
  }

  @Test
  func piSelectorRejectsEquivalentButNoncanonicalKeySpelling() throws {
    let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let pi = "{\"th\\u0065me\": \"macarchy-current\"}\n"
    try fixture.createLocalAgentTUIConfigurations(
      pi: pi,
      tuicr: "theme = \"macarchy-current\"\n",
      codex: "[tui]\ntheme = \"macarchy-current\"\n"
    )
    try fixture.createAgentTUIThemeLinks()

    #expect(
      throws: SetupOwnershipError.conflictingDirective(
        "pi.selector",
        fixture.piConfiguration
      )
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(try String(contentsOf: fixture.piConfiguration, encoding: .utf8) == pi)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func piSelectorRejectsTrailingCommasAtEveryNestedContainerBoundary() throws {
    let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { fixture.remove() }
    let documents = [
      ("{\"theme\": \"macarchy-current\",}\n", "trailing comma in JSON object"),
      (
        "{\"theme\": \"macarchy-current\", \"provider\": {\"name\": \"test\",}}\n",
        "trailing comma in JSON object"
      ),
      (
        "{\"theme\": \"macarchy-current\", \"models\": [\"one\",]}\n",
        "trailing comma in JSON array"
      ),
    ]

    for (document, expectedReason) in documents {
      do {
        _ = try SetupOwnershipManager().jsonSelectionIsExternal(
          Data(document.utf8),
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: "pi.selector",
          target: fixture.piConfiguration
        )
        Issue.record("Expected a trailing JSON comma to fail")
      } catch SetupOwnershipError.invalidConfiguration(_, _, let reason) {
        #expect(reason == expectedReason)
      }
    }
  }

  @Test
  func piSelectorRejectsDuplicateKeysInsideNestedObjects() throws {
    let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { fixture.remove() }
    let document =
      "{\"theme\": \"macarchy-current\", \"provider\": {\"name\": \"one\", \"name\": \"two\"}}\n"

    do {
      _ = try SetupOwnershipManager().jsonSelectionIsExternal(
        Data(document.utf8),
        key: PiAdapter.selectionKey,
        value: PiAdapter.themeName,
        id: "pi.selector",
        target: fixture.piConfiguration
      )
      Issue.record("Expected a nested duplicate JSON key to fail")
    } catch SetupOwnershipError.invalidConfiguration(_, _, let reason) {
      #expect(reason == "duplicate JSON key \"name\"")
    }
  }

  @Test
  func herdrSelectorMustRemainValidAndAdapterManaged() throws {
    for configuration in [
      "[theme]\nauto_switch = true\n",
      "[theme]\nname = [\"not-a-string\"]\n",
    ] {
      let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
      defer { fixture.remove() }
      try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
      try fixture.createLocalAgentTUIConfigurations(
        pi: "{\"theme\": \"macarchy-current\"}\n",
        herdr: configuration,
        tuicr: "theme = \"macarchy-current\"\n",
        codex: "[tui]\ntheme = \"macarchy-current\"\n"
      )
      try fixture.createAgentTUIThemeLinks()

      do {
        _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
        Issue.record("Expected invalid Herdr configuration to fail")
      } catch SetupOwnershipError.invalidConfiguration(let id, let target, _) {
        #expect(id == "herdr.selector")
        #expect(target == fixture.herdrConfiguration)
      }
    }
  }

  @Test
  func staticTOMLSelectorsRejectEquivalentAndDuplicateShapes() throws {
    let tuicrFixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { tuicrFixture.remove() }
    try tuicrFixture.writeKittyConfiguration("\(tuicrFixture.includeDirective)\n")
    let tuicr = "theme = 'macarchy-current'\n"
    try tuicrFixture.createLocalAgentTUIConfigurations(
      pi: "{\"theme\": \"macarchy-current\"}\n",
      tuicr: tuicr,
      codex: "[tui]\ntheme = \"macarchy-current\"\n"
    )
    try tuicrFixture.createAgentTUIThemeLinks()

    #expect(
      throws: SetupOwnershipError.conflictingDirective(
        "tuicr.selector",
        tuicrFixture.tuicrConfiguration
      )
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: tuicrFixture.home, dryRun: true)
    }
    #expect(try String(contentsOf: tuicrFixture.tuicrConfiguration, encoding: .utf8) == tuicr)

    let codexFixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { codexFixture.remove() }
    try codexFixture.writeKittyConfiguration("\(codexFixture.includeDirective)\n")
    let codex = "[tui]\ntheme = \"macarchy-current\"\ntheme = \"other\"\n"
    try codexFixture.createLocalAgentTUIConfigurations(
      pi: "{\"theme\": \"macarchy-current\"}\n",
      tuicr: "theme = \"macarchy-current\"\n",
      codex: codex
    )
    try codexFixture.createAgentTUIThemeLinks()

    do {
      _ = try SetupOwnershipManager().setup(homeDirectory: codexFixture.home, dryRun: true)
      Issue.record("Expected duplicate Codex TOML keys to fail")
    } catch SetupOwnershipError.invalidConfiguration(let id, let target, _) {
      #expect(id == "codex.selector")
      #expect(target == codexFixture.codexConfiguration)
    }
    #expect(try String(contentsOf: codexFixture.codexConfiguration, encoding: .utf8) == codex)
  }

  @Test
  func codexSelectorInsertionPreservesCRLFWithoutAnExistingTUITable() throws {
    let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { fixture.remove() }
    let manager = SetupOwnershipManager()

    let absent = Data("model = \"gpt-5\"\r\n".utf8)
    let appended = try manager.addingTOMLSelection(
      to: absent,
      table: CodexAdapter.selectionTable,
      key: CodexAdapter.selectionKey,
      value: CodexAdapter.themeName,
      id: "codex.selector",
      target: fixture.codexConfiguration
    )
    #expect(
      String(decoding: appended, as: UTF8.self)
        == "model = \"gpt-5\"\r\n[tui]\r\ntheme = \"macarchy-current\"\r\n"
    )

    let finalHeader = Data("model = \"gpt-5\"\r\n[tui]".utf8)
    let inserted = try manager.addingTOMLSelection(
      to: finalHeader,
      table: CodexAdapter.selectionTable,
      key: CodexAdapter.selectionKey,
      value: CodexAdapter.themeName,
      id: "codex.selector",
      target: fixture.codexConfiguration
    )
    #expect(
      String(decoding: inserted, as: UTF8.self)
        == "model = \"gpt-5\"\r\n[tui]\r\ntheme = \"macarchy-current\"\r\n"
    )
  }
}

extension Fixture {
  var piConfiguration: URL {
    home.appending(path: ".pi/agent/settings.json")
  }

  var piThemeLink: URL {
    home.appending(path: ".pi/agent/themes/\(PiAdapter.themeName).json")
  }

  var piThemeDestination: URL {
    stateRoot.appending(path: "current/\(PiAdapter.outputPath)")
  }

  var piSelectorReplacement: URL {
    piConfiguration.deletingLastPathComponent()
      .appending(path: ".macarchy-pi-settings-transaction")
  }

  var herdrConfiguration: URL {
    home.appending(path: ".config/herdr/config.toml")
  }

  var tuicrConfiguration: URL {
    home.appending(path: ".config/tuicr/config.toml")
  }

  var tuicrThemeLink: URL {
    home.appending(path: ".config/tuicr/themes/\(TuicrAdapter.themeName).toml")
  }

  var tuicrThemeDestination: URL {
    stateRoot.appending(path: "current/\(TuicrAdapter.outputPath)")
  }

  var tuicrSyntaxLink: URL {
    home.appending(path: ".config/tuicr/themes/\(TuicrAdapter.themeName).tmTheme")
  }

  var tuicrSyntaxDestination: URL {
    stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
  }

  var codexConfiguration: URL {
    home.appending(path: ".codex/config.toml")
  }

  var codexThemeLink: URL {
    home.appending(path: ".codex/themes/\(CodexAdapter.themeName).tmTheme")
  }

  var codexThemeDestination: URL {
    stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
  }

  var tuicrSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/tuicr-config.toml")
  }

  var codexSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/codex-config.toml")
  }

  func createLocalAgentTUIConfigurations(
    pi: String,
    herdr: String = "[theme]\nname = \"catppuccin\"\nauto_switch = false\n",
    tuicr: String,
    codex: String
  ) throws {
    try FileManager.default.createDirectory(
      at: piThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(pi.utf8).write(to: piConfiguration)
    try FileManager.default.createDirectory(
      at: herdrConfiguration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(herdr.utf8).write(to: herdrConfiguration)
    try FileManager.default.createDirectory(
      at: tuicrThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(tuicr.utf8).write(to: tuicrConfiguration)
    try FileManager.default.createDirectory(
      at: codexThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(codex.utf8).write(to: codexConfiguration)
  }

  func createAgentTUIThemeLinks() throws {
    try FileManager.default.createSymbolicLink(
      at: piThemeLink,
      withDestinationURL: piThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrThemeLink,
      withDestinationURL: tuicrThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrSyntaxLink,
      withDestinationURL: tuicrSyntaxDestination
    )
    try FileManager.default.createSymbolicLink(
      at: codexThemeLink,
      withDestinationURL: codexThemeDestination
    )
  }

  func createExternalAgentTUISeams() throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let dotfiles = root.appending(path: "dotfiles/agent-tuis")

    let pi = dotfiles.appending(path: "pi")
    let piThemes = pi.appending(path: "agent/themes")
    try FileManager.default.createDirectory(at: piThemes, withIntermediateDirectories: true)
    try Data("{\n  \"theme\": \"\(PiAdapter.themeName)\"\n}\n".utf8).write(
      to: pi.appending(path: "agent/settings.json")
    )
    try FileManager.default.createSymbolicLink(
      at: piThemes.appending(path: "\(PiAdapter.themeName).json"),
      withDestinationURL: piThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: ".pi"),
      withDestinationURL: pi
    )

    let configurationRoot = home.appending(path: ".config")
    try FileManager.default.createDirectory(
      at: configurationRoot,
      withIntermediateDirectories: true
    )
    let tuicrHome = configurationRoot.appending(path: "tuicr")
    try FileManager.default.createDirectory(at: tuicrHome, withIntermediateDirectories: true)
    let tuicr = dotfiles.appending(path: "tuicr")
    let tuicrThemes = tuicr.appending(path: "themes")
    try FileManager.default.createDirectory(at: tuicrThemes, withIntermediateDirectories: true)
    try Data("theme = \"\(TuicrAdapter.themeName)\"\n".utf8).write(
      to: tuicr.appending(path: "config.toml")
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrThemes.appending(path: "\(TuicrAdapter.themeName).toml"),
      withDestinationURL: tuicrThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrThemes.appending(path: "\(TuicrAdapter.themeName).tmTheme"),
      withDestinationURL: tuicrSyntaxDestination
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrHome.appending(path: "config.toml"),
      withDestinationURL: tuicr.appending(path: "config.toml")
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrHome.appending(path: "themes"),
      withDestinationURL: tuicrThemes
    )

    let herdr = dotfiles.appending(path: "herdr")
    try FileManager.default.createDirectory(at: herdr, withIntermediateDirectories: true)
    try Data("[theme]\nname = \"catppuccin\"\nauto_switch = false\n".utf8).write(
      to: herdr.appending(path: "config.toml")
    )
    try FileManager.default.createSymbolicLink(
      at: configurationRoot.appending(path: "herdr"),
      withDestinationURL: herdr
    )

    let codexHome = home.appending(path: ".codex")
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let codex = dotfiles.appending(path: "codex")
    let codexThemes = codex.appending(path: "themes")
    try FileManager.default.createDirectory(at: codexThemes, withIntermediateDirectories: true)
    try Data("[tui]\ntheme = \"\(CodexAdapter.themeName)\"\n".utf8).write(
      to: codex.appending(path: "config.toml")
    )
    try FileManager.default.createSymbolicLink(
      at: codexThemes.appending(path: "\(CodexAdapter.themeName).tmTheme"),
      withDestinationURL: codexThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: codexHome.appending(path: "config.toml"),
      withDestinationURL: codex.appending(path: "config.toml")
    )
    try FileManager.default.createSymbolicLink(
      at: codexHome.appending(path: "themes"),
      withDestinationURL: codexThemes
    )
  }

  func pathIsMissing(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return false }
    guard errno == ENOENT else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return true
  }
}
