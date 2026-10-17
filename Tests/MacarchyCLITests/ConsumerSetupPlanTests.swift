import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct ConsumerSetupPlanTests {
  private let teardownDispatchIDs = [
    "spicetify.selectors", "spicetify.color-link",
    "codex.selector", "codex.theme-link",
    "tuicr.selector", "tuicr.syntax-link", "tuicr.theme-link",
    "herdr.selector",
    "pi.selector", "pi.theme-link",
    "starship.configuration-link", "starship.behavior",
    "neovim.theme-link", "neovim.watcher",
    "atuin.selector", "atuin.theme-link",
    "yazi.selector", "yazi.syntax-link", "yazi.flavor-link",
    "btop.selector", "btop.theme-link",
    "eza.theme-link", "eza.environment",
    "bat.theme-link", "bat.selector",
    "kitty.include",
  ]

  private func expectedPathToID(
    context: SetupOwnershipManager.Context
  ) -> [String: String] {
    let targetPaths = [
      context.kittyConfiguration.path: "kitty.include",
      context.batConfiguration.path: "bat.selector",
      context.batThemeLink.path: "bat.theme-link",
      context.shellConfiguration.path: "eza.environment",
      context.ezaThemeLink.path: "eza.theme-link",
      context.btopConfiguration.path: "btop.selector",
      context.btopThemeLink.path: "btop.theme-link",
      context.yaziConfiguration.path: "yazi.selector",
      context.yaziFlavorLink.path: "yazi.flavor-link",
      context.yaziSyntaxLink.path: "yazi.syntax-link",
      context.atuinConfiguration.path: "atuin.selector",
      context.atuinThemeLink.path: "atuin.theme-link",
      context.neovimWatcherConfiguration.path: "neovim.watcher",
      context.neovimThemeLink.path: "neovim.theme-link",
      context.starshipBehavior.path: "starship.behavior",
      context.starshipConfigurationLink.path: "starship.configuration-link",
      context.piConfiguration.path: "pi.selector",
      context.piThemeLink.path: "pi.theme-link",
      context.herdrConfiguration.path: "herdr.selector",
      context.tuicrConfiguration.path: "tuicr.selector",
      context.tuicrThemeLink.path: "tuicr.theme-link",
      context.tuicrSyntaxLink.path: "tuicr.syntax-link",
      context.codexConfiguration.path: "codex.selector",
      context.codexThemeLink.path: "codex.theme-link",
      context.spicetifyConfiguration.path: "spicetify.selectors",
      context.spicetifyColorLink.path: "spicetify.color-link",
    ]
    let backupPaths = [
      context.backupURL.path: "kitty.include",
      context.batSelectorBackup.path: "bat.selector",
      context.ezaEnvironmentBackup.path: "eza.environment",
      context.yaziSelectorBackup.path: "yazi.selector",
      context.atuinSelectorBackup.path: "atuin.selector",
      context.tuicrSelectorBackup.path: "tuicr.selector",
      context.codexSelectorBackup.path: "codex.selector",
      context.spicetifySelectorsBackup.path: "spicetify.selectors",
    ]
    let replacementPaths = [
      replacementPath(context.kittyConfiguration, context.replacementName): "kitty.include",
      replacementPath(context.batConfiguration, context.batSelectorReplacementName):
        "bat.selector",
      replacementPath(context.shellConfiguration, context.ezaEnvironmentReplacementName):
        "eza.environment",
      replacementPath(context.yaziConfiguration, context.yaziSelectorReplacementName):
        "yazi.selector",
      replacementPath(context.atuinConfiguration, context.atuinSelectorReplacementName):
        "atuin.selector",
      replacementPath(context.piConfiguration, context.piSelectorReplacementName):
        "pi.selector",
      replacementPath(context.tuicrConfiguration, context.tuicrSelectorReplacementName):
        "tuicr.selector",
      replacementPath(context.codexConfiguration, context.codexSelectorReplacementName):
        "codex.selector",
      replacementPath(
        context.spicetifyConfiguration,
        context.spicetifySelectorsReplacementName
      ): "spicetify.selectors",
    ]
    return targetPaths.merging(backupPaths) { first, _ in first }
      .merging(replacementPaths) { first, _ in first }
  }

  private func expectedOwnershipKinds() -> [String: SetupOwnershipRecord.Kind] {
    [
      "kitty.include": .regularFile,
      "bat.selector": .regularFile,
      "bat.theme-link": .symbolicLink,
      "eza.environment": .regularFile,
      "eza.theme-link": .symbolicLink,
      "btop.theme-link": .symbolicLink,
      "yazi.selector": .regularFile,
      "yazi.flavor-link": .symbolicLink,
      "yazi.syntax-link": .symbolicLink,
      "atuin.selector": .regularFile,
      "atuin.theme-link": .symbolicLink,
      "neovim.theme-link": .symbolicLink,
      "starship.configuration-link": .symbolicLink,
      "pi.selector": .jsonSelector,
      "pi.theme-link": .symbolicLink,
      "tuicr.selector": .regularFile,
      "tuicr.theme-link": .symbolicLink,
      "tuicr.syntax-link": .symbolicLink,
      "codex.selector": .regularFile,
      "codex.theme-link": .symbolicLink,
      "spicetify.selectors": .spicetifySelection,
      "spicetify.color-link": .symbolicLink,
    ]
  }

  private func replacementPath(_ target: URL, _ replacementName: String) -> String {
    target.deletingLastPathComponent().appending(path: replacementName).path
  }

  @Test
  func plansOwnTheDeterministicConsumerAndResultOrder() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    let plans = manager.consumerSetupPlans(context: context)
    let steps = plans.flatMap(\.steps)

    #expect(
      plans.map { $0.consumerID.rawValue }
        == [
          "kitty", "bat", "eza", "btop", "yazi", "atuin", "neovim", "starship",
          "pi", "herdr", "tuicr", "codex", "spicetify",
        ]
    )
    #expect(steps.map(\.id) == allIntegrationIDs)
    #expect(Set(steps.map(\.id)).count == allIntegrationIDs.count)
    #expect(steps.allSatisfy { $0.affectedPaths.first == $0.target })
    let plannedPathToID = Dictionary(
      uniqueKeysWithValues: steps.flatMap { step in
        step.affectedPaths.map { ($0.path, step.id) }
      }
    )
    #expect(plannedPathToID == expectedPathToID(context: context))
    let plannedOwnership = Dictionary(
      uniqueKeysWithValues: steps.compactMap { step in
        step.ownershipKind.map { (step.id, $0) }
      }
    )
    #expect(plannedOwnership == expectedOwnershipKinds())
    for step in steps where step.ownershipKind == nil {
      #expect(throws: SetupOwnershipError.invalidManifest("unknown integration \(step.id)")) {
        try manager.validateRecord(
          SetupOwnershipRecord(
            id: step.id,
            phase: .applied,
            kind: .regularFile,
            targetPath: step.target.path,
            backupPath: nil,
            originalDigest: nil,
            installedDigest: String(repeating: "0", count: 64),
            linkDestination: nil
          ),
          for: step,
          context: context
        )
      }
    }
    #expect(
      plans.allSatisfy { plan in
        Set(plan.steps.map(\.teardownRank)) == Set(0..<plan.steps.count)
      }
    )
  }

  @Test
  func teardownResultsUseThePlanOrder() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }

    let teardown = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true)

    #expect(teardown.map(\.id) == allIntegrationIDs)
  }

  @Test
  func plansPreserveTheConcreteTeardownRanks() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    let plans = SetupOwnershipManager().consumerSetupPlans(context: context)
    let teardownIDs = plans.reversed().flatMap { plan in
      plan.steps.sorted { $0.teardownRank < $1.teardownRank }.map(\.id)
    }

    #expect(teardownIDs == teardownDispatchIDs)
  }

  @Test
  func manifestLookupCoversEveryOwnedStepAndRecordKind() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let context = fixture.ownershipContext
    let manager = SetupOwnershipManager()
    var written = [SetupOwnershipRecord]()
    for step in manager.consumerSetupPlans(context: context).flatMap(\.steps)
    where step.id != SetupOwnershipManager.spicetifyColorLinkID {
      switch step.mechanism {
      case .external, .spicetifySelectors:
        continue
      case .regularFile:
        written.append(
          try fixture.legacyFileRecord(step.id, original: "original\n", installed: "installed\n"))
      case .themeLink:
        written.append(try fixture.legacyThemeLink(step.id))
      case .piSelector:
        written.append(
          try fixture.legacyPiSelector(contents: "{\"theme\": \"macarchy-current\"}\n"))
      }
    }
    try fixture.writeLegacyOwnership(written)

    let records = try manager.readRecords(context: context)
    let ownership = Dictionary(
      uniqueKeysWithValues: records.map { ($0.id, $0.kind) }
    )

    var expected = expectedOwnershipKinds()
    expected.removeValue(forKey: "spicetify.selectors")
    expected.removeValue(forKey: "spicetify.color-link")
    #expect(ownership == expected)
    #expect(
      Set(records.map(\.kind))
        == Set([.regularFile, .symbolicLink, .jsonSelector])
    )

    var document = try jsonObject(String(contentsOf: context.manifestURL, encoding: .utf8))
    var entries = try #require(document["records"] as? [[String: Any]])
    entries[0]["id"] = "unknown-first"
    entries[1]["id"] = "unknown-second"
    document["records"] = entries
    try JSONSerialization.data(withJSONObject: document).write(to: context.manifestURL)
    #expect(throws: SetupOwnershipError.invalidManifest("unknown integration unknown-first")) {
      _ = try manager.readRecords(context: context)
    }
  }

  @Test
  func everyExpectedTargetBackupAndReplacementPathAttributesFailureToItsID() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    for (path, expectedID) in expectedPathToID(context: context) {
      let url = URL(filePath: path)
      let failure = SetupOwnershipManager.failureResult(
        SetupOwnershipError.system("inspect", url, "test failure"),
        homeDirectory: fixture.home
      )
      #expect(failure.id == expectedID)
      #expect(failure.target == path)
    }
  }
}
