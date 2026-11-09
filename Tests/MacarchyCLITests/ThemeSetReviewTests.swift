import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeSetReviewTests {
  @Test(arguments: [
    (Optional<ThemeIconStyle>.none, Optional<ThemeIconStyle>.some(.dark)),
    (.some(.dark), .some(.clear)), (.some(.clear), .none),
  ])
  func sameThemeIDIconStyleEditInvalidatesReviewedApply(
    before: ThemeIconStyle?, after: ThemeIconStyle?
  ) async throws {
    try await withTemporaryRoot(named: "icon-style-reviewed-edit") { root in
      let themes = root.appending(path: "themes")
      let packageURL = themes.appending(path: "tokyo-night")
      try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: repositoryRoot.appending(path: "Themes/tokyo-night"), to: packageURL)
      let manifest = packageURL.appending(path: "theme.toml")
      let original = try String(contentsOf: manifest, encoding: .utf8)
      func write(_ style: ThemeIconStyle?) throws {
        let options = style.map { "\n[macos]\nicon_style = \"\($0.rawValue)\"\n" } ?? ""
        try (original + options).write(to: manifest, atomically: false, encoding: .utf8)
      }
      try write(before)
      let repository = ThemeRepository(builtInRoot: themes)
      let state = root.appending(path: "state")
      let paths = testConsumerPaths(homeDirectory: root)
      // Use the real coordinator digest and the public service's locked stale-review check.
      // No native consumers are needed: package inputs are always part of the review.
      let service = ThemeActivationService.reconciling([], onCommittedLocked: { _ in })
      let reviewed = try service.review(repository.package(id: "tokyo-night"), nil, state, paths)
      try write(after)
      let changed = try service.review(repository.package(id: "tokyo-night"), nil, state, paths)
      #expect(changed.digest != reviewed.digest)
      let result = try await service.execute(
        repository: repository, themeID: "tokyo-night", stateRoot: state, consumerPaths: paths,
        dryRun: false, json: false, reviewedDigest: reviewed.digest)
      #expect(!result.succeeded)
      #expect(result.output.contains("review it again"))
      #expect(!FileManager.default.fileExists(atPath: state.appending(path: "current").path))
      #expect(!FileManager.default.fileExists(atPath: state.appending(path: "generations").path))
    }
  }

  @Test func aDryRunPrintsThePlanAndHowToApplyIt() async throws {
    let service = fakeService(review: { try review($0, active: "g-active", kitty: .ready) })

    let text = try await execute(service, dryRun: true, json: false)
    let json = try await execute(service, dryRun: true, json: true)

    let plan = try review(try package(), active: "g-active", kitty: .ready)
    #expect(text.succeeded)
    #expect(text.output.contains("Plan for theme 'tokyo-night':"))
    #expect(
      text.output.contains("  kitty: Kitty colors (\(KittyAdapter.outputPath)); reloads; ready"))
    #expect(text.output.contains("Disabled in the profile: "))
    #expect(text.output.contains("macarchy theme set tokyo-night --reviewed \(plan.digest)"))
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
    let reviewObject = try #require(object["review"] as? [String: Any])
    #expect(object["outcome"] as? String == "dry_run")
    #expect(reviewObject["digest"] as? String == plan.digest)
    #expect(reviewObject["can_apply"] as? Bool == true)
  }

  @Test func aPlanWithAFailedPreflightIsReportedAndCannotBeApplied() async throws {
    let service = fakeService(review: {
      try review($0, active: nil, kitty: .failed("Kitty is not installed"))
    })

    let text = try await execute(service, dryRun: true, json: false)

    #expect(!text.succeeded)
    #expect(
      text.output.contains("  kitty: Kitty colors (\(KittyAdapter.outputPath)); reloads; FAILED: "))
    #expect(text.output.contains("preflight failed for kitty"))
  }

  @Test func aReviewedApplyActivatesOnlyTheReviewedPlanOnTheReviewedGeneration() async throws {
    let activated = Mutex<[String?]>([])
    let current = Mutex("g-active")
    let service = fakeService(
      review: { try review($0, active: current.withLock { $0 }, kitty: .ready) },
      activate: { expected, _ in activated.withLock { $0.append(expected) } })
    let reviewed = try review(try package(), active: "g-active", kitty: .ready).digest

    // Another activation changed the active generation since the review.
    current.withLock { $0 = "g-other" }
    let stale = try await execute(service, dryRun: false, json: false, reviewed: reviewed)
    #expect(!stale.succeeded)
    #expect(stale.output.contains("review it again"))
    #expect(activated.withLock { $0 } == [])

    current.withLock { $0 = "g-active" }
    _ = try await execute(service, dryRun: false, json: false, reviewed: reviewed)
    #expect(activated.withLock { $0 } == ["g-active"])
  }

  @Test(arguments: [false, true])
  func onlyReviewedApplyReconcilesAllConsumers(reviewed: Bool) async throws {
    let requested = Mutex([Bool]())
    let service = fakeService(
      review: { try review($0, active: "g-active", kitty: .ready) },
      activate: { _, all in requested.withLock { $0.append(all) } })
    let digest = try review(try package(), active: "g-active", kitty: .ready).digest

    _ = try await execute(
      service, dryRun: false, json: false, reviewed: reviewed ? digest : nil,
      background: "default")

    #expect(requested.withLock { $0 } == [reviewed])
  }

  @Test func aReviewedApplyIsRefusedWhenPreflightNowFails() async throws {
    let activated = Mutex(0)
    let ready = try review(try package(), active: nil, kitty: .ready)
    let service = fakeService(
      review: { try review($0, active: nil, kitty: .failed("Kitty is not installed")) },
      activate: { _, _ in activated.withLock { $0 += 1 } })

    let refused = try await execute(service, dryRun: false, json: false, reviewed: ready.digest)

    // Preflight results are not part of the digest, so the same digest is refused as blocked.
    #expect(!refused.succeeded)
    #expect(refused.output.contains("preflight failed for kitty"))
    #expect(activated.withLock { $0 } == 0)
  }

  @Test func theDigestCoversTheInputTheEnabledConsumersAndTheActiveGeneration() throws {
    func digest(input: String = "i", enabled: Set<String> = ["kitty"], active: String? = "g")
      throws -> String
    {
      try ThemeActivationReview(
        themeID: "t", backgroundID: nil, activeGenerationID: active, inputDigest: input,
        enabledAdapterIDs: enabled, consumers: [], disabledConsumerIDs: []
      ).digest
    }
    let base = try digest()
    #expect(try digest() == base)
    #expect(try digest(input: "j") != base)
    #expect(try digest(enabled: ["kitty", "atuin"]) != base)
    #expect(try digest(active: nil) != base)
  }

  @Test func aPlanForARequestedBackgroundDoesNotSuggestAThemeSetCommand() async throws {
    let service = fakeService(review: { try review($0, active: nil, kitty: .ready) })

    // `theme undo --dry-run` asks for the background it restores; `theme set` cannot.
    let text = try await execute(service, dryRun: true, json: false, background: "default")

    #expect(text.succeeded)
    #expect(text.output.contains("Plan for theme 'tokyo-night':"))
    #expect(!text.output.contains("--reviewed"))
  }

  @Test func consumersListTheFilesTheyReadAndTheirCurrentRepaintBoundary() throws {
    func entry(_ id: String) throws -> ConsumerCatalogEntry {
      try #require(ConsumerCatalog.shared.runtimeEntries.first { $0.id.rawValue == id })
    }

    let codex = ThemeActivationReview.Consumer(entry: try entry("codex"), preflight: .ready)
    let pi = ThemeActivationReview.Consumer(
      entry: try entry("pi"), preflight: .ready, repaint: .freshSession)
    let wallpaper = ThemeActivationReview.Consumer(entry: try entry("wallpaper"), preflight: .ready)
      .unchanged(because: "unchanged: the theme has no background")

    #expect(codex.artifacts == [TextMateThemeArtifact.outputPath])
    #expect(pi.repaint == .freshSession)
    #expect(
      ThemeActivationReview.Consumer(entry: try entry("pi"), preflight: .ready).repaint == .live)
    #expect(wallpaper.artifacts == [])
    #expect(wallpaper.change == "unchanged: the theme has no background")
  }
}

