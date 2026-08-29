import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct ConsumerSetupPlanTests {
  private let integrationIDs = [
    "kitty.include",
    "bat.selector",
    "bat.theme-link",
    "eza.environment",
    "eza.theme-link",
    "btop.selector",
    "btop.theme-link",
    "yazi.selector",
    "yazi.flavor-link",
    "yazi.syntax-link",
    "atuin.selector",
    "atuin.theme-link",
    "neovim.watcher",
    "neovim.theme-link",
    "starship.behavior",
    "starship.configuration-link",
    "pi.selector",
    "pi.theme-link",
    "herdr.selector",
    "tuicr.selector",
    "tuicr.theme-link",
    "tuicr.syntax-link",
    "codex.selector",
    "codex.theme-link",
    "spicetify.selectors",
    "spicetify.color-link",
  ]

  private let setupDispatchIDs = [
    "kitty.include",
    "bat.selector", "bat.theme-link",
    "eza.environment", "eza.theme-link",
    "btop.selector", "btop.theme-link",
    "yazi.flavor-link", "yazi.syntax-link", "yazi.selector",
    "atuin.theme-link", "atuin.selector",
    "neovim.watcher", "neovim.theme-link",
    "starship.behavior", "starship.configuration-link",
    "pi.theme-link", "pi.selector",
    "herdr.selector",
    "tuicr.theme-link", "tuicr.syntax-link", "tuicr.selector",
    "codex.theme-link", "codex.selector",
    "spicetify.color-link", "spicetify.selectors",
  ]

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
      context.replacementURL.path: "kitty.include",
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
    let fixture = try Fixture(configuration: "")
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
    #expect(steps.map(\.id) == integrationIDs)
    #expect(Set(steps.map(\.id)).count == integrationIDs.count)
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
    #expect(
      steps.allSatisfy {
        ($0.ownershipKind == nil) == ($0.validateOwnershipRecord == nil)
      }
    )
    #expect(
      plans.allSatisfy { plan in
        Set(plan.steps.map(\.setupRank)) == Set(0..<plan.steps.count)
          && Set(plan.steps.map(\.teardownRank)) == Set(0..<plan.steps.count)
      }
    )
  }

  @Test
  func setupAndTeardownResultsUseThePlanOrder() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let manager = SetupOwnershipManager()

    let setup = try manager.setup(homeDirectory: fixture.home, dryRun: true)
    let teardown = try manager.teardown(homeDirectory: fixture.home, dryRun: true)

    #expect(setup.map(\.id) == integrationIDs)
    #expect(teardown.map(\.id) == integrationIDs)
  }

  @Test
  func plansPreserveTheConcreteSetupAndTeardownRanks() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    let plans = SetupOwnershipManager().consumerSetupPlans(context: context)
    let setupIDs = plans.flatMap { plan in
      plan.steps.sorted { $0.setupRank < $1.setupRank }.map(\.id)
    }
    let teardownIDs = plans.reversed().flatMap { plan in
      plan.steps.sorted { $0.teardownRank < $1.teardownRank }.map(\.id)
    }

    #expect(setupIDs == setupDispatchIDs)
    #expect(teardownIDs == teardownDispatchIDs)
  }

  @Test
  func manifestResumeLookupCoversEveryOwnedStepAndRecordKind() throws {
    let fixture = try Fixture(
      configuration: "font_size 13\n",
      externalBatEza: false,
      externalBtopYaziAtuin: false,
      externalNeovimStarship: false,
      externalAgentTUIs: false
    )
    defer { fixture.remove() }
    try fixture.createLocalBatEzaConfigurations(
      bat: "--italic-text=always\n",
      shell: "export EDITOR=nvim\n"
    )
    try fixture.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: "[flavor]\nlight = \"default\"\n",
      atuin: "sync_frequency = \"5m\"\n"
    )
    try fixture.createNeovimStarshipPrerequisites()
    try fixture.createLocalAgentTUIConfigurations(
      pi: "{\n  \"provider\": \"openai\"\n}\n",
      tuicr: "show_help = true\n",
      codex: "[tui]\nanimations = false\n"
    )
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    try FileManager.default.createDirectory(
      at: context.spicetifyColorLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("[Setting]\ninject_css = 1\nreplace_colors = 1\n".utf8).write(
      to: context.spicetifyConfiguration
    )
    let manager = SetupOwnershipManager()

    _ = try manager.setup(homeDirectory: fixture.home, dryRun: false)
    let records = try manager.readRecords(context: context)
    let resumedOwnership = Dictionary(
      uniqueKeysWithValues: records.map { ($0.id, $0.kind) }
    )

    #expect(resumedOwnership == expectedOwnershipKinds())
    #expect(
      Set(records.map(\.kind))
        == Set([.regularFile, .symbolicLink, .jsonSelector, .spicetifySelection])
    )
  }

  @Test
  func partialPlanFailureRetainsEarlierUnownedStepAfterAPriorMutation() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.btopThemeLink)
    try FileManager.default.createSymbolicLink(
      at: fixture.btopThemeLink,
      withDestinationURL: fixture.root.appending(path: "wrong-btop-theme")
    )
    let manager = SetupOwnershipManager()
    let error: any Error
    do {
      _ = try manager.setup(homeDirectory: fixture.home, dryRun: false)
      throw FixtureError.interrupted
    } catch let caught {
      error = caught
    }

    let results = SetupOwnershipManager.failureResults(error, homeDirectory: fixture.home)

    #expect(results.map(\.id) == Array(integrationIDs.prefix(7)))
    #expect(
      results.map(\.status)
        == [.owned, .external, .external, .external, .external, .external, .failed]
    )
    #expect(
      results.map(\.mutationAttempted)
        == [true, false, false, false, false, false, false]
    )
  }

  @Test
  func everyExpectedTargetBackupAndReplacementPathAttributesFailureToItsID() throws {
    let fixture = try Fixture(configuration: "")
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

  @Test
  func interruptedOwnershipResumesThroughThePlanAndRetainsOrder() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    let interrupted = SetupOwnershipManager { checkpoint in
      if checkpoint == .manifestPrepared { throw FixtureError.interrupted }
    }

    #expect(throws: (any Error).self) {
      _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
    }

    let resumed = try SetupOwnershipManager().setup(
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(resumed.map(\.id) == integrationIDs)
    #expect(resumed.first?.status == .owned)
    #expect(resumed.first?.mutationAttempted == true)
    #expect(try fixture.configuration() == "font_size 13\n\(fixture.includeDirective)\n")
  }
}
