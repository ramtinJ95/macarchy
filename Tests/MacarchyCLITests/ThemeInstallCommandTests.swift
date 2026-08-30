import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeInstallCommandTests {
  @Test
  func builtInCollisionFailsBeforeFetchOrStateMutation() async throws {
    let fixture = try ThemeInstallFixture()
    defer { fixture.remove() }
    let processCalls = ProcessCallCounter()

    let execution = try await fixture.runner(processCalls: processCalls).execute(
      source: "https://github.com/example/omarchy-catppuccin-mocha-theme",
      repository: fixture.repository,
      userThemesRoot: fixture.userThemes,
      stateRoot: fixture.stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: false
    )

    #expect(!execution.succeeded)
    #expect(execution.output.contains("would shadow a built-in package"))
    #expect(processCalls.value.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))
  }

  @Test
  func activationPrecommitFailureRestoresPackageAndCanonicalGeneration() async throws {
    let fixture = try ThemeInstallFixture()
    defer { fixture.remove() }
    try fixture.preparePreviousPackageAndCanonicalTheme()
    let previousGeneration = try fixture.activeManifest().generationID
    let runner = fixture.runner(activationFailure: ThemeActivationError.cannotReplaceCurrent(EIO))

    let execution = try await runner.execute(
      source: fixture.source,
      repository: fixture.repository,
      userThemesRoot: fixture.userThemes,
      stateRoot: fixture.stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: true
    )

    #expect(!execution.succeeded)
    let output = try #require(
      JSONSerialization.jsonObject(with: Data(execution.output.utf8)) as? [String: Any]
    )
    #expect(output["outcome"] as? String == "precommit_failure")
    #expect(output["installed"] as? Bool == false)
    #expect(output["committed"] as? Bool == false)
    #expect(try fixture.installedCommit() == ThemeInstallFixture.oldCommit)
    #expect(try fixture.activeManifest().generationID == previousGeneration)
    #expect(try fixture.transactionResidue().isEmpty)
  }

  @Test
  func fetchAndConversionFailuresNeverPublishTheReplacement() async throws {
    for failure in [ThemeInstallFixture.Failure.fetch, .conversion] {
      let fixture = try ThemeInstallFixture()
      defer { fixture.remove() }
      try fixture.preparePreviousPackageAndCanonicalTheme()
      let previousGeneration = try fixture.activeManifest().generationID

      let execution = try await fixture.runner(failure: failure).execute(
        source: fixture.source,
        repository: fixture.repository,
        userThemesRoot: fixture.userThemes,
        stateRoot: fixture.stateRoot,
        consumerPaths: testConsumerPaths(),
        dryRun: false,
        json: false
      )

      #expect(!execution.succeeded)
      #expect(execution.output.contains("Installed package: unchanged."))
      #expect(execution.output.contains("Canonical state: unchanged."))
      #expect(try fixture.installedCommit() == ThemeInstallFixture.oldCommit)
      #expect(try fixture.activeManifest().generationID == previousGeneration)
      #expect(try fixture.transactionResidue().isEmpty)
    }
  }

  @Test
  func dryRunConvertsAndPreflightsWithoutCreatingState() async throws {
    let fixture = try ThemeInstallFixture()
    defer { fixture.remove() }

    let execution = try await fixture.runner().execute(
      source: fixture.source,
      repository: fixture.repository,
      userThemesRoot: fixture.userThemes,
      stateRoot: fixture.stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: true,
      json: false
    )

    #expect(execution.succeeded)
    #expect(execution.output.contains("is valid"))
    #expect(execution.output.contains("would install"))
    #expect(execution.output.contains("Imported backgrounds:\n- backgrounds/purple.png"))
    #expect(execution.output.contains("Warnings: missing_asset_provenance"))
    #expect(execution.output.contains("- herdr [required]: pending"))
    #expect(execution.output.contains("- neovim [required]: pending"))
    #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))

    let jsonExecution = try await fixture.runner().execute(
      source: fixture.source,
      repository: fixture.repository,
      userThemesRoot: fixture.userThemes,
      stateRoot: fixture.stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: true,
      json: true
    )
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(jsonExecution.output.utf8)) as? [String: Any]
    )
    let conversion = try #require(report["conversion"] as? [String: Any])
    let reconciliation = try #require(report["reconciliation"] as? [[String: Any]])
    #expect(conversion["resolved_commit"] as? String == ThemeInstallFixture.newCommit)
    #expect((conversion["warnings"] as? [String]) == ["missing_asset_provenance"])
    #expect(reconciliation.count == ThemeActivationCoordinator.adapterRequirements.count)
    #expect(
      reconciliation.first { $0["adapter_id"] as? String == "herdr" }?["status"] as? String
        == "pending"
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))
  }

  @Test
  func committedReinstallPublishesCurrentInventoryAndSlackPayload() async throws {
    let fixture = try ThemeInstallFixture()
    defer { fixture.remove() }
    try fixture.preparePreviousPackageAndCanonicalTheme()
    let manifest = GenerationManifest(
      generationID: "g-imported",
      themeID: "purple-dream",
      themeSchemaVersion: 1,
      inputDigest: "sha256:" + String(repeating: "a", count: 64),
      themeDigest: "sha256:" + String(repeating: "b", count: 64),
      rendererVersions: ["normalized_theme": 1],
      artifacts: [:]
    )
    let activation = ThemeActivationResult(
      manifest: manifest,
      reconciliation: try ReconciliationRecord(manifest: manifest, results: [])
    )

    let execution = try await fixture.runner(activationResult: activation).execute(
      source: fixture.source,
      repository: fixture.repository,
      userThemesRoot: fixture.userThemes,
      stateRoot: fixture.stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: true
    )

    #expect(execution.succeeded)
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(execution.output.utf8)) as? [String: Any]
    )
    #expect(report["committed"] as? Bool == true)
    #expect(
      report["slack_theme"] as? String
        == "#1a0d2e,#8b9aff,#5ffbf1,#ff6ec7"
    )
    #expect(try fixture.installedCommit() == ThemeInstallFixture.newCommit)
    let reinstalled = try ThemePackageLoader().load(packageURL: fixture.installedPackage)
    #expect(reinstalled.backgrounds.map(\.path) == ["backgrounds/purple.png"])
    #expect(try fixture.transactionResidue().isEmpty)
  }
}

