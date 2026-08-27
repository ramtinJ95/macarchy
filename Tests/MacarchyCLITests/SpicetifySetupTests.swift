import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct SpicetifySetupTests {
  @Test
  func absentOptionalProviderIsExplicitlyDisabledAndSuccessful() throws {
    let fixture = try SpicetifySetupFixture(configuration: nil)
    defer { fixture.remove() }

    let setup = try fixture.setup(dryRun: false)

    #expect(setup.map(\.id) == ["spicetify.selectors", "spicetify.color-link"])
    #expect(setup.allSatisfy { $0.status == .disabled && $0.succeeded })
    #expect(setup.allSatisfy { !$0.mutationAttempted })
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.stateRoot.appending(path: "run/spicetify.lock").path
      )
    )

    let teardown = try fixture.teardown(dryRun: false)
    #expect(teardown.map(\.status) == [.none, .none])
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.stateRoot.appending(path: "run/spicetify.lock").path
      )
    )
  }

  @Test
  func partialProviderStateFailsInsteadOfBeingReportedAsDisabled() throws {
    let fixture = try SpicetifySetupFixture(
      configuration: nil,
      createColorLink: true
    )
    defer { fixture.remove() }

    #expect(
      throws: SetupOwnershipError.missingConfiguration(
        "spicetify.selectors",
        fixture.configuration
      )
    ) {
      _ = try fixture.setup(dryRun: false)
    }
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func centralSetupAndTeardownRoundTripPresentSpicetifySeams() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    let original = Data(
      "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\ninject_css = 1\n".utf8
    )
    try FileManager.default.createDirectory(
      at: context.spicetifyColorLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try original.write(to: context.spicetifyConfiguration)
    let userCSS = context.spicetifyColorLink.deletingLastPathComponent()
      .appending(path: "user.css")
    let css = Data("/* preserve provider CSS */\n".utf8)
    try css.write(to: userCSS)

    let setup = try SetupOwnershipManager().setup(
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(setup.suffix(2).map(\.status) == [.owned, .owned])
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: context.spicetifyColorLink.path
      ) == context.spicetifyColorDestination.path
    )
    #expect(try Data(contentsOf: userCSS) == css)

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(teardown.suffix(2).map(\.status) == [.removed, .removed])
    #expect(try Data(contentsOf: context.spicetifyConfiguration) == original)
    #expect(try Data(contentsOf: userCSS) == css)
    #expect(throws: (any Error).self) {
      _ = try FileManager.default.destinationOfSymbolicLink(
        atPath: context.spicetifyColorLink.path
      )
    }
    #expect(!FileManager.default.fileExists(atPath: context.manifestURL.path))
  }

  @Test
  func exactStowOwnedSeamsRemainExternalAndByteIdentical() throws {
    let configuration = Data(
      """
      [Setting]
      prefs_path              = /Users/test/Library/Application Support/Spotify/prefs
      inject_css              = 1
      current_theme           = text
      color_scheme            = MacarchyCurrent
      replace_colors          = 1

      [Preprocesses]
      disable_sentry          = 1

      """.utf8
    )
    let fixture = try SpicetifySetupFixture(
      configuration: configuration,
      externallyOwned: true,
      createColorLink: true
    )
    defer { fixture.remove() }
    let css = try Data(contentsOf: fixture.userCSS)

    let results = try fixture.setup(dryRun: false)

    #expect(results.map(\.id) == ["spicetify.selectors", "spicetify.color-link"])
    #expect(results.allSatisfy { $0.status == .external && !$0.mutationAttempted })
    #expect(try Data(contentsOf: fixture.configuration) == configuration)
    #expect(try Data(contentsOf: fixture.userCSS) == css)
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func ownedSelectorsAndColorLinkPreserveProviderBytesAndRoundTrip() throws {
    let original = Data(
      "[Setting]\r\n; provider comment\r\ninject_css = 1\r\nreplace_colors = 1\r\n"
        .appending("\r\n[Backup]\r\nversion = 1.2.3\r\n").utf8
    )
    let fixture = try SpicetifySetupFixture(configuration: original)
    defer { fixture.remove() }
    let css = try Data(contentsOf: fixture.userCSS)

    let preview = try fixture.setup(dryRun: true)

    #expect(preview.map(\.status) == [.planned, .planned])
    #expect(try Data(contentsOf: fixture.configuration) == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(throws: (any Error).self) {
      _ = try fixture.colorLinkDestination()
    }

    let setup = try fixture.setup(dryRun: false)
    let expected = Data(
      "[Setting]\r\ncurrent_theme = text\r\ncolor_scheme = MacarchyCurrent\r\n"
        .appending("; provider comment\r\ninject_css = 1\r\nreplace_colors = 1\r\n")
        .appending("\r\n[Backup]\r\nversion = 1.2.3\r\n").utf8
    )

    #expect(setup.map(\.status) == [.owned, .owned])
    #expect(setup.allSatisfy { $0.mutationAttempted })
    #expect(try Data(contentsOf: fixture.configuration) == expected)
    #expect(try Data(contentsOf: fixture.userCSS) == css)
    #expect(try Data(contentsOf: fixture.selectorsBackup) == original)
    #expect(try fixture.permissions(at: fixture.selectorsBackup) == 0o600)
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)
    let manifest = try fixture.manifestJSON()
    #expect(manifest["schema_version"] as? Int == 1)
    #expect(
      (manifest["records"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        == ["spicetify.color-link", "spicetify.selectors"]
    )
    #expect(
      (manifest["records"] as? [[String: Any]])?
        .first { $0["id"] as? String == "spicetify.selectors" }?["kind"] as? String
        == "spicetify_selection"
    )

    let repeated = try fixture.setup(dryRun: false)
    #expect(repeated.map(\.status) == [.owned, .owned])
    #expect(repeated.allSatisfy { !$0.mutationAttempted })

    let teardown = try fixture.teardown(dryRun: false)

    #expect(teardown.map(\.status) == [.removed, .removed])
    #expect(try Data(contentsOf: fixture.configuration) == original)
    #expect(try Data(contentsOf: fixture.userCSS) == css)
    #expect(throws: (any Error).self) {
      _ = try fixture.colorLinkDestination()
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.selectorsBackup.path))
  }

  @Test
  func providerRewriteOfUnrelatedFieldsSurvivesRepeatSetupAndTeardown() throws {
    let original = Data(
      "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\ninject_css = 1\n".utf8
    )
    let fixture = try SpicetifySetupFixture(
      configuration: original,
      createColorLink: true
    )
    defer { fixture.remove() }
    _ = try fixture.setup(dryRun: false)
    let providerRewrite = Data(
      """
      [Setting]
      spotify_path = /Applications/Spotify.app/Contents/Resources
      current_theme = text
      color_scheme = MacarchyCurrent
      inject_css = 0

      [Preprocesses]
      disable_sentry = 0

      """.utf8
    )
    try providerRewrite.write(to: fixture.configuration, options: .atomic)

    let repeated = try fixture.setup(dryRun: false)

    #expect(repeated.map(\.status) == [.owned, .external])
    #expect(repeated.allSatisfy { !$0.mutationAttempted })
    #expect(try Data(contentsOf: fixture.configuration) == providerRewrite)

    let teardown = try fixture.teardown(dryRun: false)
    let expected = Data(
      """
      [Setting]
      spotify_path = /Applications/Spotify.app/Contents/Resources
      current_theme = marketplace
      color_scheme = Default
      inject_css = 0

      [Preprocesses]
      disable_sentry = 0

      """.utf8
    )
    #expect(teardown.map(\.status) == [.removed, .none])
    #expect(try Data(contentsOf: fixture.configuration) == expected)
  }

  @Test
  func setupWaitsForTheSharedSpicetifyLock() throws {
    let original = Data(
      "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n".utf8
    )
    let fixture = try SpicetifySetupFixture(
      configuration: original,
      createColorLink: true
    )
    defer { fixture.remove() }
    let refreshEntered = DispatchSemaphore(value: 0)
    let releaseLock = DispatchSemaphore(value: 0)
    let reconciliationFinished = DispatchSemaphore(value: 0)
    let setupFinished = DispatchSemaphore(value: 0)
    let reconciliationError = Mutex<String?>(nil)
    let setupError = Mutex<String?>(nil)
    let adapter = SpicetifyAdapter(
      root: fixture.stateRoot,
      configurationDirectoryURL: fixture.configuration.deletingLastPathComponent(),
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
          return ProcessResult(terminationStatus: 1, output: "")
        }
        refreshEntered.signal()
        releaseLock.wait()
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )

    Task(executorPreference: BlockingTaskExecutor(label: "spicetify-setup-overlap")) {
      do {
        _ = try await adapter.reconciliation().run()
      } catch {
        reconciliationError.withLock { $0 = String(describing: error) }
      }
      reconciliationFinished.signal()
    }
    #expect(refreshEntered.wait(timeout: .now() + 1) == .success)
    let providerEdit = Data(
      "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\n".utf8
    )
    try providerEdit.write(to: fixture.configuration, options: .atomic)

    DispatchQueue.global(qos: .utility).async {
      do {
        _ = try fixture.setup(dryRun: false)
      } catch {
        setupError.withLock { $0 = String(describing: error) }
      }
      setupFinished.signal()
    }
    #expect(setupFinished.wait(timeout: .now() + 0.1) == .timedOut)
    #expect(try Data(contentsOf: fixture.configuration) == providerEdit)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))

    releaseLock.signal()
    #expect(reconciliationFinished.wait(timeout: .now() + 1) == .success)
    #expect(setupFinished.wait(timeout: .now() + 1) == .success)
    #expect(reconciliationError.withLock { $0 } == nil)
    #expect(setupError.withLock { $0 } == nil)
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n"
    )
  }

  @Test
  func interruptedTeardownPreservesProviderFieldsAndResumes() throws {
    for checkpoint in [
      SetupOwnershipCheckpoint.replacementSwapped,
      .targetWritten,
    ] {
      let original = Data(
        "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\ninject_css = 1\n".utf8
      )
      let fixture = try SpicetifySetupFixture(
        configuration: original,
        createColorLink: true
      )
      defer { fixture.remove() }
      _ = try fixture.setup(dryRun: false)
      let providerRewrite = Data(
        "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\ninject_css = 0\n".utf8
      )
      try providerRewrite.write(to: fixture.configuration, options: .atomic)
      let interrupted = SetupOwnershipManager { observed in
        if observed == checkpoint { throw SpicetifySetupTestError.interrupted }
      }

      #expect(throws: SetupOwnershipTransactionError.self) {
        _ = try fixture.teardown(manager: interrupted, dryRun: false)
      }
      let resumed = try fixture.teardown(dryRun: false)

      #expect(resumed.map(\.status) == [.removed, .none])
      #expect(
        try String(contentsOf: fixture.configuration, encoding: .utf8)
          == "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\ninject_css = 0\n"
      )
      #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    }
  }

  @Test
  func interruptedSelectorReplacementNeverPublishesOnlyOneSelector() throws {
    let original = Data("[Setting]\ninject_css = 1\n".utf8)
    let fixture = try SpicetifySetupFixture(
      configuration: original,
      createColorLink: true
    )
    defer { fixture.remove() }
    let interrupted = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw SpicetifySetupTestError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try fixture.setup(manager: interrupted, dryRun: false)
    }
    let interruptedConfiguration = try String(
      contentsOf: fixture.configuration,
      encoding: .utf8
    )
    #expect(interruptedConfiguration.contains("current_theme = text\n"))
    #expect(interruptedConfiguration.contains("color_scheme = MacarchyCurrent\n"))

    let resumed = try fixture.setup(dryRun: false)

    #expect(resumed.map(\.status) == [.owned, .external])
    let teardown = try fixture.teardown(dryRun: false)
    #expect(teardown.map(\.status) == [.removed, .none])
    #expect(try Data(contentsOf: fixture.configuration) == original)
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)
  }

  @Test
  func selectorParserRejectsMalformedAndDuplicateStateWithoutMutation() throws {
    let malformedConfigurations = [
      "[Setting]\ncurrent_theme = text\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n",
      "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n[Setting]\n",
      "[Setting]\nmalformed provider setting\n",
      "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n[Backup]\nmalformed later section\n",
      "[Backup]\nversion = 1\n",
    ]
    for configuration in malformedConfigurations {
      let original = Data(configuration.utf8)
      let fixture = try SpicetifySetupFixture(
        configuration: original,
        createColorLink: true
      )
      defer { fixture.remove() }

      do {
        _ = try fixture.setup(dryRun: true)
        Issue.record("Expected malformed Spicetify configuration to fail")
      } catch SetupOwnershipError.invalidConfiguration(let id, let target, _) {
        #expect(id == "spicetify.selectors")
        #expect(target == fixture.configuration)
      }
      #expect(try Data(contentsOf: fixture.configuration) == original)
      #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    }
  }

  @Test
  func existingSelectorValuesAreReplacedWithoutRewritingTheirFormatting() throws {
    let original = Data(
      """
      [Setting]
      current_theme          = marketplace   ; keep theme comment
      color_scheme\t=\tDefault\t# keep scheme comment
      inject_css = 1

      [Preprocesses]
      disable_sentry = 1

      """.utf8
    )
    let fixture = try SpicetifySetupFixture(
      configuration: original,
      createColorLink: true
    )
    defer { fixture.remove() }
    let css = try Data(contentsOf: fixture.userCSS)

    let setup = try fixture.setup(dryRun: false)

    #expect(setup.map(\.status) == [.owned, .external])
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == """
        [Setting]
        current_theme          = text
        color_scheme\t=\tMacarchyCurrent
        inject_css = 1

        [Preprocesses]
        disable_sentry = 1

        """
    )
    #expect(try Data(contentsOf: fixture.userCSS) == css)

    let teardown = try fixture.teardown(dryRun: false)
    #expect(teardown.map(\.status) == [.removed, .none])
    #expect(try Data(contentsOf: fixture.configuration) == original)
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)
  }

  @Test
  func laterSelectorFailureReportsTheEarlierOwnedLinkAndExactIdentity() throws {
    let original = Data("[Setting]\nmalformed provider setting\n".utf8)
    let fixture = try SpicetifySetupFixture(configuration: original)
    defer { fixture.remove() }
    let error: any Error
    do {
      _ = try fixture.setup(dryRun: false)
      Issue.record("Expected the malformed selector configuration to fail")
      return
    } catch let caught {
      error = caught
    }

    let results = SetupOwnershipManager.failureResults(error, homeDirectory: fixture.home)

    #expect(results.map(\.id) == ["spicetify.selectors", "spicetify.color-link"])
    #expect(results.map(\.status) == [.failed, .owned])
    #expect(results.map(\.mutationAttempted) == [false, true])
    #expect(results.first?.target == fixture.configuration.path)
    #expect(try Data(contentsOf: fixture.configuration) == original)
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)

    let teardown = try fixture.teardown(dryRun: false)
    #expect(teardown.map(\.status) == [.none, .removed])
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func existingColorFileIsNeverClaimedOrReplaced() throws {
    let configuration = Data(
      "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n".utf8
    )
    let fixture = try SpicetifySetupFixture(configuration: configuration)
    defer { fixture.remove() }
    let staticColors = Data("[Legacy]\nmain = 000000\n".utf8)
    try staticColors.write(to: fixture.colorLink)
    let css = try Data(contentsOf: fixture.userCSS)

    #expect(
      throws: SetupOwnershipError.conflictingThemeLink(
        "spicetify.color-link",
        fixture.colorLink
      )
    ) {
      _ = try fixture.setup(dryRun: false)
    }
    #expect(try Data(contentsOf: fixture.colorLink) == staticColors)
    #expect(try Data(contentsOf: fixture.configuration) == configuration)
    #expect(try Data(contentsOf: fixture.userCSS) == css)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }
}

