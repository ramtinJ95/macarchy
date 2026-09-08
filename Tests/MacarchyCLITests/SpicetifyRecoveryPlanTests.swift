import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SpicetifyRecoveryPlanTests {
  @Test
  func stockSpotifyBlocksUnifiedSetupBeforeAnyStageAndDisabledPresetDoesNotProbeIt() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = UnifiedSetupPlanContext(
      themesRoot: fixture.context.themesRoot,
      keybindingsResourcesRoot: repositoryRoot.appending(path: "Keybindings"),
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: fixture.context.profileURL, profileRequired: true,
      machineProfileURL: fixture.context.machineProfileURL, machineProfileRequired: false,
      stateRoot: fixture.state, homeDirectory: fixture.home)
    let profile = """
      schema_version = 1
      [focus_ring]
      provider = "disabled"
      [terminal]
      provider = "disabled"
      [shell]
      provider = "disabled"
      [editor]
      provider = "disabled"
      [tools]
      bat = false
      btop = false
      eza = false
      yazi = false
      [presets]
      spicetify = true
      """
    try profile.write(to: context.profileURL, atomically: true, encoding: .utf8)
    let configurationDirectory = fixture.home.appending(path: ".config/spicetify")
    try FileManager.default.createDirectory(
      at: configurationDirectory.appending(path: "Themes/text"), withIntermediateDirectories: true)
    let configuration = configurationDirectory.appending(path: "config-xpui.ini")
    try
      "[Setting]\nspotify_path = \(fixture.root.path)/stock-spotify\ncurrent_theme = text\ncolor_scheme = Personal\n"
      .write(to: configuration, atomically: true, encoding: .utf8)
    let before = try Data(contentsOf: configuration)
    let planner = UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: { _ in true }, desktopPlanner: fixture.planner().desktopPlanner,
      environmentPlanner: UnifiedSetupPlanCommandRunner.live.environmentPlanner,
      packageInventoryReader: { .init(packages: [], issues: []) },
      standardBrewfile: { _ in SetupBrewfile(packages: []) })
    let preparation = try planner.prepare(context: context)
    #expect(!preparation.succeeded)
    #expect(preparation.report.diagnostics.contains { $0.message.contains("xpui") })
    let runner = UnifiedSetupApplyCommandRunner(
      planner: planner, themeInspection: UnifiedSetupThemeLifecycleStatus.inspect,
      packageInstaller: .init(apply: { _, _ in
        Issue.record("Blocked preflight must not install packages")
        return .init(status: 1, diagnostic: "unexpected")
      }),
      capabilityIsAvailable: { _ in true }, writePreMutationPlan: { _ in },
      themeApply: { _, _ in
        Issue.record("Blocked preflight must not activate theme")
        return try applyComponent("{}")
      },
      desktopApply: { _, _, _, _, _ in
        Issue.record("Blocked preflight must not mutate desktop")
        return try applyComponent("{}")
      },
      environmentApply: { _, _, _, _, _ in
        Issue.record("Blocked preflight must not mutate environment")
        return try applyComponent("{}")
      })
    let execution = try await runner.execute(
      context: context, consumerPaths: testConsumerPaths(), json: true)
    #expect(!execution.succeeded)
    #expect(try jsonObject(execution.output)["mutated"] as? Bool == false)
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "current").path))
    #expect(try Data(contentsOf: configuration) == before)

    try profile.replacingOccurrences(of: "spicetify = true", with: "spicetify = false")
      .write(to: context.profileURL, atomically: true, encoding: .utf8)
    try "malformed and deliberately uninspectable".write(
      to: configuration, atomically: true, encoding: .utf8)
    try EnvironmentStateStore(stateRoot: fixture.state).recordUnverifiedSpicetifyRecovery()
    let disabled = try planner.prepare(context: context)
    #expect(disabled.succeeded)
    #expect(
      disabled.report.manualBoundaries.contains {
        $0.id == "spicetify_runtime_restoration" && $0.kind == "unverified"
      })
    let inspector = UnifiedSetupInspectionCommandRunner(
      planner: planner, themeInspection: UnifiedSetupThemeLifecycleStatus.inspect,
      desktopInspection: { _, _, _, _ in
        Issue.record("An absent setup must not inspect desktop runtime")
        return try applyComponent("{}")
      },
      environmentInspection: { _, _, _, _ in
        Issue.record("An absent setup must not inspect environment runtime")
        return try applyComponent("{}")
      })
    for operation in [UnifiedSetupInspectionOperation.status, .doctor] {
      let status = try inspector.execute(
        operation: operation, context: context, consumerPaths: testConsumerPaths(), json: false)
      #expect(status.output.contains("UNVERIFIED"))
    }
  }

  @Test
  func recoveryAcknowledgmentIsAnExplicitFlag() throws {
    let ordinary = try Macarchy.Setup.Recover.parse([])
    #expect(!ordinary.acknowledgeUnverifiedSpicetify)
    let explicit = try Macarchy.Setup.Recover.parse([
      "--acknowledge-unverified-spicetify", "--json",
    ])
    #expect(explicit.acknowledgeUnverifiedSpicetify)
    #expect(explicit.json)
  }
}
