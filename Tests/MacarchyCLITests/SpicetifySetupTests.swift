import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

// Setup takes the process-wide Spicetify lock synchronously. A lock holder in
// another suite may need the cooperative pool to resume and release it.
private struct SpicetifySetupBlockingScope: SuiteTrait, TestTrait, TestScoping {
  let isRecursive = true
  static let executor = BlockingTaskExecutor(label: "spicetify-setup-tests")

  func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    try await withTaskExecutorPreference(Self.executor, operation: function)
  }
}

@Suite(.serialized, SpicetifySetupBlockingScope())
struct SpicetifySetupTests {
  @Test
  func absentOptionalProviderIsExplicitlyDisabledAndSuccessful() throws {
    let fixture = try SpicetifySetupFixture(configuration: nil)
    defer { fixture.remove() }

    let setup = try fixture.setup(dryRun: false)

    expectStatuses(
      setup,
      ["spicetify.selectors": .disabled, "spicetify.color-link": .disabled]
    )
    #expect(setup.allSatisfy { $0.succeeded })
    #expect(setup.allSatisfy { !$0.mutationAttempted })
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.stateRoot.appending(path: "run/spicetify.lock").path
      )
    )

    let teardown = try fixture.teardown(dryRun: false)
    expectStatuses(
      teardown,
      ["spicetify.selectors": .none, "spicetify.color-link": .none]
    )
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
  func centralSetupLeavesNewSpicetifyConfigurationForEnvironmentOwnership() throws {
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

    expectStatuses(setup, externalFixtureStatuses)
    #expect(!setup.first { $0.id == "spicetify.selectors" }!.mutationAttempted)
    #expect(!setup.first { $0.id == "spicetify.color-link" }!.mutationAttempted)
    #expect(try Data(contentsOf: userCSS) == css)
    #expect(try Data(contentsOf: context.spicetifyConfiguration) == original)
    #expect(!FileManager.default.fileExists(atPath: context.spicetifyColorLink.path))

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )

    let teardownStatuses = externalFixtureStatuses.mapValues { _ in
      SetupIntegrationResult.Status.none
    }
    expectStatuses(teardown, teardownStatuses)
    #expect(try Data(contentsOf: context.spicetifyConfiguration) == original)
    #expect(try Data(contentsOf: userCSS) == css)
    #expect(!FileManager.default.fileExists(atPath: context.spicetifyColorLink.path))
    #expect(!FileManager.default.fileExists(atPath: context.manifestURL.path))
  }

  @Test
  func centralSetupBlocksBothPartialLegacyOwnershipShapesBeforeProviderMutation() throws {
    let original = Data(
      "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\ninject_css = 1\n".utf8
    )
    for retainedID in [
      SetupOwnershipManager.spicetifySelectorsID,
      SetupOwnershipManager.spicetifyColorLinkID,
    ] {
      let fixture = try SpicetifySetupFixture(configuration: original)
      defer { fixture.remove() }
      _ = try fixture.setup(dryRun: false)
      let manager = SetupOwnershipManager()
      let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
      let completeRecords = try manager.readRecords(context: context)
      let retained = try #require(completeRecords.first { $0.id == retainedID })
      try manager.persist(records: [retained], context: context)

      if retainedID == SetupOwnershipManager.spicetifySelectorsID {
        try FileManager.default.removeItem(at: fixture.colorLink)
      } else {
        try FileManager.default.removeItem(at: fixture.selectorsBackup)
        try original.write(to: fixture.configuration, options: .atomic)
      }
      let beforeManifest = try Data(contentsOf: fixture.manifest)
      let beforeConfiguration = try Data(contentsOf: fixture.configuration)
      let beforeLink = try? fixture.colorLinkDestination()
      var excluded = Set(manager.consumerSetupPlans(context: context).map(\.consumerID))
      excluded.remove(.spicetify)

      #expect(
        throws: SetupOwnershipError.invalidManifest(
          "legacy Spicetify ownership must contain both spicetify.selectors and spicetify.color-link"
        )
      ) {
        _ = try manager.setup(
          homeDirectory: fixture.home,
          dryRun: false,
          excluding: excluded
        )
      }
      #expect(try Data(contentsOf: fixture.manifest) == beforeManifest)
      #expect(try Data(contentsOf: fixture.configuration) == beforeConfiguration)
      #expect((try? fixture.colorLinkDestination()) == beforeLink)
    }
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

    expectStatuses(
      results,
      ["spicetify.selectors": .external, "spicetify.color-link": .external]
    )
    #expect(!results.contains { $0.mutationAttempted })
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

    expectStatuses(
      preview,
      ["spicetify.selectors": .planned, "spicetify.color-link": .planned]
    )
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

    expectStatuses(
      setup,
      ["spicetify.selectors": .owned, "spicetify.color-link": .owned]
    )
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
    expectStatuses(
      repeated,
      ["spicetify.selectors": .owned, "spicetify.color-link": .owned]
    )
    #expect(repeated.allSatisfy { !$0.mutationAttempted })

    let teardown = try fixture.teardown(dryRun: false)

    expectStatuses(
      teardown,
      ["spicetify.selectors": .removed, "spicetify.color-link": .removed]
    )
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

    expectStatuses(
      repeated,
      ["spicetify.selectors": .owned, "spicetify.color-link": .external]
    )
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
    expectStatuses(
      teardown,
      ["spicetify.selectors": .removed, "spicetify.color-link": .none]
    )
    #expect(try Data(contentsOf: fixture.configuration) == expected)
  }

  @Test
  func setupWaitsForTheSharedSpicetifyLock() async throws {
    let executor = SpicetifySetupBlockingScope.executor
    // Synchronous boundary for bounded gates on the explicitly preferred executor.
    func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) -> DispatchTimeoutResult {
      semaphore.wait(timeout: timeout)
    }

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
    let setupStarted = DispatchSemaphore(value: 0)
    let setupFinished = DispatchSemaphore(value: 0)
    let reconciliationError = Mutex<String?>(nil)
    let setupError = Mutex<String?>(nil)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")
    )
    _ = try ThemeActivator(root: fixture.stateRoot).activate(package: package)
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
      },
      spicetifyVersionProvider: { "2.44.0" },
      spotifyVersionProvider: { "1.2.50" }
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      // Release even if a prerequisite or file assertion throws. The group joins
      // both operations before the fixture's deferred removal can run.
      defer { releaseLock.signal() }
      group.addTask(executorPreference: executor) { @Sendable in
        defer { reconciliationFinished.signal() }
        do {
          _ = try await adapter.reconciliation().run()
        } catch {
          reconciliationError.withLock { $0 = String(describing: error) }
        }
      }
      try #require(wait(refreshEntered, timeout: .now() + 5) == .success)
      let providerEdit = Data(
        "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\n".utf8
      )
      try providerEdit.write(to: fixture.configuration, options: .atomic)

      group.addTask(executorPreference: executor) { @Sendable in
        defer { setupFinished.signal() }
        setupStarted.signal()
        do {
          _ = try fixture.setup(dryRun: false)
        } catch {
          setupError.withLock { $0 = String(describing: error) }
        }
      }
      try #require(wait(setupStarted, timeout: .now() + 5) == .success)
      // Started is not proof of a lock attempt; retain the negative window and
      // the unchanged-file/manifest checks while refresh demonstrably holds it.
      #expect(wait(setupFinished, timeout: .now() + 0.1) == .timedOut)
      #expect(try Data(contentsOf: fixture.configuration) == providerEdit)
      #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))

      releaseLock.signal()
      try #require(wait(reconciliationFinished, timeout: .now() + 5) == .success)
      try #require(wait(setupFinished, timeout: .now() + 5) == .success)
      try await group.waitForAll()
    }
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

      expectStatuses(
        resumed,
        ["spicetify.selectors": .removed, "spicetify.color-link": .none]
      )
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

    expectStatuses(
      resumed,
      ["spicetify.selectors": .owned, "spicetify.color-link": .external]
    )
    let teardown = try fixture.teardown(dryRun: false)
    expectStatuses(
      teardown,
      ["spicetify.selectors": .removed, "spicetify.color-link": .none]
    )
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

    expectStatuses(
      setup,
      ["spicetify.selectors": .owned, "spicetify.color-link": .external]
    )
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
    expectStatuses(
      teardown,
      ["spicetify.selectors": .removed, "spicetify.color-link": .none]
    )
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

    expectStatuses(
      results,
      ["spicetify.selectors": .failed, "spicetify.color-link": .owned]
    )
    #expect(
      results.first { $0.id == "spicetify.selectors" }?.mutationAttempted == false
    )
    #expect(results.first { $0.id == "spicetify.color-link" }?.mutationAttempted == true)
    #expect(results.first { $0.id == "spicetify.selectors" }?.target == fixture.configuration.path)
    #expect(try Data(contentsOf: fixture.configuration) == original)
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)

    let teardown = try fixture.teardown(dryRun: false)
    expectStatuses(
      teardown,
      ["spicetify.selectors": .none, "spicetify.color-link": .removed]
    )
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
    return try spicetifyPlan(manager: manager, context: context).setup(dryRun, &records)
  }

  func teardown(
    manager: SetupOwnershipManager = SetupOwnershipManager(),
    dryRun: Bool
  ) throws -> [SetupIntegrationResult] {
    let context = SetupOwnershipManager.Context(homeDirectory: home)
    var records = try manager.readRecords(context: context)
    return try spicetifyPlan(manager: manager, context: context).teardown(
      dryRun,
      &records
    )
  }

  private func spicetifyPlan(
    manager: SetupOwnershipManager,
    context: SetupOwnershipManager.Context
  ) throws -> ConsumerSetupPlan {
    try #require(
      manager.consumerSetupPlans(context: context).first {
        $0.consumerID == .spicetify
      }
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
    removeSpicetifyTestRoot(root)
  }
}
