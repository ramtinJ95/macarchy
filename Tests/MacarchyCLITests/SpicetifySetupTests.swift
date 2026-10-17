import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

// Teardown takes the process-wide Spicetify lock synchronously. A lock holder in
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
  func absentOptionalProviderTeardownIsUnownedAndLockFree() throws {
    let fixture = try SpicetifySetupFixture(configuration: nil)
    defer { fixture.remove() }

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
  func teardownLeavesUnownedSpicetifyConfigurationAlone() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
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

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )

    expectStatuses(teardown, unownedTeardownStatuses)
    #expect(try Data(contentsOf: context.spicetifyConfiguration) == original)
    #expect(try Data(contentsOf: userCSS) == css)
    #expect(!FileManager.default.fileExists(atPath: context.spicetifyColorLink.path))
    #expect(!FileManager.default.fileExists(atPath: context.manifestURL.path))
  }

  @Test
  func ownedSelectorsAndColorLinkRestoreProviderBytes() throws {
    let original =
      "[Setting]\r\n; provider comment\r\ninject_css = 1\r\nreplace_colors = 1\r\n"
      + "\r\n[Backup]\r\nversion = 1.2.3\r\n"
    let fixture = try SpicetifySetupFixture(configuration: Data(original.utf8))
    defer { fixture.remove() }
    let css = try Data(contentsOf: fixture.userCSS)
    try fixture.writeLegacyOwnership([
      fixture.legacyFileRecord(
        SetupOwnershipManager.spicetifySelectorsID,
        original: original,
        installed: "[Setting]\r\ncurrent_theme = text\r\ncolor_scheme = MacarchyCurrent\r\n"
          + "; provider comment\r\ninject_css = 1\r\nreplace_colors = 1\r\n"
          + "\r\n[Backup]\r\nversion = 1.2.3\r\n"
      ),
      fixture.legacyThemeLink(SetupOwnershipManager.spicetifyColorLinkID),
    ])

    let teardown = try fixture.teardown(dryRun: false)

    expectStatuses(
      teardown,
      ["spicetify.selectors": .removed, "spicetify.color-link": .removed]
    )
    #expect(try Data(contentsOf: fixture.configuration) == Data(original.utf8))
    #expect(try Data(contentsOf: fixture.userCSS) == css)
    #expect(throws: (any Error).self) {
      _ = try fixture.colorLinkDestination()
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.selectorsBackup.path))
  }

  @Test
  func providerRewriteOfUnrelatedFieldsSurvivesTeardown() throws {
    let fixture = try SpicetifySetupFixture(
      configuration: Data(marketplaceConfiguration.utf8),
      createColorLink: true
    )
    defer { fixture.remove() }
    let providerRewrite = """
      [Setting]
      spotify_path = /Applications/Spotify.app/Contents/Resources
      current_theme = text
      color_scheme = MacarchyCurrent
      inject_css = 0

      [Preprocesses]
      disable_sentry = 0

      """
    try fixture.writeLegacyOwnership([
      fixture.legacySelectors(onDisk: providerRewrite)
    ])

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
  func teardownWaitsForTheSharedSpicetifyLock() async throws {
    let executor = SpicetifySetupBlockingScope.executor
    // Synchronous boundary for bounded gates on the explicitly preferred executor.
    func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) -> DispatchTimeoutResult {
      semaphore.wait(timeout: timeout)
    }

    let fixture = try SpicetifySetupFixture(
      configuration: Data(marketplaceConfiguration.utf8),
      createColorLink: true
    )
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([fixture.legacySelectors()])
    let refreshEntered = DispatchSemaphore(value: 0)
    let releaseLock = DispatchSemaphore(value: 0)
    let reconciliationFinished = DispatchSemaphore(value: 0)
    let teardownStarted = DispatchSemaphore(value: 0)
    let teardownFinished = DispatchSemaphore(value: 0)
    let reconciliationError = Mutex<String?>(nil)
    let teardownError = Mutex<String?>(nil)
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
        "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\ninject_css = 0\n".utf8
      )
      try providerEdit.write(to: fixture.configuration, options: .atomic)

      group.addTask(executorPreference: executor) { @Sendable in
        defer { teardownFinished.signal() }
        teardownStarted.signal()
        do {
          _ = try fixture.teardown(dryRun: false)
        } catch {
          teardownError.withLock { $0 = String(describing: error) }
        }
      }
      try #require(wait(teardownStarted, timeout: .now() + 5) == .success)
      // Started is not proof of a lock attempt; retain the negative window and
      // the unchanged-file/manifest checks while refresh demonstrably holds it.
      #expect(wait(teardownFinished, timeout: .now() + 0.1) == .timedOut)
      #expect(try Data(contentsOf: fixture.configuration) == providerEdit)
      #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))

      releaseLock.signal()
      try #require(wait(reconciliationFinished, timeout: .now() + 5) == .success)
      try #require(wait(teardownFinished, timeout: .now() + 5) == .success)
      try await group.waitForAll()
    }
    #expect(reconciliationError.withLock { $0 } == nil)
    #expect(teardownError.withLock { $0 } == nil)
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\ninject_css = 0\n"
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func interruptedTeardownPreservesProviderFieldsAndResumes() throws {
    for checkpoint in [
      SetupOwnershipCheckpoint.replacementSwapped,
      .targetWritten,
    ] {
      let fixture = try SpicetifySetupFixture(
        configuration: Data(marketplaceConfiguration.utf8),
        createColorLink: true
      )
      defer { fixture.remove() }
      try fixture.writeLegacyOwnership([
        fixture.legacySelectors(
          onDisk:
            "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\ninject_css = 0\n"
        )
      ])
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
  func teardownRestoresAnInterruptedSelectorReplacementFromItsResidue() throws {
    let original = "[Setting]\ninject_css = 1\n"
    let fixture = try SpicetifySetupFixture(
      configuration: Data(original.utf8),
      createColorLink: true
    )
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([
      fixture.legacyFileRecord(
        SetupOwnershipManager.spicetifySelectorsID,
        original: original,
        installed:
          "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\ninject_css = 1\n",
        phase: .prepared,
        residue: original
      )
    ])

    let teardown = try fixture.teardown(dryRun: false)

    expectStatuses(
      teardown,
      ["spicetify.selectors": .removed, "spicetify.color-link": .none]
    )
    #expect(try Data(contentsOf: fixture.configuration) == Data(original.utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.replacement.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.selectorsBackup.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)
  }

  @Test
  func existingSelectorValuesAreRestoredWithoutRewritingTheirFormatting() throws {
    let original = """
      [Setting]
      current_theme          = marketplace   ; keep theme comment
      color_scheme\t=\tDefault\t# keep scheme comment
      inject_css = 1

      [Preprocesses]
      disable_sentry = 1

      """
    let fixture = try SpicetifySetupFixture(
      configuration: Data(original.utf8),
      createColorLink: true
    )
    defer { fixture.remove() }
    let css = try Data(contentsOf: fixture.userCSS)
    try fixture.writeLegacyOwnership([
      fixture.legacyFileRecord(
        SetupOwnershipManager.spicetifySelectorsID,
        original: original,
        installed: """
          [Setting]
          current_theme          = text
          color_scheme\t=\tMacarchyCurrent
          inject_css = 1

          [Preprocesses]
          disable_sentry = 1

          """
      )
    ])

    let teardown = try fixture.teardown(dryRun: false)
    expectStatuses(
      teardown,
      ["spicetify.selectors": .removed, "spicetify.color-link": .none]
    )
    #expect(try Data(contentsOf: fixture.configuration) == Data(original.utf8))
    #expect(try Data(contentsOf: fixture.userCSS) == css)
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)
  }

  @Test
  func selectorParserRejectsMalformedAndDuplicateState() throws {
    let malformedConfigurations = [
      "[Setting]\ncurrent_theme = text\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n",
      "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n[Setting]\n",
      "[Setting]\nmalformed provider setting\n",
      "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n[Backup]\nmalformed later section\n",
      "[Backup]\nversion = 1\n",
    ]
    let fixture = try SpicetifySetupFixture(configuration: nil)
    defer { fixture.remove() }
    for configuration in malformedConfigurations {
      do {
        _ = try SetupOwnershipManager().spicetifySelection(
          Data(configuration.utf8),
          target: fixture.configuration
        )
        Issue.record("Expected malformed Spicetify configuration to fail")
      } catch SetupOwnershipError.invalidConfiguration(let id, let target, _) {
        #expect(id == "spicetify.selectors")
        #expect(target == fixture.configuration)
      }
    }
  }

  @Test
  func teardownRemovesALoneColorLinkRecordBesideMalformedConfiguration() throws {
    let original = Data("[Setting]\nmalformed provider setting\n".utf8)
    let fixture = try SpicetifySetupFixture(configuration: original)
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([
      fixture.legacyThemeLink(SetupOwnershipManager.spicetifyColorLinkID)
    ])

    let teardown = try fixture.teardown(dryRun: false)
    expectStatuses(
      teardown,
      ["spicetify.selectors": .none, "spicetify.color-link": .removed]
    )
    #expect(try Data(contentsOf: fixture.configuration) == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }
}

private enum SpicetifySetupTestError: Error {
  case interrupted
}

private let marketplaceConfiguration =
  "[Setting]\ncurrent_theme = marketplace\ncolor_scheme = Default\ninject_css = 1\n"

private final class SpicetifySetupFixture: LegacySetupOwnershipFixture, @unchecked Sendable {
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

  var replacement: URL {
    configuration.deletingLastPathComponent()
      .appending(path: ".macarchy-spicetify-config-transaction")
  }

  /// The selector record an older release left for the marketplace configuration.
  func legacySelectors(onDisk: String? = nil) throws -> SetupOwnershipRecord {
    try legacyFileRecord(
      SetupOwnershipManager.spicetifySelectorsID,
      original: marketplaceConfiguration,
      installed:
        "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\ninject_css = 1\n",
      onDisk: onDisk
    )
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

  func remove() {
    removeSpicetifyTestRoot(root)
  }
}
