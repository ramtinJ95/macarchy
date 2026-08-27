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
  func batAndEzaTransactionsResumeFileAndLinkBoundaries() throws {
    for checkpoint in [
      SetupOwnershipCheckpoint.manifestPrepared,
      .backupWritten,
      .replacementSwapped,
      .targetWritten,
    ] {
      let fixture = try Fixture(configuration: "", externalBatEza: false)
      defer { fixture.remove() }
      try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
      try fixture.createLocalBatEzaConfigurations(
        bat: "--italic-text=always\n",
        shell: "\(fixture.ezaDirective)\n"
      )
      let interrupted = SetupOwnershipManager { observed in
        if observed == checkpoint { throw FixtureError.interrupted }
      }

      #expect(throws: SetupOwnershipTransactionError.self) {
        _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
      }
      let resumed = try SetupOwnershipManager().setup(
        homeDirectory: fixture.home,
        dryRun: false
      )
      #expect(
        resumed.map(\.status)
          == [.external, .owned, .owned, .external, .owned]
          + Array(repeating: .external, count: 19)
          + Array(repeating: .disabled, count: 2)
      )
      #expect(try fixture.batConfigurationText().contains(fixture.batDirective))
      #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
      #expect(try fixture.linkDestination(fixture.ezaThemeLink) == fixture.ezaThemeDestination.path)
    }

    for checkpoint in [SetupOwnershipCheckpoint.manifestPrepared, .targetWritten] {
      let fixture = try Fixture(configuration: "", externalBatEza: false)
      defer { fixture.remove() }
      try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
      try fixture.createLocalBatEzaConfigurations(
        bat: "\(fixture.batDirective)\n",
        shell: "\(fixture.ezaDirective)\n"
      )
      let interrupted = SetupOwnershipManager { observed in
        if observed == checkpoint { throw FixtureError.interrupted }
      }

      #expect(throws: SetupOwnershipTransactionError.self) {
        _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
      }
      let resumed = try SetupOwnershipManager().setup(
        homeDirectory: fixture.home,
        dryRun: false
      )
      #expect(
        resumed.map(\.status)
          == [.external, .external, .owned, .external, .owned]
          + Array(repeating: .external, count: 19)
          + Array(repeating: .disabled, count: 2)
      )
      #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    }

    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "\(fixture.batDirective)\n",
      shell: "\(fixture.ezaDirective)\n"
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.ezaThemeLink,
      withDestinationURL: fixture.ezaThemeDestination
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try FileManager.default.moveItem(at: fixture.batThemeLink, to: fixture.batThemeRemoval)

    let resumed = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    #expect(
      resumed.map(\.status)
        == [.external, .external, .owned, .external, .external]
        + Array(repeating: .external, count: 19)
        + Array(repeating: .disabled, count: 2)
    )
    #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.batThemeRemoval.path))

    try FileManager.default.moveItem(at: fixture.batThemeLink, to: fixture.batThemeRemoval)
    let teardown = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    #expect(
      teardown.map(\.status)
        == [.none, .none, .removed, .none, .none] + Array(repeating: .none, count: 21)
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.batThemeRemoval.path))
  }

  @Test
  func themeLinkCreationNeverOverwritesAConcurrentPathClaim() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "\(fixture.batDirective)\n",
      shell: "\(fixture.ezaDirective)\n"
    )
    let batThemeLink = fixture.batThemeLink
    let manager = SetupOwnershipManager { checkpoint in
      if checkpoint == .manifestPrepared {
        try Data("concurrent owner\n".utf8).write(to: batThemeLink)
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try manager.setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try String(contentsOf: fixture.batThemeLink, encoding: .utf8)
        == "concurrent owner\n"
    )
    expectOwnershipError(.ownershipDrift(fixture.batThemeLink)) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try String(contentsOf: fixture.batThemeLink, encoding: .utf8)
        == "concurrent owner\n"
    )
  }

  @Test
  func themeLinkTeardownNeverDeletesAConcurrentPathClaim() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "\(fixture.batDirective)\n",
      shell: "\(fixture.ezaDirective)\n"
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.ezaThemeLink,
      withDestinationURL: fixture.ezaThemeDestination
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let batThemeLink = fixture.batThemeLink
    let manager = SetupOwnershipManager { checkpoint in
      if checkpoint == .teardownReady {
        try FileManager.default.removeItem(at: batThemeLink)
        try Data("concurrent owner\n".utf8).write(to: batThemeLink)
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try manager.teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try String(contentsOf: fixture.batThemeLink, encoding: .utf8)
        == "concurrent owner\n"
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.batThemeRemoval.path))
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func teardownPreflightsEveryOwnedSeamBeforeChangingAnyOfThem() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "--italic-text=always\n",
      shell: "export EDITOR=nvim\n"
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try Data("user edit\n\(fixture.batDirective)\n".utf8).write(
      to: fixture.batConfiguration,
      options: .atomic
    )
    let ezaBefore = try fixture.shellConfigurationText()

    expectOwnershipError(.ownershipDrift(fixture.batConfiguration)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }

    #expect(try fixture.batConfigurationText() == "user edit\n\(fixture.batDirective)\n")
    #expect(try fixture.shellConfigurationText() == ezaBefore)
    #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    #expect(try fixture.linkDestination(fixture.ezaThemeLink) == fixture.ezaThemeDestination.path)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
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
  func teardownRejectsAnOwnedThemeLinkBelowASwappedParentBeforeMutation() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "--italic-text=always\n",
      shell: "export EDITOR=nvim\n"
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let ezaDirectory = fixture.ezaThemeLink.deletingLastPathComponent()
    let movedEzaDirectory = fixture.root.appending(path: "eza-original")
    try FileManager.default.moveItem(at: ezaDirectory, to: movedEzaDirectory)
    try FileManager.default.createSymbolicLink(
      at: ezaDirectory,
      withDestinationURL: movedEzaDirectory
    )
    let batBefore = try fixture.batConfigurationText()

    expectOwnershipError(.ownershipDrift(fixture.ezaThemeLink)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }

    #expect(try fixture.batConfigurationText() == batBefore)
    #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    #expect(try fixture.linkDestination(fixture.ezaThemeLink) == fixture.ezaThemeDestination.path)
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
  func setupResumesAtEveryRecordedTransactionBoundary() throws {
    let setupCheckpoints: [SetupOwnershipCheckpoint] = [
      .manifestPrepared, .backupWritten, .replacementSwapped, .targetWritten,
    ]
    for selectedCheckpoint in setupCheckpoints {
      let fixture = try Fixture(configuration: "font_size 13\n")
      defer { fixture.remove() }
      let interrupted = SetupOwnershipManager { checkpoint in
        if checkpoint == selectedCheckpoint { throw FixtureError.interrupted }
      }

      #expect(throws: SetupOwnershipTransactionError.self) {
        try interrupted.setup(
          homeDirectory: fixture.home,
          dryRun: false
        )
      }
      let prepared = try decode(
        OwnershipManifest.self,
        String(decoding: Data(contentsOf: fixture.manifest), as: UTF8.self)
      )
      #expect(prepared.records.map(\.phase) == ["prepared"])

      let resumed = try #require(
        SetupOwnershipManager().setup(
          homeDirectory: fixture.home,
          dryRun: false
        ).first)
      let applied = try decode(
        OwnershipManifest.self,
        String(decoding: Data(contentsOf: fixture.manifest), as: UTF8.self)
      )

      #expect(resumed.status == .owned)
      #expect(resumed.mutationAttempted)
      #expect(applied.records.map(\.phase) == ["applied"])
      #expect(try fixture.configuration().contains(fixture.includeDirective))
      #expect(FileManager.default.fileExists(atPath: fixture.backup.path))
      #expect(
        try #require(
          SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false).first
        ).status
          == .removed
      )
      #expect(try fixture.configuration() == "font_size 13\n")
    }
  }

  @Test
  func setupPreservesReplacementResidueUntilTheBackupIsValidated() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    let interrupted = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
    }
    let residue = try Data(contentsOf: fixture.replacement)
    try FileManager.default.removeItem(at: fixture.backup)

    expectOwnershipError(.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try Data(contentsOf: fixture.replacement) == residue)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func concurrentConfigurationEditsAreNeverOverwritten() throws {
    let setupFixture = try Fixture(configuration: "font_size 13\n")
    defer { setupFixture.remove() }
    let setupTarget = setupFixture.kittyConfiguration
    let setupEdit = Data("font_size 14\n".utf8)
    let interruptedSetup = SetupOwnershipManager { checkpoint in
      if checkpoint == .backupWritten {
        try setupEdit.write(to: setupTarget, options: .atomic)
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedSetup.setup(homeDirectory: setupFixture.home, dryRun: false)
    }
    #expect(try setupFixture.configuration() == "font_size 14\n")

    let boundaryFixture = try Fixture(configuration: "font_size 13\n")
    defer { boundaryFixture.remove() }
    let boundaryTarget = boundaryFixture.kittyConfiguration
    let boundaryEdit = Data("font_size 15\n".utf8)
    let boundarySetup = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementReady {
        try boundaryEdit.write(to: boundaryTarget, options: .atomic)
      }
    }
    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try boundarySetup.setup(homeDirectory: boundaryFixture.home, dryRun: false)
    }
    #expect(try boundaryFixture.configuration() == "font_size 15\n")
    #expect(!FileManager.default.fileExists(atPath: boundaryFixture.replacement.path))

    let metadataFixture = try Fixture(configuration: "font_size 13\n")
    defer { metadataFixture.remove() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: metadataFixture.kittyConfiguration.path
    )
    let metadataTarget = metadataFixture.kittyConfiguration
    let metadataSetup = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementReady {
        try Data("font_size 13\n".utf8).write(to: metadataTarget, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o644],
          ofItemAtPath: metadataTarget.path
        )
      }
    }
    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try metadataSetup.setup(homeDirectory: metadataFixture.home, dryRun: false)
    }
    #expect(try metadataFixture.configuration() == "font_size 13\n")
    #expect(try metadataFixture.permissions() == 0o644)
    #expect(!FileManager.default.fileExists(atPath: metadataFixture.replacement.path))

    let teardownFixture = try Fixture(configuration: "font_size 13\n")
    defer { teardownFixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: teardownFixture.home, dryRun: false)
    let teardownTarget = teardownFixture.kittyConfiguration
    let teardownEdit = Data(
      "font_size 14\n\(teardownFixture.includeDirective)\n".utf8
    )
    let interruptedTeardown = SetupOwnershipManager { checkpoint in
      if checkpoint == .teardownReady {
        try teardownEdit.write(to: teardownTarget, options: .atomic)
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedTeardown.teardown(homeDirectory: teardownFixture.home, dryRun: false)
    }
    #expect(
      try teardownFixture.configuration()
        == "font_size 14\n\(teardownFixture.includeDirective)\n"
    )
  }

  @Test
  func parentDirectorySwapCannotRedirectTheSetupWrite() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    let kittyDirectory = fixture.kittyConfiguration.deletingLastPathComponent()
    let movedDirectory = kittyDirectory.appendingPathExtension("original")
    let externalDirectory = fixture.root.appending(path: "external-kitty")
    let externalConfiguration = externalDirectory.appending(path: "kitty.conf")
    try FileManager.default.createDirectory(
      at: externalDirectory,
      withIntermediateDirectories: true
    )
    try Data("font_size 13\n".utf8).write(to: externalConfiguration)
    let manager = SetupOwnershipManager { checkpoint in
      if checkpoint == .backupWritten {
        try FileManager.default.moveItem(at: kittyDirectory, to: movedDirectory)
        try FileManager.default.createSymbolicLink(
          at: kittyDirectory,
          withDestinationURL: externalDirectory
        )
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try manager.setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try String(contentsOf: externalConfiguration, encoding: .utf8) == "font_size 13\n")
    #expect(
      try String(
        contentsOf: movedDirectory.appending(path: "kitty.conf"),
        encoding: .utf8
      ) == "font_size 13\n"
    )
  }

  @Test
  func setupWaitsForActivationPreflightAndCanonicalCommit() async throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    let package = try ThemePackageLoader().load(
      packageURL: URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "Themes/catppuccin-mocha")
    )
    let stateRoot = fixture.stateRoot
    let home = fixture.home
    let preflightEntered = Mutex(false)
    let releasePreflight = DispatchSemaphore(value: 0)
    let activationCompleted = Mutex(false)
    let activationResult = Mutex<Result<GenerationManifest, any Error>?>(nil)
    DispatchQueue.global().async {
      let result = Result {
        try ThemeActivator(root: stateRoot).activate(
          package: package,
          expectedActiveGenerationID: nil,
          prepareWallpaperData: {
            preflightEntered.withLock { $0 = true }
            releasePreflight.wait()
            return package.wallpaperData
          }
        )
      }
      activationResult.withLock { $0 = result }
      activationCompleted.withLock { $0 = true }
    }
    for _ in 0..<100 where !preflightEntered.withLock({ $0 }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(preflightEntered.withLock { $0 })
    let setupCompleted = Mutex(false)
    let setupResult = Mutex<Result<[SetupIntegrationResult], any Error>?>(nil)
    DispatchQueue.global().async {
      let result = Result {
        try SetupOwnershipManager().setup(
          homeDirectory: home,
          dryRun: false
        )
      }
      setupResult.withLock { $0 = result }
      setupCompleted.withLock { $0 = true }
    }

    try await Task.sleep(for: .milliseconds(25))
    #expect(!setupCompleted.withLock { $0 })
    #expect(try fixture.configuration() == "font_size 13\n")
    releasePreflight.signal()

    for _ in 0..<1000
    where !activationCompleted.withLock({ $0 }) || !setupCompleted.withLock({ $0 }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    _ = try #require(activationResult.withLock { $0 }).get()
    #expect(try #require(setupResult.withLock { $0 }).get().first?.status == .owned)
    #expect(try fixture.configuration().contains(fixture.includeDirective))
  }

  @Test
  func teardownRefusesToEraseChangesMadeAfterSetup() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(
      homeDirectory: fixture.home,
      dryRun: false
    )
    try Data("font_size 14\n\(fixture.includeDirective)\n".utf8).write(
      to: fixture.kittyConfiguration,
      options: .atomic
    )

    let expected = SetupOwnershipError.ownershipDrift(fixture.kittyConfiguration)
    expectOwnershipError(expected) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    let execution = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: false, json: true)
    let report = try decode(TeardownReport.self, execution.output)
    #expect(!execution.succeeded)
    #expect(report.integrations.map(\.status) == ["failed"])
    #expect(report.integrations.first?.message == expected.description)
    #expect(report.integrations.first?.mutationAttempted == false)
    #expect(try fixture.configuration() == "font_size 14\n\(fixture.includeDirective)\n")
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(FileManager.default.fileExists(atPath: fixture.backup.path))
  }

  @Test
  func ownershipRejectsAnInstalledDigestThatCannotBeReproducedFromBackup() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let forgedConfiguration = Data("font_size 99\n".utf8)
    var manifest = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest))
        as? [String: Any]
    )
    var records = try #require(manifest["records"] as? [[String: Any]])
    records[0]["installed_digest"] = sha256Digest(forgedConfiguration)
    manifest["records"] = records
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(
      to: fixture.manifest,
      options: .atomic
    )
    try forgedConfiguration.write(to: fixture.kittyConfiguration, options: .atomic)

    expectOwnershipError(
      .invalidManifest("Kitty installed digest cannot be reproduced")
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
  }

  @Test
  func ownershipRejectsAnUnsupportedSchemaVersion() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.manifest.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"schema_version":99,"records":[]}"#.utf8).write(to: fixture.manifest)

    expectOwnershipError(.invalidManifest("unsupported schema version 99")) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
  }

  @Test
  func ownershipRejectsOutOfContractSchemaOneShapes() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.manifest.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let prereleaseRecord = """
      {
        "schema_version": 1,
        "records": [{
          "id": "kitty.include",
          "phase": "applied",
          "target_path": "\(fixture.kittyConfiguration.path)",
          "backup_path": "state/setup/backups/kitty.conf",
          "original_digest": "original",
          "installed_digest": "installed"
        }]
      }
      """
    let documents = [
      #"{"schema_version":1,"records":[],"integration":{}}"#,
      #"{"schema_version":1,"records":[{"id":"bat.theme-link","phase":"applied","kind":"symbolic_link","target_path":"target","installed_digest":"digest","link_destination":"destination","unknown_field":true}]}"#,
      prereleaseRecord,
    ]

    for document in documents {
      try Data(document.utf8).write(to: fixture.manifest, options: .atomic)
      do {
        _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
        Issue.record("Expected strict schema-v1 rejection")
      } catch SetupOwnershipError.invalidManifest {
      } catch {
        Issue.record("Expected invalid manifest, got \(error)")
      }
    }
  }

  @Test
  func teardownDryRunRejectsASymlinkedBackupBeforePromisingRestoration() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let externalBackup = fixture.root.appending(path: "external-kitty.conf")
    try FileManager.default.removeItem(at: fixture.backup)
    try Data("font_size 13\n".utf8).write(to: externalBackup)
    try FileManager.default.createSymbolicLink(
      at: fixture.backup,
      withDestinationURL: externalBackup
    )

    let expected = SetupOwnershipError.corruptBackup(fixture.backup)
    expectOwnershipError(expected) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true)
    }
    let execution = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: true, json: true)
    let report = try decode(TeardownReport.self, execution.output)
    #expect(!execution.succeeded)
    #expect(report.integrations.map(\.status) == ["failed"])
    #expect(report.integrations.first?.message == expected.description)
    #expect(report.integrations.first?.mutationAttempted == false)
    #expect(try fixture.configuration().contains(fixture.includeDirective))
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func teardownRejectsAPermissiveBackup() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: fixture.backup.path
    )

    expectOwnershipError(.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true)
    }
  }

  @Test
  func teardownNeverRecursivelyRemovesSubstitutedBackupState() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try Data("font_size 13\n".utf8).write(
      to: fixture.kittyConfiguration,
      options: .atomic
    )
    try FileManager.default.removeItem(at: fixture.backup)
    try FileManager.default.createDirectory(
      at: fixture.backup,
      withIntermediateDirectories: false
    )
    let sentinel = fixture.backup.appending(path: "preserve")
    try Data("evidence".utf8).write(to: sentinel)

    expectOwnershipError(.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "evidence")
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func setupRefusesAnOrphanedBackup() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.backup.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("recovery evidence".utf8).write(to: fixture.backup)

    expectOwnershipError(.orphanedBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(try String(contentsOf: fixture.backup, encoding: .utf8) == "recovery evidence")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
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

enum FixtureError: Error {
  case interrupted
}

final class Fixture {
  let root: URL
  let home: URL

  init(
    configuration: String? = nil,
    externalBatEza: Bool = true,
    externalBtopYaziAtuin: Bool = true,
    externalNeovimStarship: Bool = true,
    externalAgentTUIs: Bool = true
  ) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-ownership-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    if let configuration {
      try FileManager.default.createDirectory(
        at: kittyConfiguration.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(configuration.utf8).write(to: kittyConfiguration)
    }
    if externalBatEza {
      try createExternalBatEzaSeams()
    }
    if externalBtopYaziAtuin {
      try createExternalBtopYaziAtuinSeams()
    }
    if externalNeovimStarship {
      try createExternalNeovimStarshipSeams()
    }
    if externalAgentTUIs {
      try createExternalAgentTUISeams()
    }
  }

  var stateRoot: URL {
    home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
  }

  var kittyConfiguration: URL {
    home.appending(path: ".config/kitty/kitty.conf")
  }

  var includeDirective: String {
    ThemeActivationCoordinator.kittyIncludeDirective(root: stateRoot)
  }

  var manifest: URL {
    stateRoot.appending(path: "state/setup/ownership.json")
  }

  var backup: URL {
    stateRoot.appending(path: "state/setup/backups/kitty.conf")
  }

  var batSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/bat-config")
  }

  var ezaEnvironmentBackup: URL {
    stateRoot.appending(path: "state/setup/backups/zshrc")
  }

  var replacement: URL {
    kittyConfiguration.deletingLastPathComponent()
      .appending(path: ".macarchy-kitty-transaction")
  }

  var batConfiguration: URL {
    home.appending(path: ".config/bat/config")
  }

  var batThemeLink: URL {
    home.appending(path: ".config/bat/themes/\(BatAdapter.themeFileName)")
  }

  var batThemeDestination: URL {
    stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
  }

  var batThemeRemoval: URL {
    batThemeLink.deletingLastPathComponent()
      .appending(path: ".macarchy-bat-theme-link-removal")
  }

  var shellConfiguration: URL {
    home.appending(path: ".zshrc")
  }

  var ezaThemeLink: URL {
    home.appending(path: ".config/eza/theme.yml")
  }

  var ezaThemeDestination: URL {
    stateRoot.appending(path: "current/\(EzaAdapter.outputPath)")
  }

  var batDirective: String {
    BatAdapter.themeDirective
  }

  var ezaDirective: String {
    EzaAdapter.environmentDirective(
      configurationDirectoryURL: ezaThemeLink.deletingLastPathComponent()
    )
  }

  var btopConfiguration: URL {
    home.appending(path: ".config/btop/btop.conf")
  }

  var btopThemeLink: URL {
    home.appending(path: ".config/btop/themes/\(BtopAdapter.themeFileName)")
  }

  var btopThemeDestination: URL {
    stateRoot.appending(path: "current/\(BtopAdapter.outputPath)")
  }

  var yaziConfiguration: URL {
    home.appending(path: ".config/yazi/theme.toml")
  }

  var yaziFlavorLink: URL {
    home.appending(
      path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi/flavor.toml")
  }

  var yaziFlavorDestination: URL {
    stateRoot.appending(path: "current/\(YaziAdapter.flavorOutputPath)")
  }

  var yaziSyntaxLink: URL {
    home.appending(
      path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi/tmtheme.xml")
  }

  var yaziSyntaxDestination: URL {
    stateRoot.appending(path: "current/\(YaziAdapter.syntaxOutputPath)")
  }

  var atuinConfiguration: URL {
    home.appending(path: ".config/atuin/config.toml")
  }

  var atuinThemeLink: URL {
    home.appending(path: ".config/atuin/themes/\(AtuinAdapter.themeName).toml")
  }

  var atuinThemeDestination: URL {
    stateRoot.appending(path: "current/\(AtuinAdapter.outputPath)")
  }

  var yaziSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/yazi-theme.toml")
  }

  var atuinSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/atuin-config.toml")
  }

  func writeKittyConfiguration(_ configuration: String) throws {
    try FileManager.default.createDirectory(
      at: kittyConfiguration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(configuration.utf8).write(to: kittyConfiguration, options: .atomic)
  }

  func createLocalBatEzaConfigurations(bat: String, shell: String) throws {
    try FileManager.default.createDirectory(
      at: batThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(bat.utf8).write(to: batConfiguration)
    try Data(shell.utf8).write(to: shellConfiguration)
    try FileManager.default.createDirectory(
      at: ezaThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  func createLocalBtopYaziAtuinConfigurations(
    btop: String,
    yazi: String,
    atuin: String
  ) throws {
    try FileManager.default.createDirectory(
      at: btopThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(btop.utf8).write(to: btopConfiguration)
    try FileManager.default.createDirectory(
      at: yaziFlavorLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(yazi.utf8).write(to: yaziConfiguration)
    try FileManager.default.createDirectory(
      at: atuinThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(atuin.utf8).write(to: atuinConfiguration)
  }

  func createBtopYaziAtuinThemeLinks() throws {
    try FileManager.default.createSymbolicLink(
      at: btopThemeLink,
      withDestinationURL: btopThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavorLink,
      withDestinationURL: yaziFlavorDestination
    )
    try FileManager.default.createSymbolicLink(
      at: yaziSyntaxLink,
      withDestinationURL: yaziSyntaxDestination
    )
    try FileManager.default.createSymbolicLink(
      at: atuinThemeLink,
      withDestinationURL: atuinThemeDestination
    )
  }

  func batConfigurationText() throws -> String {
    try String(contentsOf: batConfiguration, encoding: .utf8)
  }

  func shellConfigurationText() throws -> String {
    try String(contentsOf: shellConfiguration, encoding: .utf8)
  }

  func linkDestination(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
  }

  private func createExternalBatEzaSeams() throws {
    let batDirectory = home.appending(path: ".config/bat")
    let batThemes = batDirectory.appending(path: "themes")
    try FileManager.default.createDirectory(at: batThemes, withIntermediateDirectories: true)
    try Data("\(batDirective)\n".utf8).write(
      to: batDirectory.appending(path: "config")
    )
    try FileManager.default.createSymbolicLink(
      at: batThemes.appending(path: BatAdapter.themeFileName),
      withDestinationURL: batThemeDestination
    )

    try Data("\(ezaDirective)\n".utf8).write(
      to: home.appending(path: ".zshrc")
    )
    let ezaDirectory = home.appending(path: ".config/eza")
    try FileManager.default.createDirectory(at: ezaDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: ezaDirectory.appending(path: "theme.yml"),
      withDestinationURL: ezaThemeDestination
    )
  }

  private func createExternalBtopYaziAtuinSeams() throws {
    let dotfiles = root.appending(path: "dotfiles")
    let configurationRoot = home.appending(path: ".config")
    try FileManager.default.createDirectory(
      at: configurationRoot,
      withIntermediateDirectories: true
    )

    let btop = dotfiles.appending(path: "btop")
    let btopThemes = btop.appending(path: "themes")
    try FileManager.default.createDirectory(at: btopThemes, withIntermediateDirectories: true)
    try Data("\(BtopAdapter.themeDirective)\n".utf8).write(
      to: btop.appending(path: "btop.conf")
    )
    try FileManager.default.createSymbolicLink(
      at: btopThemes.appending(path: BtopAdapter.themeFileName),
      withDestinationURL: btopThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: configurationRoot.appending(path: "btop"),
      withDestinationURL: btop
    )

    let yazi = dotfiles.appending(path: "yazi")
    let yaziFlavorDirectory = yazi.appending(
      path: "flavors/\(YaziAdapter.flavorName).yazi")
    try FileManager.default.createDirectory(
      at: yaziFlavorDirectory,
      withIntermediateDirectories: true
    )
    try Data("[flavor]\ndark = \"\(YaziAdapter.flavorName)\"\n".utf8).write(
      to: yazi.appending(path: "theme.toml")
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavorDirectory.appending(path: "flavor.toml"),
      withDestinationURL: yaziFlavorDestination
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavorDirectory.appending(path: "tmtheme.xml"),
      withDestinationURL: yaziSyntaxDestination
    )
    try FileManager.default.createSymbolicLink(
      at: configurationRoot.appending(path: "yazi"),
      withDestinationURL: yazi
    )

    let atuin = configurationRoot.appending(path: "atuin")
    try FileManager.default.createDirectory(at: atuin, withIntermediateDirectories: true)
    let externalAtuin = dotfiles.appending(path: "atuin")
    let externalAtuinThemes = externalAtuin.appending(path: "themes")
    try FileManager.default.createDirectory(
      at: externalAtuinThemes,
      withIntermediateDirectories: true
    )
    let externalAtuinConfiguration = externalAtuin.appending(path: "config.toml")
    try Data("[theme]\nname = \"\(AtuinAdapter.themeName)\"\n".utf8).write(
      to: externalAtuinConfiguration
    )
    try FileManager.default.createSymbolicLink(
      at: externalAtuinThemes.appending(path: "\(AtuinAdapter.themeName).toml"),
      withDestinationURL: atuinThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: atuin.appending(path: "config.toml"),
      withDestinationURL: externalAtuinConfiguration
    )
    try FileManager.default.createSymbolicLink(
      at: atuin.appending(path: "themes"),
      withDestinationURL: externalAtuinThemes
    )
  }

  func configuration() throws -> String {
    try String(contentsOf: kittyConfiguration, encoding: .utf8)
  }

  func permissions() throws -> Int {
    try permissions(at: kittyConfiguration)
  }

  func permissions(at url: URL) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        as? Int
    )
  }

  func setExtendedAttribute(name: String, value: String) throws {
    let data = Data(value.utf8)
    let result = data.withUnsafeBytes { bytes in
      kittyConfiguration.path.withCString { path in
        name.withCString { attribute in
          Darwin.setxattr(path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  func extendedAttribute(name: String) throws -> String {
    let size = kittyConfiguration.path.withCString { path in
      name.withCString { attribute in
        Darwin.getxattr(path, attribute, nil, 0, 0, 0)
      }
    }
    guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes { bytes in
      kittyConfiguration.path.withCString { path in
        name.withCString { attribute in
          Darwin.getxattr(path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard count == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return String(decoding: data, as: UTF8.self)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
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
