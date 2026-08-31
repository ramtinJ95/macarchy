import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct UpdateAwarenessTests {
  @Test
  func explicitCheckCachesStableReleaseAndReportsPackagingPending() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let requests = Mutex([UpdateHTTPRequest]())
    let checker = UpdateChecker(
      root: root,
      httpClient: UpdateHTTPClient { request in
        requests.withLock { $0.append(request) }
        return UpdateHTTPResponse(
          statusCode: 200,
          headers: [
            "ETag": #""release-etag""#,
            "Last-Modified": "Wed, 26 Aug 2026 10:00:00 GMT",
          ],
          body: releaseJSON(version: "0.2.0")
        )
      },
      now: { checkedAt }
    )
    let runner = commandRunner(
      root: root,
      checker: checker,
      installedVersion: "0.1.0",
      tapVersion: .available("0.1.0"),
      now: checkedAt
    )

    let execution = try runner.execute(stateRoot: root, refresh: true, json: true)
    let report = try jsonObject(execution.output)
    let request = try #require(requests.withLock { $0.first })

    #expect(execution.succeeded)
    #expect(request.url == UpdateChecker.latestReleaseURL)
    #expect(request.headers["Accept"] == "application/vnd.github+json")
    #expect(request.headers["X-GitHub-Api-Version"] == "2022-11-28")
    #expect(request.headers["If-None-Match"] == nil)
    #expect(report["operation"] as? String == "update_check")
    #expect(report["outcome"] as? String == "update_available")
    #expect(report["packaging"] as? String == "pending")
    #expect(report["update_available"] as? Bool == true)
    let upstream = try #require(report["upstream"] as? [String: Any])
    #expect(upstream["version"] as? String == "0.2.0")
    #expect(upstream["status"] as? String == "available")

    guard case .available(let cache) = UpdateCacheStore(root: root).read() else {
      Issue.record("Expected a valid persisted update cache")
      return
    }
    #expect(cache.lastSuccess?.release?.version == "0.2.0")
    #expect(cache.lastSuccess?.etag == #""release-etag""#)
    let cacheStore = UpdateCacheStore(root: root)
    let firstPersistedBytes = try Data(contentsOf: cacheStore.cacheURL)
    try cacheStore.write(cache)
    #expect(try Data(contentsOf: cacheStore.cacheURL) == firstPersistedBytes)
    let permissions = try #require(
      FileManager.default.attributesOfItem(atPath: cacheStore.cacheURL.path)[.posixPermissions]
        as? NSNumber
    )
    #expect(permissions.intValue == 0o600)
  }

  @Test
  func updateCheckLockRejectsASymlinkWithoutFollowingIt() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let target = root.appending(path: "lock-target")
    let lockURL = runDirectory.appending(path: "update-check.lock")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)

    do {
      try StateFileLock(root: root, identity: .updateCheck).withLock {}
      Issue.record("Expected the symlinked update-check lock to be rejected")
    } catch let error as StateFileLockError {
      #expect(error == .system(.updateCheck, "open", ELOOP))
      #expect(
        error.description
          == "Cannot open update-check lock (errno \(ELOOP)): "
          + String(cString: strerror(ELOOP))
      )
    }
    #expect(try Data(contentsOf: target).isEmpty)
  }

  @Test
  func staleCacheUsesBothValidatorsAnd304RefreshesWithoutLosingRelease() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newDate = oldDate.addingTimeInterval(UpdateChecker.freshnessInterval + 1)
    try UpdateCacheStore(root: root).write(
      successfulCache(
        checkedAt: oldDate,
        version: "0.2.0",
        etag: #""old-etag""#,
        lastModified: "Tue, 25 Aug 2026 10:00:00 GMT"
      )
    )
    let requests = Mutex([UpdateHTTPRequest]())
    let checker = UpdateChecker(
      root: root,
      httpClient: UpdateHTTPClient { request in
        requests.withLock { $0.append(request) }
        return UpdateHTTPResponse(statusCode: 304, headers: [:], body: Data())
      },
      now: { newDate }
    )

    let refreshed = checker.check(ifStaleOnly: true)
    let reused = checker.check(ifStaleOnly: true)
    let request = try #require(requests.withLock { $0.first })

    #expect(refreshed.refreshed)
    #expect(refreshed.succeeded)
    #expect(!reused.refreshed)
    #expect(requests.withLock { $0.count } == 1)
    #expect(request.headers["If-None-Match"] == #""old-etag""#)
    #expect(request.headers["If-Modified-Since"] == "Tue, 25 Aug 2026 10:00:00 GMT")
    #expect(refreshed.cache.lastSuccess?.release?.version == "0.2.0")
    #expect(refreshed.cache.lastSuccess?.checkedAt == newDate)

    try UpdateCacheStore(root: root).write(
      successfulCache(
        checkedAt: newDate.addingTimeInterval(60 * 60),
        version: "0.2.0"
      )
    )
    let futureDated = checker.check(ifStaleOnly: true)
    #expect(!futureDated.refreshed)
    #expect(requests.withLock { $0.count } == 1)

    let rollback = UpdateChecker(
      root: root,
      httpClient: UpdateHTTPClient { _ in throw UpdateTestError.failure("offline") },
      now: { newDate }
    ).check(ifStaleOnly: false)
    #expect(!rollback.succeeded)
    guard case .available(let rollbackCache) = UpdateCacheStore(root: root).read() else {
      Issue.record("Expected rollback-safe failure evidence")
      return
    }
    #expect(rollbackCache.lastAttempt.checkedAt == newDate.addingTimeInterval(60 * 60))
  }

  @Test
  func failedCheckPreservesLastStableReleaseAndCachesBoundedEvidence() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let checkedAt = oldDate.addingTimeInterval(UpdateChecker.freshnessInterval + 1)
    try UpdateCacheStore(root: root).write(
      successfulCache(checkedAt: oldDate, version: "0.2.0")
    )
    let failure = String(repeating: "e\u{301} \u{1B}[31mnetwork failure\n", count: 100)
    let checker = UpdateChecker(
      root: root,
      httpClient: UpdateHTTPClient { _ in throw UpdateTestError.failure(failure) },
      now: { checkedAt }
    )
    let runner = commandRunner(
      root: root,
      checker: checker,
      installedVersion: "0.1.0",
      tapVersion: .available("0.2.0"),
      now: checkedAt
    )

    let execution = try runner.execute(stateRoot: root, refresh: true, json: true)
    let report = try jsonObject(execution.output)
    let upstream = try #require(report["upstream"] as? [String: Any])

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "check_failed")
    #expect(upstream["status"] as? String == "check_failed")
    #expect(upstream["version"] as? String == "0.2.0")
    #expect(upstream["stale"] as? Bool == true)
    #expect(upstream["checked_at"] != nil)
    #expect(upstream["attempted_at"] != nil)
    let error = try #require(upstream["error"] as? String)
    #expect(error.utf8.count <= 512)
    #expect(error.hasSuffix("..."))
    #expect(!error.contains("\n"))
    #expect(!error.contains("\u{1B}"))
    guard case .available(let cache) = UpdateCacheStore(root: root).read() else {
      Issue.record("Expected failed-attempt evidence to remain readable")
      return
    }
    #expect(cache.lastAttempt.outcome == .failure)
    #expect(cache.lastSuccess?.release?.version == "0.2.0")
  }

  @Test
  func oversizedValidatorPersistsBoundedFailureEvidence() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let checker = UpdateChecker(
      root: root,
      httpClient: UpdateHTTPClient { _ in
        UpdateHTTPResponse(
          statusCode: 200,
          headers: ["ETag": String(repeating: "x", count: BoundedRegularFile.maximumSize)],
          body: releaseJSON(version: "0.2.0")
        )
      },
      now: { date }
    )

    let execution = checker.check(ifStaleOnly: false)

    #expect(!execution.succeeded)
    guard case .available(let cache) = UpdateCacheStore(root: root).read() else {
      Issue.record("Expected cache-write failure evidence to be persisted")
      return
    }
    #expect(cache.lastAttempt.outcome == .failure)
    #expect(cache.lastAttempt.error?.contains("ETag validator exceeded") == true)
    #expect(cache.lastSuccess == nil)
  }

  @Test
  func updateCachePreservesItsExactSizeError() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let oversized = successfulCache(
      checkedAt: checkedAt,
      version: "0.2.0",
      etag: String(repeating: "x", count: BoundedRegularFile.maximumSize)
    )

    #expect(throws: UpdateCacheError.tooLarge) {
      try UpdateCacheStore(root: root).write(oversized)
    }
  }

  @Test
  func noReleaseIsSuccessfulButPrereleasePayloadIsRejected() throws {
    let noReleaseRoot = try temporaryRoot()
    let prereleaseRoot = try temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: noReleaseRoot)
      try? FileManager.default.removeItem(at: prereleaseRoot)
    }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let noRelease = UpdateChecker(
      root: noReleaseRoot,
      httpClient: UpdateHTTPClient { _ in
        UpdateHTTPResponse(statusCode: 404, headers: [:], body: Data())
      },
      now: { date }
    ).check(ifStaleOnly: false)
    let prerelease = UpdateChecker(
      root: prereleaseRoot,
      httpClient: UpdateHTTPClient { _ in
        UpdateHTTPResponse(
          statusCode: 200,
          headers: [:],
          body: releaseJSON(version: "0.2.0", prerelease: true)
        )
      },
      now: { date }
    ).check(ifStaleOnly: false)

    #expect(noRelease.succeeded)
    #expect(noRelease.cache.lastSuccess?.release == nil)
    #expect(!prerelease.succeeded)
    #expect(prerelease.cache.lastAttempt.outcome == .failure)
    #expect(prerelease.cache.lastAttempt.error == "GitHub latest release was not stable")

    let failedAt = date.addingTimeInterval(60)
    let failedChecker = UpdateChecker(
      root: noReleaseRoot,
      httpClient: UpdateHTTPClient { _ in throw UpdateTestError.failure("offline") },
      now: { failedAt }
    )
    #expect(!failedChecker.check(ifStaleOnly: false).succeeded)
    let status = try commandRunner(
      root: noReleaseRoot,
      checker: failedChecker,
      installedVersion: "0.1.0",
      tapVersion: .available("0.1.0"),
      now: failedAt
    ).execute(stateRoot: noReleaseRoot, refresh: false, json: true)
    let upstream = try #require(
      jsonObject(status.output)["upstream"] as? [String: Any]
    )
    #expect(upstream["status"] as? String == "check_failed")
    #expect(upstream["checked_at"] != nil)
    #expect(upstream["attempted_at"] != nil)
    #expect(upstream["version"] == nil)
  }

  @Test
  func statusDoesNotRefreshAndMakesInvalidCacheVisible() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let checks = Mutex(0)
    let cacheStore = UpdateCacheStore(root: root)
    try FileManager.default.createDirectory(
      at: cacheStore.cacheURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let invalidDocuments = [
      """
      {"schema_version":1,"last_attempt":{"checked_at":"2027-01-01T00:00:00Z","outcome":"success","error":"contradiction"},"last_success":{"checked_at":"2027-01-01T00:00:00Z"}}
      """,
      """
      {"schema_version":1,"last_attempt":{"checked_at":"2027-01-01T00:00:00Z","outcome":"failure"}}
      """,
      """
      {"schema_version":1,"last_attempt":{"checked_at":"2027-01-01T00:00:00Z","outcome":"failure","error":"offline"},"last_success":{"checked_at":"2027-01-02T00:00:00Z"}}
      """,
      """
      {"schema_version":1,"last_attempt":{"checked_at":"2027-01-01T00:00:00Z","outcome":"success"},"last_success":{"checked_at":"2027-01-01T00:00:00Z","release":{"version":"0.2.0","tag":"v0.2.0","url":"https://example.com/v0.2.0"}}}
      """,
    ]
    for document in invalidDocuments {
      try Data(document.utf8).write(to: cacheStore.cacheURL)
      guard case .invalid = cacheStore.read() else {
        Issue.record("Expected contradictory cache evidence to be rejected")
        continue
      }
    }
    let runner = UpdateCommandRunner(
      buildInformation: { buildInformation(version: "0.1.0") },
      tapVersion: { .unavailable("tap missing") },
      readCache: { _ in cacheStore.read() },
      check: { _, _ in
        checks.withLock { $0 += 1 }
        return UpdateCheckExecution(
          cache: successfulCache(checkedAt: Date(), version: "9.9.9"),
          refreshed: true,
          succeeded: true
        )
      },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let execution = try runner.execute(stateRoot: root, refresh: false, json: true)
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(checks.withLock { $0 } == 0)
    #expect(report["outcome"] as? String == "cache_invalid")
    #expect(report["update_available"] == nil)
  }

  @Test
  func homebrewReaderUsesReadOnlyLocalMetadataQuery() {
    let requests = Mutex([ProcessRequest]())
    let reader = HomebrewTapVersionReader(
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(
          terminationStatus: 0,
          output:
            #"{"formulae":[{"full_name":"ramtinj95/tap/macarchy","versions":{"stable":"0.1.0"}}],"casks":[]}"#
        )
      },
      executableIsAvailable: { true }
    )

    let version = reader.read()

    #expect(version == .available("0.1.0"))
    #expect(requests.withLock { $0.only } == HomebrewTapVersionReader.request)
    #expect(
      HomebrewTapVersionReader.request.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1"
    )
  }

  @Test
  func noticeRunsOnlyForInteractiveStableInstallWithNewerRelease() throws {
    let checks = Mutex(0)
    let notices = Mutex([String]())
    let refreshes = Mutex([true, false])
    let cache = successfulCache(
      checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
      version: "0.2.0"
    )
    let noninteractive = UpdateNoticeRunner(
      isInteractive: { false },
      automaticChecksEnabled: { true },
      checkIfDue: { _ in
        checks.withLock { $0 += 1 }
        return UpdateCheckExecution(cache: cache, refreshed: true, succeeded: true)
      },
      installedVersion: { "0.1.0" },
      write: { notice in notices.withLock { $0.append(notice) } }
    )
    noninteractive.run(stateRoot: URL(filePath: "/unused"))
    #expect(checks.withLock { $0 } == 0)

    let disabled = UpdateNoticeRunner(
      isInteractive: { true },
      automaticChecksEnabled: { false },
      checkIfDue: { _ in
        checks.withLock { $0 += 1 }
        return UpdateCheckExecution(cache: cache, refreshed: true, succeeded: true)
      },
      installedVersion: { "0.1.0" },
      write: { notice in notices.withLock { $0.append(notice) } }
    )
    disabled.run(stateRoot: URL(filePath: "/unused"))
    #expect(checks.withLock { $0 } == 0)

    let interactive = UpdateNoticeRunner(
      isInteractive: { true },
      automaticChecksEnabled: { true },
      checkIfDue: { _ in
        checks.withLock { $0 += 1 }
        return UpdateCheckExecution(
          cache: cache,
          refreshed: refreshes.withLock { $0.removeFirst() },
          succeeded: true
        )
      },
      installedVersion: { "0.1.0" },
      write: { notice in notices.withLock { $0.append(notice) } }
    )
    interactive.run(stateRoot: URL(filePath: "/unused"))
    interactive.run(stateRoot: URL(filePath: "/unused"))

    #expect(checks.withLock { $0 } == 2)
    #expect(notices.withLock { $0.only }?.contains("0.2.0") == true)
  }

  private func commandRunner(
    root: URL,
    checker: UpdateChecker,
    installedVersion: String,
    tapVersion: HomebrewTapVersion,
    now: Date
  ) -> UpdateCommandRunner {
    UpdateCommandRunner(
      buildInformation: { buildInformation(version: installedVersion) },
      tapVersion: { tapVersion },
      readCache: { _ in UpdateCacheStore(root: root).read() },
      check: { _, staleOnly in checker.check(ifStaleOnly: staleOnly) },
      now: { now }
    )
  }

  private func successfulCache(
    checkedAt: Date,
    version: String,
    etag: String? = nil,
    lastModified: String? = nil
  ) -> UpdateCacheDocument {
    UpdateCacheDocument(
      lastAttempt: UpdateCheckAttempt(
        checkedAt: checkedAt,
        outcome: .success,
        error: nil
      ),
      lastSuccess: UpdateCheckSuccess(
        checkedAt: checkedAt,
        release: StableRelease(
          version: version,
          tag: "v\(version)",
          url: "https://github.com/ramtinJ95/macarchy/releases/tag/v\(version)"
        ),
        etag: etag,
        lastModified: lastModified
      )
    )
  }

  private func buildInformation(version: String) -> MacarchyBuildInformation {
    MacarchyBuildInformation(
      version: version,
      revision: "0123456789abcdef0123456789abcdef01234567",
      platform: "macos-arm64",
      installation: .homebrew
    )
  }

  private func releaseJSON(version: String, prerelease: Bool = false) -> Data {
    Data(
      """
      {
        "tag_name": "v\(version)",
        "html_url": "https://github.com/ramtinJ95/macarchy/releases/tag/v\(version)",
        "draft": false,
        "prerelease": \(prerelease)
      }
      """.utf8
    )
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: ".build/update-awareness-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private enum UpdateTestError: Error, CustomStringConvertible {
  case failure(String)

  var description: String {
    switch self {
    case .failure(let message):
      message
    }
  }
}

extension Array {
  fileprivate var only: Element? {
    count == 1 ? self[0] : nil
  }
}