private enum SpicetifySetupTestError: Error {
  case interrupted
}

private final class SpicetifySetupFixture: @unchecked Sendable {
  let root: URL
  let home: URL

  init(
    configuration: Data?,
    externallyOwned: Bool = false,
    createColorLink: Bool = false
  ) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-spicetify-ownership-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    let spicetifyDirectory: URL
    if externallyOwned {
      spicetifyDirectory = root.appending(
        path: "dotfiles/spicetify", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: home.appending(path: ".config", directoryHint: .isDirectory),
        withIntermediateDirectories: true
      )
    } else {
      spicetifyDirectory = home.appending(
        path: ".config/spicetify", directoryHint: .isDirectory)
    }
    if configuration != nil || createColorLink || externallyOwned {
      let themeDirectory = spicetifyDirectory.appending(
        path: "Themes/\(SpicetifyAdapter.themeName)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: themeDirectory,
        withIntermediateDirectories: true
      )
      if let configuration {
        try configuration.write(to: spicetifyDirectory.appending(path: "config-xpui.ini"))
      }
      try Data("/* provider-owned behavior */\n".utf8).write(
        to: themeDirectory.appending(path: "user.css")
      )
      if createColorLink {
        try FileManager.default.createSymbolicLink(
          at: themeDirectory.appending(path: "color.ini"),
          withDestinationURL: colorDestination
        )
      }
    }
    if externallyOwned {
      try FileManager.default.createSymbolicLink(
        at: home.appending(path: ".config/spicetify"),
        withDestinationURL: spicetifyDirectory
      )
    }
  }

  var stateRoot: URL {
    home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
  }

  var configuration: URL {
    home.appending(path: ".config/spicetify/config-xpui.ini")
  }

  var colorLink: URL {
    home.appending(
      path: ".config/spicetify/Themes/\(SpicetifyAdapter.themeName)/color.ini")
  }

  var colorDestination: URL {
    stateRoot.appending(path: "current/\(SpicetifyAdapter.outputPath)")
  }

  var userCSS: URL {
    home.appending(
      path: ".config/spicetify/Themes/\(SpicetifyAdapter.themeName)/user.css")
  }

  var manifest: URL {
    stateRoot.appending(path: "state/setup/ownership.json")
  }

  var selectorsBackup: URL {
    stateRoot.appending(path: "state/setup/backups/spicetify-config-xpui.ini")
  }

  func setup(
    manager: SetupOwnershipManager = SetupOwnershipManager(),
    dryRun: Bool
  ) throws -> [SetupIntegrationResult] {
    let context = SetupOwnershipManager.Context(homeDirectory: home)
    var records = try manager.readRecords(context: context)
    return try manager.setupSpicetifyIntegrations(
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func teardown(
    manager: SetupOwnershipManager = SetupOwnershipManager(),
    dryRun: Bool
  ) throws -> [SetupIntegrationResult] {
    let context = SetupOwnershipManager.Context(homeDirectory: home)
    var records = try manager.readRecords(context: context)
    return try manager.teardownSpicetifyIntegrations(
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func colorLinkDestination() throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: colorLink.path)
  }

  func manifestJSON() throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
    )
  }

  func permissions(at url: URL) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