private func package() throws -> ThemePackage {
  try ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes")).package(
    id: "tokyo-night")
}

private func review(
  _ package: ThemePackage, active: String?, kitty: ThemeActivationReview.Preflight
) throws -> ThemeActivationReview {
  let entry = try #require(
    ConsumerCatalog.shared.runtimeEntries.first { $0.id.rawValue == "kitty" })
  return try ThemeActivationReview(
    themeID: package.id, backgroundID: nil, activeGenerationID: active, inputDigest: "input",
    enabledAdapterIDs: ["kitty"],
    consumers: [ThemeActivationReview.Consumer(entry: entry, preflight: kitty)],
    disabledConsumerIDs: ConsumerCatalog.shared.runtimeEntries.map(\.id.rawValue).filter {
      $0 != "kitty"
    })
}

private enum ReviewTestError: Error { case notActivated }

private func fakeService(
  review: @escaping @Sendable (ThemePackage) throws -> ThemeActivationReview,
  activate: @escaping @Sendable (String?, Bool) -> Void = { _, _ in }
) -> ThemeActivationService {
  ThemeActivationService(
    review: { package, _, _, _ in try review(package) },
    activate: { _, _, _, _, expected, reconcileAllConsumers in
      activate(expected, reconcileAllConsumers)
      // The test only needs to see the conditional activation request.
      throw ReviewTestError.notActivated
    },
    slackIsEnabled: { _ in false })
}

private func execute(
  _ service: ThemeActivationService, dryRun: Bool, json: Bool, reviewed: String? = nil,
  background: String? = nil
) async throws -> CommandExecution {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-theme-review-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: root) }
  return try await service.execute(
    repository: ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes")),
    themeID: "tokyo-night", stateRoot: root, consumerPaths: testConsumerPaths(),
    dryRun: dryRun, json: json, requestedBackgroundID: background, reviewedDigest: reviewed)
}
