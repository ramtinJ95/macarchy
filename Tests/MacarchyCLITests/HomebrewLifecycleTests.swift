import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct HomebrewLifecycleTests {
  @Test
  func unmanagedBuildRefusesBeforeHomebrewOrNetworkWork() throws {
    let runner = HomebrewUpdateRunner(
      buildInformation: { Self.build(installation: .unmanaged) },
      refreshRelease: { _ in
        Issue.record("Release check must not run")
        return Self.check(version: "0.2.0")
      },
      tapVersion: {
        Issue.record("Tap inspection must not run")
        return .available("0.2.0")
      },
      streamProcess: { _ in
        Issue.record("Homebrew must not run")
        return 0
      },
      verifyInstallation: { _ in Issue.record("Verification must not run") },
      writeEvidence: { _, _ in Issue.record("Evidence must not be written") },
      now: Date.init
    )

    let execution = try runner.execute(stateRoot: URL(filePath: "/unused"))

    #expect(execution.outcome == .refused)
    #expect(!execution.succeeded)
    #expect(execution.output.contains("brew install ramtinj95/tap/macarchy"))
  }

  @Test
  func newerReleaseThanTapReportsPackagingPendingWithoutUpgrade() throws {
    let requests = Mutex([ProcessRequest]())
    let runner = HomebrewUpdateRunner(
      buildInformation: { Self.build() },
      refreshRelease: { _ in Self.check(version: "0.2.0") },
      tapVersion: { .available("0.1.0") },
      streamProcess: { request in
        requests.withLock { $0.append(request) }
        return 0
      },
      verifyInstallation: { _ in Issue.record("Verification must not run") },
      writeEvidence: { _, _ in Issue.record("Evidence must not be written") },
      now: Date.init
    )

    let execution = try runner.execute(stateRoot: URL(filePath: "/state"))

    #expect(execution.outcome == .packagingPending)
    #expect(execution.succeeded)
    #expect(requests.withLock { $0.map(\.arguments) } == [["update"]])
  }

  @Test(
    arguments: [
      (installed: "0.3.0", upstream: "0.2.0", tap: "0.1.0"),
      (installed: "0.1.0", upstream: "0.2.0", tap: "0.3.0"),
    ])
  func inconsistentVersionEvidenceNeverUpgrades(
    installed: String,
    upstream: String,
    tap: String
  ) throws {
    let requests = Mutex([ProcessRequest]())
    let runner = HomebrewUpdateRunner(
      buildInformation: { Self.build(version: installed) },
      refreshRelease: { _ in Self.check(version: upstream) },
      tapVersion: { .available(tap) },
      streamProcess: { request in
        requests.withLock { $0.append(request) }
        return 0
      },
      verifyInstallation: { _ in Issue.record("Verification must not run") },
      writeEvidence: { _, _ in Issue.record("Evidence must not be written") },
      now: Date.init
    )

    let execution = try runner.execute(stateRoot: URL(filePath: "/state"))

    #expect(execution.outcome == .versionMismatch)
    #expect(!execution.succeeded)
    #expect(requests.withLock { $0.map(\.arguments) } == [["update"]])
  }

  @Test
  func stableTapUpgradeIsScopedStreamedAndVerified() throws {
    let requests = Mutex([ProcessRequest]())
    let verifiedVersions = Mutex([String]())
    let evidence = Mutex([HomebrewUpgradeEvidence]())
    let runner = HomebrewUpdateRunner(
      buildInformation: { Self.build() },
      refreshRelease: { _ in Self.check(version: "0.2.0") },
      tapVersion: { .available("0.2.0") },
      streamProcess: { request in
        requests.withLock { $0.append(request) }
        return 0
      },
      verifyInstallation: { version in
        verifiedVersions.withLock { $0.append(version) }
      },
      writeEvidence: { _, value in evidence.withLock { $0.append(value) } },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let execution = try runner.execute(stateRoot: URL(filePath: "/state"))

    #expect(execution.outcome == .updated)
    #expect(execution.succeeded)
    let streamedRequests = requests.withLock { $0 }
    #expect(
      streamedRequests.map(\.arguments)
        == [
          ["update"],
          ["upgrade", "--formula", "--no-ask", "ramtinj95/tap/macarchy"],
        ]
    )
    #expect(verifiedVersions.withLock { $0 } == ["0.2.0"])
    #expect(evidence.withLock { $0.map(\.outcome) } == [.started, .succeeded])
    let mutationEnvironment = [
      "HOMEBREW_NO_ANALYTICS": "1",
      "HOMEBREW_NO_AUTOREMOVE": "1",
      "HOMEBREW_NO_INSTALL_CLEANUP": "1",
      "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
    ]
    #expect(streamedRequests[0].environmentOverrides == mutationEnvironment)
    #expect(
      streamedRequests[1].environmentOverrides
        == mutationEnvironment.merging(
          ["HOMEBREW_NO_AUTO_UPDATE": "1"],
          uniquingKeysWith: { _, override in override }
        )
    )
  }

  @Test
  func metadataOrUpgradeFailureStopsAtTheFailedBoundary() throws {
    let metadataFailure = HomebrewUpdateRunner(
      buildInformation: { Self.build() },
      refreshRelease: { _ in
        Issue.record("Release check must not run")
        return Self.check(version: "0.2.0")
      },
      tapVersion: { .available("0.2.0") },
      streamProcess: { _ in 7 },
      verifyInstallation: { _ in Issue.record("Verification must not run") },
      writeEvidence: { _, _ in Issue.record("Evidence must not be written") },
      now: Date.init
    )
    let metadataExecution = try metadataFailure.execute(stateRoot: URL(filePath: "/state"))
    #expect(metadataExecution.outcome == .metadataRefreshFailed)
    #expect(!metadataExecution.succeeded)

    let requests = Mutex([ProcessRequest]())
    let upgradeFailure = HomebrewUpdateRunner(
      buildInformation: { Self.build() },
      refreshRelease: { _ in Self.check(version: "0.2.0") },
      tapVersion: { .available("0.2.0") },
      streamProcess: { request in
        requests.withLock {
          $0.append(request)
          return $0.count == 1 ? 0 : 9
        }
      },
      verifyInstallation: { _ in Issue.record("Verification must not run") },
      writeEvidence: { _, _ in },
      now: Date.init
    )
    let upgradeExecution = try upgradeFailure.execute(stateRoot: URL(filePath: "/state"))
    #expect(upgradeExecution.outcome == .upgradeFailed)
    #expect(!upgradeExecution.succeeded)
    #expect(
      requests.withLock { $0.map(\.arguments) }
        == [
          ["update"],
          ["upgrade", "--formula", "--no-ask", "ramtinj95/tap/macarchy"],
        ]
    )
  }

  @Test
  func failedPostUpgradeVerificationPrintsExactNonRollbackRecovery() throws {
    let evidence = Mutex([HomebrewUpgradeEvidence]())
    let runner = HomebrewUpdateRunner(
      buildInformation: { Self.build() },
      refreshRelease: { _ in Self.check(version: "0.2.0") },
      tapVersion: { .available("0.2.0") },
      streamProcess: { _ in 0 },
      verifyInstallation: { _ in throw LifecycleTestError.verification },
      writeEvidence: { _, value in evidence.withLock { $0.append(value) } },
      now: Date.init
    )

    let execution = try runner.execute(stateRoot: URL(filePath: "/state"))

    #expect(execution.outcome == .verificationFailed)
    #expect(!execution.succeeded)
    #expect(execution.output.contains(HomebrewUpdateRunner.recoveryCommand))
    #expect(execution.output.contains("no rollback is claimed"))
    #expect(execution.output.contains("/opt/homebrew/bin/macarchy update"))
    #expect(
      evidence.withLock { $0.map(\.outcome) }
        == [.started, .verificationFailed]
    )
    #expect(evidence.withLock { $0.last?.error } == "verification")
  }

  @Test
  func currentInstallationStillRunsFullVerification() throws {
    let runner = HomebrewUpdateRunner(
      buildInformation: { Self.build(version: "0.2.0") },
      refreshRelease: { _ in Self.check(version: "0.2.0") },
      tapVersion: { .available("0.2.0") },
      streamProcess: { _ in 0 },
      verifyInstallation: { _ in throw LifecycleTestError.verification },
      writeEvidence: { _, _ in Issue.record("No upgrade evidence should be written") },
      now: Date.init
    )

    let execution = try runner.execute(stateRoot: URL(filePath: "/state"))

    #expect(execution.outcome == .verificationFailed)
    #expect(!execution.succeeded)
    #expect(execution.output.contains("/opt/homebrew/bin/macarchy update"))
  }

  @Test
  func evidenceWriteFailuresRemainExplicitAtEachMutationBoundary() throws {
    let prewriteRequests = Mutex([ProcessRequest]())
    let prewriteFailure = Self.runner(
      streamProcess: { request in
        prewriteRequests.withLock { $0.append(request) }
        return 0
      },
      writeEvidence: { _, _ in throw LifecycleTestError.evidence }
    )
    let prewrite = try prewriteFailure.execute(stateRoot: URL(filePath: "/state"))
    #expect(prewrite.outcome == .evidenceWriteFailed)
    #expect(prewriteRequests.withLock { $0.map(\.arguments) } == [["update"]])

    let failureWrites = Mutex(0)
    let upgradeFailure = Self.runner(
      streamProcess: { request in request.arguments == ["update"] ? 0 : 9 },
      writeEvidence: { _, _ in
        try failureWrites.withLock {
          $0 += 1
          if $0 == 2 { throw LifecycleTestError.evidence }
        }
      }
    )
    let failed = try upgradeFailure.execute(stateRoot: URL(filePath: "/state"))
    #expect(failed.outcome == .upgradeFailed)
    #expect(failed.output.contains("Upgrade evidence could not be persisted"))

    let successWrites = Mutex(0)
    let successFailure = Self.runner(
      streamProcess: { _ in 0 },
      writeEvidence: { _, _ in
        try successWrites.withLock {
          $0 += 1
          if $0 == 2 { throw LifecycleTestError.evidence }
        }
      }
    )
    let succeeded = try successFailure.execute(stateRoot: URL(filePath: "/state"))
    #expect(succeeded.outcome == .evidenceWriteFailed)
    #expect(succeeded.output.contains("installed and verified"))
  }

  @Test
  func lifecycleLockSerializesOneRootAndRejectsASymlink() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-homebrew-lock-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = HomebrewUpdateLock(root: root)
    let secondStarted = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    let secondDone = DispatchSemaphore(value: 0)
    let failures = Mutex([String]())
    let queue = DispatchQueue(
      label: "io.github.ramtinj95.macarchy.tests.homebrew-lock",
      attributes: .concurrent
    )

    try lock.withLock {
      queue.async {
        defer { secondDone.signal() }
        secondStarted.signal()
        do {
          _ = try lock.withLock {
            secondEntered.signal()
          }
        } catch {
          failures.withLock { $0.append(String(describing: error)) }
        }
      }
      #expect(secondStarted.wait(timeout: .now() + 5) == .success)
      #expect(secondEntered.wait(timeout: .now()) == .timedOut)
    }
    #expect(secondDone.wait(timeout: .now() + 5) == .success)
    #expect(failures.withLock { $0 }.isEmpty)

    let lockURL = root.appending(path: "run/homebrew-update.lock")
    try FileManager.default.removeItem(at: lockURL)
    let target = root.appending(path: "lock-target")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
    #expect(throws: HomebrewUpdateLockError.self) {
      try lock.withLock {}
    }
  }

  @Test
  func upgradeEvidenceIsPrivateAndKeepsTheLatestAttempt() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-upgrade-evidence-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = HomebrewUpgradeEvidenceStore(root: root)
    let attemptedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let started = HomebrewUpgradeEvidence(
      attemptedAt: attemptedAt,
      installedVersion: "0.1.0",
      targetVersion: "0.2.0",
      outcome: .started,
      error: nil
    )
    let failed = HomebrewUpgradeEvidence(
      attemptedAt: attemptedAt,
      installedVersion: "0.1.0",
      targetVersion: "0.2.0",
      outcome: .verificationFailed,
      error: "missing resource"
    )

    try store.write(started)
    try store.write(failed)

    let persisted = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: store.evidenceURL))
        as? [String: Any]
    )
    let permissions = try #require(
      FileManager.default.attributesOfItem(atPath: store.evidenceURL.path)[.posixPermissions]
        as? NSNumber
    ).intValue

    #expect(persisted["schema_version"] as? Int == 1)
    #expect(persisted["installed_version"] as? String == "0.1.0")
    #expect(persisted["target_version"] as? String == "0.2.0")
    #expect(persisted["outcome"] as? String == "verification_failed")
    #expect(persisted["error"] as? String == "missing resource")
    #expect(permissions == 0o600)
  }

  @Test
  func installedLayoutVerifierReopensBuildMetadataThemesAndDocumentation() throws {
    let prefix = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-homebrew-prefix-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: prefix) }
    let executable = prefix.appending(path: "bin/macarchy")
    let resourceRoot = prefix.appending(path: "share/macarchy", directoryHint: .isDirectory)
    let documentationRoot = prefix.appending(
      path: "share/doc/macarchy",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: resourceRoot,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: documentationRoot,
      withIntermediateDirectories: true
    )
    try Data().write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    try FileManager.default.copyItem(
      at: URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Themes"),
      to: resourceRoot.appending(path: "themes")
    )
    try Data(
      """
      {"schema_version":1,"version":"0.2.0","revision":"\(String(repeating: "a", count: 40))"}

      """.utf8
    ).write(to: resourceRoot.appending(path: "build-info.json"))
    for file in [
      "INSTALL_RECEIPT.json",
      "share/doc/macarchy/CHANGELOG.md",
      "share/doc/macarchy/LICENSE",
      "share/doc/macarchy/theme-json.md",
    ] {
      try Data("{}\n".utf8).write(to: prefix.appending(path: file))
    }
    let requests = Mutex([ProcessRequest]())
    let verifier = HomebrewInstallationVerifier(
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        if request.arguments == ["--prefix", "ramtinj95/tap/macarchy"] {
          return ProcessResult(terminationStatus: 0, output: prefix.path)
        }
        return ProcessResult(
          terminationStatus: 0,
          output:
            #"{"schema_version":1,"version":"0.2.0","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","platform":"macos-arm64","installation":"homebrew"}"#
        )
      }
    )

    try verifier.verify(expectedVersion: "0.2.0")
    #expect(
      requests.withLock { $0.map(\.arguments) }
        == [
          ["--prefix", "ramtinj95/tap/macarchy"],
          ["version", "--json"],
        ]
    )
    try FileManager.default.removeItem(
      at: prefix.appending(path: "share/doc/macarchy/LICENSE")
    )
    try FileManager.default.createDirectory(
      at: prefix.appending(path: "share/doc/macarchy/LICENSE"),
      withIntermediateDirectories: false
    )
    #expect(throws: HomebrewVerificationError.self) {
      try verifier.verify(expectedVersion: "0.2.0")
    }
  }

  private static func build(
    version: String = "0.1.0",
    installation: InstallationOwnership = .homebrew
  ) -> MacarchyBuildInformation {
    MacarchyBuildInformation(
      version: version,
      revision: String(repeating: "a", count: 40),
      platform: "macos-arm64",
      installation: installation
    )
  }

  private static func runner(
    streamProcess: @escaping @Sendable (ProcessRequest) throws -> Int32,
    writeEvidence: @escaping @Sendable (URL, HomebrewUpgradeEvidence) throws -> Void
  ) -> HomebrewUpdateRunner {
    HomebrewUpdateRunner(
      buildInformation: { build() },
      refreshRelease: { _ in check(version: "0.2.0") },
      tapVersion: { .available("0.2.0") },
      streamProcess: streamProcess,
      verifyInstallation: { _ in },
      writeEvidence: writeEvidence,
      now: Date.init
    )
  }

  private static func check(version: String?) -> UpdateCheckExecution {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    return UpdateCheckExecution(
      cache: UpdateCacheDocument(
        lastAttempt: UpdateCheckAttempt(checkedAt: date, outcome: .success, error: nil),
        lastSuccess: UpdateCheckSuccess(
          checkedAt: date,
          release: version.map {
            StableRelease(
              version: $0,
              tag: "v\($0)",
              url: "https://github.com/ramtinJ95/macarchy/releases/tag/v\($0)"
            )
          },
          etag: nil,
          lastModified: nil
        )
      ),
      refreshed: true,
      succeeded: true
    )
  }
}

private enum LifecycleTestError: Error {
  case evidence
  case verification
}