private struct ThemeInstallFixture {
  enum Failure {
    case fetch
    case conversion
  }

  enum InjectedFailure: Error {
    case unexpectedActivation
  }

  static let oldCommit = String(repeating: "1", count: 40)
  static let newCommit = String(repeating: "2", count: 40)

  let root: URL
  let checkout: URL
  let invalidCheckout: URL
  let staging: URL
  let stateRoot: URL
  let builtInThemes: URL
  let source = "https://github.com/example/omarchy-purple-dream-theme"

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-theme-install-command-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    checkout = root.appending(path: "checkout", directoryHint: .isDirectory)
    invalidCheckout = root.appending(path: "invalid-checkout", directoryHint: .isDirectory)
    staging = root.appending(path: "staging", directoryHint: .isDirectory)
    stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    builtInThemes = Self.repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: invalidCheckout, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Self.repositoryRoot.appending(path: "Tests/Fixtures/Omarchy/purple-dream/colors.toml"),
      to: checkout.appending(path: "colors.toml")
    )
    try FileManager.default.createDirectory(
      at: checkout.appending(path: "backgrounds"),
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
      at: Self.repositoryRoot.appending(path: "Tests/Fixtures/Images/test-wallpaper.png"),
      to: checkout.appending(path: "backgrounds/purple.png")
    )
    try "ignored".write(
      to: invalidCheckout.appending(path: "neovim.lua"),
      atomically: false,
      encoding: .utf8
    )
  }

  var userThemes: URL {
    stateRoot.appending(path: "themes", directoryHint: .isDirectory)
  }

  var installedPackage: URL {
    userThemes.appending(path: "purple-dream", directoryHint: .isDirectory)
  }

  var repository: ThemeRepository {
    ThemeRepository(builtInRoot: builtInThemes, userRoot: userThemes)
  }

  func preparePreviousPackageAndCanonicalTheme() throws {
    try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)
    _ = try OmarchyThemeConverter().convert(
      staged: StagedOmarchyTheme(
        themeID: "purple-dream",
        sourceURL: URL(string: "https://github.com/example/purple-dream")!,
        resolvedCommit: Self.oldCommit,
        checkoutURL: checkout
      ),
      to: installedPackage
    )
    try rewriteInstalledPackageWithOlderWallpaperContract()
    let authored = try ThemePackageLoader().load(
      packageURL: builtInThemes.appending(path: "catppuccin-mocha")
    )
    _ = try activator().activate(package: authored)
  }

  func runner(
    failure: Failure? = nil,
    activationFailure: Error? = nil,
    activationResult: ThemeActivationResult? = nil,
    processCalls: ProcessCallCounter? = nil
  ) -> ThemeInstallCommandRunner {
    let selectedCheckout = failure == .conversion ? invalidCheckout : checkout
    let processRunner = ProcessRunner { request in
      processCalls?.value.withLock { $0 += 1 }
      if request.arguments.contains("clone") {
        if failure == .fetch {
          return ProcessResult(terminationStatus: 128, output: "injected fetch failure")
        }
        let destination = URL(
          filePath: request.arguments.last!,
          directoryHint: .isDirectory
        )
        try FileManager.default.copyItem(at: selectedCheckout, to: destination)
        return ProcessResult(terminationStatus: 0, output: "")
      }
      return ProcessResult(terminationStatus: 0, output: Self.newCommit)
    }
    let converter = OmarchyThemeConverter(
      stager: OmarchyThemeStager(temporaryRoot: staging, processRunner: processRunner)
    )
    let activation = ThemeSetCommandRunner(
      preflight: { _, _, _, _ in },
      activate: { _, _, _, _, _ in
        if let activationResult {
          return activationResult
        }
        guard let activationFailure else {
          throw InjectedFailure.unexpectedActivation
        }
        throw activationFailure
      }
    )
    return ThemeInstallCommandRunner(
      converter: converter,
      installer: OmarchyThemePackageInstaller(),
      activation: activation
    )
  }

  func installedCommit() throws -> String {
    let data = try Data(contentsOf: installedPackage.appending(path: "import.json"))
    let report = try JSONDecoder().decode(OmarchyThemeConversionReport.self, from: data)
    return report.resolvedCommit
  }

  func activeManifest() throws -> GenerationManifest {
    try ReconciliationStatusStore(root: stateRoot).activeManifest()
  }

  func transactionResidue() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: userThemes.path)
      .filter { $0.hasPrefix(".macarchy-install-") }
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  private func rewriteInstalledPackageWithOlderWallpaperContract() throws {
    let manifestURL = installedPackage.appending(path: "theme.toml")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    let marker = try #require(manifest.range(of: "\n[[backgrounds]]\n"))
    let olderManifest =
      manifest[..<marker.lowerBound] + """

        [wallpaper]
        path = "wallpapers/default.png"
        source = "Older installed fixture"
        author = "Fixture"
        license = "Personal use"
        """ + "\n"
    try String(olderManifest).write(to: manifestURL, atomically: true, encoding: .utf8)
  }

  private func activator() -> ThemeActivator {
    Self.activator(root: stateRoot)
  }

  private static func activator(root: URL) -> ThemeActivator {
    ThemeActivator(
      root: root,
      faultInjector: { _ in },
      postDarwinNotification: { _ in }
    )
  }

  private static var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private final class ProcessCallCounter: Sendable {
  let value = Mutex(0)
}
