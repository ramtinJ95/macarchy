import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeBrowserReviewTests {
  @Test func reviewShowsEachConsumerAndOffersApplyOnlyWhenPreflightPassed() throws {
    let ready = ThemeBrowserReview(
      review: try review(active: "g1", kitty: .ready), displayName: "Tokyo Night")
    let failed = ThemeBrowserReview(
      review: try review(active: "g1", kitty: .failed("Kitty is not installed")),
      displayName: "Tokyo Night")

    #expect(ready.title == "Review Tokyo Night with background default")
    #expect(
      ready.planText.hasPrefix("kitty: Kitty colors (\(KittyAdapter.outputPath)); reloads; ready"))
    #expect(ready.planText.contains("\nDisabled in the profile: "))
    #expect(ready.choices == [.apply, .editProfile, .cancel])
    #expect(failed.choices == [.editProfile, .cancel])
    #expect(failed.planText.contains("FAILED: Kitty is not installed"))
    #expect(
      failed.summary.hasPrefix("The reviewed plan cannot be applied: preflight failed for kitty"))
  }

  @Test func applyingIsRefusedWhenThePlanChangedOrNoLongerPasses() throws {
    let shown = ThemeBrowserReview(
      review: try review(active: "g1", kitty: .ready), displayName: "Tokyo Night")

    #expect(shown.refusal(current: try review(active: "g1", kitty: .ready)) == nil)
    #expect(
      shown.refusal(current: try review(active: "g2", kitty: .ready))
        == "The active theme changed since this review, so nothing was applied. Review it again.")
    #expect(
      shown.refusal(current: try review(active: "g1", kitty: .ready, input: "other"))
        == "The theme or its enabled consumers changed since this review, so nothing was "
        + "applied. Review it again.")
    #expect(
      shown.refusal(current: try review(active: "g1", kitty: .failed("gone")))?.hasPrefix(
        "The reviewed plan cannot be applied: preflight failed for kitty") == true)
  }

  @Test func theApplyRequestCarriesTheReviewedDigestToTheApplyProcess() {
    let selection = ThemeBrowserSelection(themeID: "lavender", backgroundID: nil)
    let reviewed = ThemeBrowserApplyRequest(selection: selection, reviewedDigest: "sha256:abc")
      .environment(addingTo: [
        ThemeBrowserApplyRequest.backgroundEnvironmentKey: "stale",
        ThemeBrowserApplyRequest.reviewedDigestEnvironmentKey: "stale",
      ])
    let plain = ThemeBrowserApplyRequest(selection: selection).environment(addingTo: reviewed)

    #expect(ThemeBrowserApplyRequest(environment: reviewed)?.reviewedDigest == "sha256:abc")
    #expect(reviewed[ThemeBrowserApplyRequest.backgroundEnvironmentKey] == nil)
    #expect(ThemeBrowserApplyRequest(environment: plain)?.reviewedDigest == nil)
    #expect(ThemeBrowserApplyRequest(environment: plain)?.selection == selection)
  }

  @Test func aReviewedApplyAlwaysActivatesTheThemeWithTheDigest() async throws {
    let calls = Mutex([String]())
    let runner = ThemeBrowserApplyRunner(
      activeThemeID: { _ in "lavender" },
      setActiveBackground: { _, backgroundID, _, _ in
        calls.withLock { $0.append("background:\(backgroundID)") }
        return ("background", true)
      },
      setThemeAndBackground: { _, themeID, _, _, _, reviewed in
        calls.withLock { $0.append("theme:\(themeID):\(reviewed ?? "none")") }
        return ("theme", true)
      }
    )

    _ = try await runner.execute(
      repository: ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes")),
      themeID: "lavender", backgroundID: "plane-purple",
      stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory),
      consumerPaths: testConsumerPaths(), reviewedDigest: "sha256:abc")

    #expect(calls.withLock { $0 } == ["theme:lavender:sha256:abc"])
  }
}

private func review(
  active: String?, kitty: ThemeActivationReview.Preflight, input: String = "input"
) throws -> ThemeActivationReview {
  let entry = try #require(
    ConsumerCatalog.shared.runtimeEntries.first { $0.id.rawValue == "kitty" })
  return try ThemeActivationReview(
    themeID: "tokyo-night", backgroundID: "default", activeGenerationID: active,
    inputDigest: input, enabledAdapterIDs: ["kitty"],
    consumers: [ThemeActivationReview.Consumer(entry: entry, preflight: kitty)],
    disabledConsumerIDs: ConsumerCatalog.shared.runtimeEntries.map(\.id.rawValue).filter {
      $0 != "kitty"
    })
}
