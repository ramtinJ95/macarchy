import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct SetupOwnershipTests {
  @Test
  func correctStowOwnedKittyIncludeRemainsExternalAndUnclaimed() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let externalKitty = fixture.root.appending(path: "dotfiles/kitty")
    try FileManager.default.createDirectory(
      at: externalKitty,
      withIntermediateDirectories: true
    )
    let original = "font_size 13\r\n\(fixture.includeDirective)\r\n"
    try Data(original.utf8).write(to: externalKitty.appending(path: "kitty.conf"))
    try FileManager.default.createDirectory(
      at: fixture.home.appending(path: ".config"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.home.appending(path: ".config/kitty"),
      withDestinationURL: externalKitty
    )

    let results = try SetupOwnershipManager().setup(
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(
      results.map(\.status)
        == Array(repeating: .external, count: 24) + Array(repeating: .disabled, count: 2)
    )
    #expect(!results.contains { $0.mutationAttempted })
    #expect(try fixture.configuration() == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func exactStowOwnedBatAndEzaSeamsRemainExternalAndUnclaimed() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let dotfiles = fixture.root.appending(path: "dotfiles")
    let bat = dotfiles.appending(path: "bat")
    let batThemes = bat.appending(path: "themes")
    try FileManager.default.createDirectory(at: batThemes, withIntermediateDirectories: true)
    try Data("\(fixture.batDirective)\n".utf8).write(to: bat.appending(path: "config"))
    try FileManager.default.createSymbolicLink(
      at: batThemes.appending(path: BatAdapter.themeFileName),
      withDestinationURL: fixture.batThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.home.appending(path: ".config/bat"),
      withDestinationURL: bat
    )

    let zsh = dotfiles.appending(path: "zshrc")
    try Data("\(fixture.ezaDirective)\n".utf8).write(to: zsh)
    try FileManager.default.createSymbolicLink(
      at: fixture.shellConfiguration, withDestinationURL: zsh)
    let eza = dotfiles.appending(path: "eza")
    try FileManager.default.createDirectory(at: eza, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: eza.appending(path: "theme.yml"),
      withDestinationURL: fixture.ezaThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.home.appending(path: ".config/eza"),
      withDestinationURL: eza
    )

    let results = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)

    #expect(
      results.map(\.status)
        == Array(repeating: .external, count: 24) + Array(repeating: .disabled, count: 2)
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(try fixture.batConfigurationText() == "\(fixture.batDirective)\n")
    #expect(try fixture.shellConfigurationText() == "\(fixture.ezaDirective)\n")
  }

  @Test
  func missingSelectorInStowOwnedBatConfigurationReportsTheExactSeam() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let externalBat = fixture.root.appending(path: "dotfiles/bat")
    try FileManager.default.createDirectory(at: externalBat, withIntermediateDirectories: true)
    try Data("--italic-text=always\n".utf8).write(to: externalBat.appending(path: "config"))
    try FileManager.default.createSymbolicLink(
      at: fixture.home.appending(path: ".config/bat"),
      withDestinationURL: externalBat
    )

    let execution = try setupRunner(ownershipManager: SetupOwnershipManager()).execute(
      profileName: "personal",
      homeDirectory: fixture.home,
      installDependencies: false,
      dryRun: false,
      json: true
    )
    let report = try decode(SetupReport.self, execution.output)

    #expect(!execution.succeeded)
    #expect(report.outcome == "integration_failed")
    #expect(report.integrations.map(\.id) == ["bat.selector"])
    #expect(report.integrations.map(\.status) == ["failed"])
    #expect(report.integrations.first?.target == fixture.batConfiguration.path)
    #expect(report.integrations.first?.mutationAttempted == false)
    #expect(try fixture.batConfigurationText() == "--italic-text=always\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func setupReportsEarlierMutationWhenALaterThemeLinkConflicts() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "--italic-text=always\n",
      shell: "\(fixture.ezaDirective)\n"
    )
    try Data("user-owned theme\n".utf8).write(to: fixture.batThemeLink)

    let execution = try setupRunner(ownershipManager: SetupOwnershipManager()).execute(
      profileName: "personal",
      homeDirectory: fixture.home,
      installDependencies: false,
      dryRun: false,
      json: true
    )
    let report = try decode(SetupReport.self, execution.output)

    #expect(!execution.succeeded)
    #expect(report.outcome == "integration_failed")
    #expect(report.mutationAttempted)
    #expect(
      report.integrations.map(\.id)
        == ["kitty.include", "bat.selector", "bat.theme-link"]
    )
    #expect(report.integrations.map(\.status) == ["external", "owned", "failed"])
    #expect(report.integrations.map(\.mutationAttempted) == [false, true, false])
    #expect(try fixture.batConfigurationText().contains(fixture.batDirective))
    #expect(try String(contentsOf: fixture.batThemeLink, encoding: .utf8) == "user-owned theme\n")
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func batAndEzaOwnedSeamsRoundTripTogether() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "--italic-text=always\n",
      shell: "export EDITOR=nvim\n"
    )
    let cacheSentinel = fixture.home.appending(path: ".cache/bat/preserve")
    try FileManager.default.createDirectory(
      at: cacheSentinel.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("cache".utf8).write(to: cacheSentinel)

    let preview = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    #expect(
      preview.map(\.status)
        == [.external, .planned, .planned, .planned, .planned]
        + Array(repeating: .external, count: 19)
        + Array(repeating: .disabled, count: 2)
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))

    let setup = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let manifest = try decode(
      OwnershipManifest.self,
      String(decoding: Data(contentsOf: fixture.manifest), as: UTF8.self)
    )

    #expect(
      setup.map(\.status)
        == [.external, .owned, .owned, .owned, .owned]
        + Array(repeating: .external, count: 19)
        + Array(repeating: .disabled, count: 2)
    )
    #expect(manifest.schemaVersion == 1)
    #expect(
      manifest.records.map(\.id)
        == ["bat.selector", "bat.theme-link", "eza.environment", "eza.theme-link"]
    )
    #expect(manifest.records.allSatisfy { $0.phase == "applied" })
    #expect(
      try fixture.batConfigurationText()
        == "--italic-text=always\n\(fixture.batDirective)\n"
    )
    #expect(
      try fixture.shellConfigurationText()
        == "export EDITOR=nvim\n\(fixture.ezaDirective)\n"
    )
    #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    #expect(try fixture.linkDestination(fixture.ezaThemeLink) == fixture.ezaThemeDestination.path)
    #expect(try fixture.permissions(at: fixture.batSelectorBackup) == 0o600)
    #expect(try fixture.permissions(at: fixture.ezaEnvironmentBackup) == 0o600)

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(
      teardown.map(\.status)
        == [.none, .removed, .removed, .removed, .removed]
        + Array(repeating: .none, count: 21)
    )
    #expect(try fixture.batConfigurationText() == "--italic-text=always\n")
    #expect(try fixture.shellConfigurationText() == "export EDITOR=nvim\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.batThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.ezaThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.batSelectorBackup.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.ezaEnvironmentBackup.path))
    #expect(try String(contentsOf: cacheSentinel, encoding: .utf8) == "cache")
  }

  @Test
  func teardownReportsAnEarlierRemovalWhenALaterMutationRaces() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "--italic-text=always\n",
      shell: "export EDITOR=nvim\n"
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let checkpoints = Mutex(0)
    let shellConfiguration = fixture.shellConfiguration
    let manager = SetupOwnershipManager { checkpoint in
      guard checkpoint == .teardownReady else { return }
      let shouldEdit = checkpoints.withLock { count in
        count += 1
        return count == 2
      }
      if shouldEdit {
        try Data("concurrent shell edit\n".utf8).write(
          to: shellConfiguration,
          options: .atomic
        )
      }
    }

    let execution = try TeardownCommandRunner(ownershipManager: manager).execute(
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    let report = try decode(TeardownReport.self, execution.output)

    #expect(!execution.succeeded)
    #expect(
      report.integrations.map(\.id)
        == [
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
    #expect(
      report.integrations.map(\.status)
        == ["failed", "removed"] + Array(repeating: "none", count: 21)
    )
    #expect(
      report.integrations.map(\.mutationAttempted)
        == [true, true] + Array(repeating: false, count: 21)
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.ezaThemeLink.path))
    #expect(try fixture.shellConfigurationText() == "concurrent shell edit\n")
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func setupAndTeardownRoundTripOnlyTheRecordedKittyChange() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fixture.kittyConfiguration.path
    )
    try fixture.setExtendedAttribute(name: "io.github.macarchy.test", value: "preserve")
    let sentinel = fixture.stateRoot.appending(path: "generations/keep/manifest.json")
    try FileManager.default.createDirectory(
      at: sentinel.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("preserve".utf8).write(to: sentinel)

    let dryRun = try #require(
      SetupOwnershipManager().setup(
        homeDirectory: fixture.home,
        dryRun: true
      ).first)
    #expect(dryRun.status == .planned)
    #expect(try fixture.configuration() == "font_size 13\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))

    let setup = try setupRunner(ownershipManager: SetupOwnershipManager()).execute(
      profileName: "personal",
      homeDirectory: fixture.home,
      installDependencies: false,
      dryRun: false,
      json: true
    )
    let setupReport = try decode(SetupReport.self, setup.output)
    let setupJSON = try #require(
      JSONSerialization.jsonObject(with: Data(setup.output.utf8)) as? [String: Any]
    )
    let manifest = try decode(
      OwnershipManifest.self,
      String(decoding: Data(contentsOf: fixture.manifest), as: UTF8.self)
    )

    #expect(setup.succeeded)
    #expect(setupJSON["integration"] == nil)
    #expect((setupJSON["integrations"] as? [[String: Any]])?.count == 26)
    #expect(setupReport.outcome == "ready")
    #expect(setupReport.mutationAttempted)
    #expect(
      setupReport.integrations.map(\.status)
        == ["owned"] + Array(repeating: "external", count: 23)
        + Array(repeating: "disabled", count: 2)
    )
    #expect(manifest.schemaVersion == 1)
    #expect(manifest.records.map(\.phase) == ["applied"])
    #expect(try fixture.configuration() == "font_size 13\n\(fixture.includeDirective)\n")
    #expect(try fixture.permissions() == 0o600)
    #expect(try fixture.extendedAttribute(name: "io.github.macarchy.test") == "preserve")
    #expect(try fixture.permissions(at: fixture.backup) == 0o600)

    let repeated = try #require(
      SetupOwnershipManager().setup(
        homeDirectory: fixture.home,
        dryRun: false
      ).first)
    #expect(repeated.status == .owned)
    #expect(!repeated.mutationAttempted)

    let teardownDryRun = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: true, json: true)
    let teardownPreview = try decode(TeardownReport.self, teardownDryRun.output)
    #expect(
      teardownPreview.integrations.map(\.status)
        == ["planned"] + Array(repeating: "none", count: 25)
    )
    #expect(try fixture.configuration().contains(fixture.includeDirective))

    let teardown = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: false, json: true)
    let teardownReport = try decode(TeardownReport.self, teardown.output)
    let teardownJSON = try #require(
      JSONSerialization.jsonObject(with: Data(teardown.output.utf8)) as? [String: Any]
    )

    #expect(teardown.succeeded)
    #expect(teardownJSON["integration"] == nil)
    #expect((teardownJSON["integrations"] as? [[String: Any]])?.count == 26)
    #expect(
      teardownReport.integrations.map(\.status)
        == ["removed"] + Array(repeating: "none", count: 25)
    )
    #expect(try fixture.configuration() == "font_size 13\n")
    #expect(try fixture.permissions() == 0o600)
    #expect(try fixture.extendedAttribute(name: "io.github.macarchy.test") == "preserve")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")

    let repeatedTeardown = try #require(
      SetupOwnershipManager().teardown(
        homeDirectory: fixture.home,
        dryRun: false
      ).first)
    #expect(repeatedTeardown.status == .none)
  }

  @Test
  func missingIncludeInStowOwnedConfigurationRequiresExternalRemediation() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let externalKitty = fixture.root.appending(path: "dotfiles/kitty")
    try FileManager.default.createDirectory(
      at: externalKitty,
      withIntermediateDirectories: true
    )
    try Data("font_size 13\n".utf8).write(to: externalKitty.appending(path: "kitty.conf"))
    try FileManager.default.createDirectory(
      at: fixture.home.appending(path: ".config"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.home.appending(path: ".config/kitty"),
      withDestinationURL: externalKitty
    )

    let expected = SetupOwnershipError.kittyConfigurationIsExternallyOwned(
      fixture.kittyConfiguration
    )
    expectOwnershipError(expected) {
      _ = try SetupOwnershipManager().setup(
        homeDirectory: fixture.home,
        dryRun: false
      )
    }
    let execution = try setupRunner(ownershipManager: SetupOwnershipManager()).execute(
      profileName: "personal",
      homeDirectory: fixture.home,
      installDependencies: false,
      dryRun: false,
      json: true
    )
    let report = try decode(SetupReport.self, execution.output)
    #expect(!execution.succeeded)
    #expect(report.outcome == "integration_failed")
    #expect(report.integrations.map(\.status) == ["failed"])
    #expect(report.integrations.first?.message == expected.description)
    #expect(report.integrations.first?.mutationAttempted == false)
    #expect(try fixture.configuration() == "font_size 13\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func exactBridgeIncludeDoesNotHideAConflictingMacarchyInclude() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try Data(
      "\(fixture.includeDirective)\ninclude\t../macarchy/current/generated/kitty.conf\n"
        .utf8
    ).write(to: fixture.kittyConfiguration, options: .atomic)

    expectOwnershipError(.conflictingKittyInclude(fixture.kittyConfiguration)) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  private func setupRunner(ownershipManager: SetupOwnershipManager) -> SetupCommandRunner {
    SetupCommandRunner(
      resolveProfile: DependencyProfile.named,
      capabilityIsAvailable: { _ in true },
      processRunner: ProcessRunner { _ in
        Issue.record("Homebrew must not run")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      },
      writePreMutationPlan: { _ in Issue.record("No Homebrew plan is expected") },
      setupIntegrations: { homeDirectory, dryRun in
        try ownershipManager.setup(homeDirectory: homeDirectory, dryRun: dryRun)
      }
    )
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ output: String) throws -> Value {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: Data(output.utf8))
  }

  private func expectOwnershipError(
    _ expected: SetupOwnershipError,
    operation: () throws -> Void
  ) {
    do {
      try operation()
      Issue.record("Expected \(expected)")
    } catch let error as SetupOwnershipError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected \(expected), got \(error)")
    }
  }
}

private struct SetupReport: Decodable {
  let outcome: String
  let mutationAttempted: Bool
  let integrations: [IntegrationReport]
}

private struct TeardownReport: Decodable {
  let integrations: [IntegrationReport]
}

private struct IntegrationReport: Decodable {
  let id: String
  let status: String
  let target: String
  let message: String
  let mutationAttempted: Bool
}

private struct OwnershipManifest: Decodable {
  let schemaVersion: Int
  let records: [OwnershipRecord]
}

private struct OwnershipRecord: Decodable {
  let id: String
  let phase: String
}
