import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SketchyBarUpdateIndicatorTests {
  @Test(arguments: ["current", "available", "failed-known", "failed-unknown", "missing", "invalid"])
  func rendersReleaseEvidenceWithoutImplyingFailedChecksAreCurrent(state: String) throws {
    let calls = Mutex([[String]]())
    let failed = state.hasPrefix("failed")
    let newer = state == "available" || state == "failed-known"
    let cache: UpdateCacheRead =
      state == "missing"
      ? .missing
      : state == "invalid"
        ? .invalid("bad cache")
        : .available(Self.cache(version: newer ? "0.2.0" : "0.1.0", failed: failed))
    let indicator = SketchyBarUpdateIndicator(
      processRunner: .init { request in
        calls.withLock { $0.append(request.arguments) }
        return .init(terminationStatus: 0, output: "")
      }, buildInformation: { Self.build }, readCache: { _ in cache },
      checkIfDue: { _ in
        Issue.record("Opt-out must not check the network")
        return Self.execution
      },
      launchReview: { _ in Issue.record("Rendering must not launch an updater") })
    try indicator.execute(
      sender: "routine", stateRoot: URL(filePath: "/unused"), automaticChecksEnabled: false,
      accent: "accent", warning: "warning")
    let args = try #require(calls.withLock { $0.last })
    #expect(args.contains("drawing=\(newer || failed || state == "invalid" ? "on" : "off")"))
    if newer { #expect(args.contains { $0.contains("Macarchy 0.2.0 available") }) }
    if failed || state == "invalid" { #expect(args.contains("icon.color=warning")) }
    if state == "failed-known" { #expect(args.contains("icon=↻!")) }
    if state == "available" { #expect(args.contains("icon=↻")) }
  }

  @Test(arguments: [false, true])
  func automaticOptOutPreventsChecksButNotCachedPresentation(enabled: Bool) throws {
    let checks = Mutex(0)
    let indicator = SketchyBarUpdateIndicator(
      processRunner: .init { _ in .init(terminationStatus: 0, output: "") },
      buildInformation: { Self.build }, readCache: { _ in .missing },
      checkIfDue: { _ in
        checks.withLock { $0 += 1 }
        return Self.execution
      },
      launchReview: { _ in Issue.record("Not a click") })
    try indicator.execute(
      sender: "system_woke", stateRoot: URL(filePath: "/unused"),
      automaticChecksEnabled: enabled, accent: "accent", warning: "warning")
    #expect(checks.withLock { $0 } == (enabled ? 1 : 0))
  }

  @Test(arguments: ["mouse.clicked", "mouse.entered", "mouse.exited.global"])
  func interactionNeverChecksOrInstallsAndClicksOnlyLaunchReview(sender: String) throws {
    let launched = Mutex(false)
    let indicator = SketchyBarUpdateIndicator(
      processRunner: .init { _ in .init(terminationStatus: 0, output: "") },
      buildInformation: {
        Issue.record("Interaction must not inspect installations")
        return Self.build
      },
      readCache: { _ in
        Issue.record("Interaction must not read cache")
        return .missing
      },
      checkIfDue: { _ in
        Issue.record("Interaction must not check network")
        return Self.execution
      },
      launchReview: { _ in launched.withLock { $0 = true } })
    try indicator.execute(
      sender: sender, stateRoot: URL(filePath: "/unused"), automaticChecksEnabled: true,
      accent: "accent", warning: "warning")
    #expect(launched.withLock { $0 } == (sender == "mouse.clicked"))
  }

  @Test func failedReviewLaunchPropagatesForVisibleScriptErrorPresentation() throws {
    let indicator = SketchyBarUpdateIndicator(
      processRunner: .init { _ in .init(terminationStatus: 0, output: "") },
      buildInformation: { Self.build }, readCache: { _ in .missing },
      checkIfDue: { _ in Self.execution },
      launchReview: { _ in throw CocoaError(.fileNoSuchFile) })
    #expect(throws: CocoaError.self) {
      try indicator.execute(
        sender: "mouse.clicked", stateRoot: URL(filePath: "/unused"),
        automaticChecksEnabled: true, accent: "accent", warning: "warning")
    }
  }

  @Test(arguments: [false, true])
  func sixHourPollingReusesTheSharedCacheAndBoundsFailedRetries(failed: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = Self.cache(version: "0.2.0", failed: failed)
    try UpdateCacheStore(root: root).write(cache)
    let now = Mutex(cache.lastAttempt.checkedAt.addingTimeInterval(6 * 3600 - 1))
    let requests = Mutex(0)
    let checker = UpdateChecker(
      root: root,
      httpClient: .init { _ in
        requests.withLock { $0 += 1 }
        return .init(statusCode: 304, headers: [:], body: Data())
      }, now: { now.withLock { $0 } })
    #expect(
      !checker.check(ifStaleOnly: true, freshnessInterval: SketchyBarUpdateIndicator.checkInterval)
        .refreshed)
    #expect(requests.withLock { $0 } == 0)
    now.withLock { $0 = $0.addingTimeInterval(1) }
    #expect(
      checker.check(ifStaleOnly: true, freshnessInterval: SketchyBarUpdateIndicator.checkInterval)
        .succeeded)
    #expect(requests.withLock { $0 } == 1)
    #expect(
      !checker.check(ifStaleOnly: true, freshnessInterval: SketchyBarUpdateIndicator.checkInterval)
        .refreshed)
    #expect(requests.withLock { $0 } == 1)
  }

  private static var build: MacarchyBuildInformation {
    .init(
      version: "0.1.0", revision: String(repeating: "a", count: 40), platform: "macos-arm64",
      installation: .homebrew)
  }

  private static var execution: UpdateCheckExecution {
    .init(cache: cache(version: "0.2.0", failed: false), refreshed: false, succeeded: true)
  }

  private static func cache(version: String, failed: Bool) -> UpdateCacheDocument {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    return .init(
      lastAttempt: .init(
        checkedAt: date, outcome: failed ? .failure : .success,
        error: failed ? "offline" : nil),
      lastSuccess: .init(
        checkedAt: date,
        release: .init(
          version: version, tag: "v\(version)",
          url: "https://github.com/ramtinJ95/macarchy/releases/tag/v\(version)"),
        etag: nil, lastModified: nil))
  }
}
