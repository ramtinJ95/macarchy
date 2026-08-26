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

    let result = try SetupOwnershipManager().setup(
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(result.status == .external)
    #expect(!result.mutationAttempted)
    #expect(try fixture.configuration() == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
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

    let dryRun = try SetupOwnershipManager().setup(
      homeDirectory: fixture.home,
      dryRun: true
    )
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
    let manifest = try decode(
      OwnershipManifest.self,
      String(decoding: Data(contentsOf: fixture.manifest), as: UTF8.self)
    )

    #expect(setup.succeeded)
    #expect(setupReport.outcome == "ready")
    #expect(setupReport.mutationAttempted)
    #expect(setupReport.integration.status == "owned")
    #expect(manifest.schemaVersion == 1)
    #expect(manifest.records.map(\.phase) == ["applied"])
    #expect(try fixture.configuration() == "font_size 13\n\(fixture.includeDirective)\n")
    #expect(try fixture.permissions() == 0o600)
    #expect(try fixture.extendedAttribute(name: "io.github.macarchy.test") == "preserve")
    #expect(try fixture.permissions(at: fixture.backup) == 0o600)

    let repeated = try SetupOwnershipManager().setup(
      homeDirectory: fixture.home,
      dryRun: false
    )
    #expect(repeated.status == .owned)
    #expect(!repeated.mutationAttempted)

    let teardownDryRun = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: true, json: true)
    let teardownPreview = try decode(TeardownReport.self, teardownDryRun.output)
    #expect(teardownPreview.integration.status == "planned")
    #expect(try fixture.configuration().contains(fixture.includeDirective))

    let teardown = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: false, json: true)
    let teardownReport = try decode(TeardownReport.self, teardown.output)

    #expect(teardown.succeeded)
    #expect(teardownReport.integration.status == "removed")
    #expect(try fixture.configuration() == "font_size 13\n")
    #expect(try fixture.permissions() == 0o600)
    #expect(try fixture.extendedAttribute(name: "io.github.macarchy.test") == "preserve")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")

    let repeatedTeardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )
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

      let resumed = try SetupOwnershipManager().setup(
        homeDirectory: fixture.home,
        dryRun: false
      )
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
        try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false).status
          == .removed
      )
      #expect(try fixture.configuration() == "font_size 13\n")
    }
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
    let activation = Task.detached {
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
    for _ in 0..<100 where !preflightEntered.withLock({ $0 }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(preflightEntered.withLock { $0 })
    let setupCompleted = Mutex(false)
    let setup = Task.detached {
      let result = try SetupOwnershipManager().setup(
        homeDirectory: home,
        dryRun: false
      )
      setupCompleted.withLock { $0 = true }
      return result
    }

    try await Task.sleep(for: .milliseconds(25))
    #expect(!setupCompleted.withLock { $0 })
    #expect(try fixture.configuration() == "font_size 13\n")
    releasePreflight.signal()

    _ = try await activation.value
    #expect(try await setup.value.status == .owned)
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
    #expect(report.integration.status == "failed")
    #expect(report.integration.message == expected.description)
    #expect(!report.integration.mutationAttempted)
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
    #expect(report.integration.status == "failed")
    #expect(report.integration.message == expected.description)
    #expect(!report.integration.mutationAttempted)
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
    #expect(report.integration.status == "failed")
    #expect(report.integration.message == expected.description)
    #expect(!report.integration.mutationAttempted)
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
      setupIntegration: { homeDirectory, dryRun in
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

private enum FixtureError: Error {
  case interrupted
}

private final class Fixture {
  let root: URL
  let home: URL

  init(configuration: String? = nil) throws {
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

  var replacement: URL {
    kittyConfiguration.deletingLastPathComponent()
      .appending(path: ".macarchy-kitty-transaction")
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
  let integration: IntegrationReport
}

private struct TeardownReport: Decodable {
  let integration: IntegrationReport
}

private struct IntegrationReport: Decodable {
  let status: String
  let message: String
  let mutationAttempted: Bool
}

private struct OwnershipManifest: Decodable {
  let schemaVersion: Int
  let records: [OwnershipRecord]
}

private struct OwnershipRecord: Decodable {
  let phase: String
}
