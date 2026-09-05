import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SlackPresetLifecycleTests {
  @Test
  func strictBundleVersionAndRendererV2PayloadGateManualAuthority() throws {
    let fixture = try SlackPresetFixture(version: "4.51.191")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try fixture.preset.supportedVersion() == "4.51.191")
    #expect(
      try fixture.preset.payload(stateRoot: fixture.state) == "#1e1e2e,#cba6f7,#a6e3a1,#f38ba8\n")

    let planned = fixture.preset.entry(stateRoot: fixture.state, applied: false)
    #expect(planned.status == .authorityRequired)
    #expect(planned.message.contains(SlackAdapter.importInstructions))
    #expect(planned.message.contains("#1e1e2e,#cba6f7,#a6e3a1,#f38ba8"))
    let applied = fixture.preset.entry(stateRoot: fixture.state, applied: true)
    #expect(applied.status == .external)
    #expect(applied.message.contains("Manual import is required for each workspace"))

    for version in ["4.51.190", "4.51", "4.51.191-beta", "unknown"] {
      let rejected = try SlackPresetFixture(version: version)
      defer { try? FileManager.default.removeItem(at: rejected.root) }
      #expect(
        rejected.preset.entry(stateRoot: rejected.state, applied: false).status == .unsupported)
    }
    let newer = try SlackPresetFixture(version: "99.0.0")
    defer { try? FileManager.default.removeItem(at: newer.root) }
    #expect(try newer.preset.supportedVersion() == "99.0.0")
  }

  @Test
  func authorityIsOnlyTheAppliedSelectionAndDisableRemovesOnlyThatSelection() throws {
    let fixture = try SlackPresetFixture(version: "4.60.0")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try !ThemeRuntimeSelection.slackIsEnabled(stateRoot: fixture.state))

    let inspector = EnvironmentProviderInspector(slackPreset: fixture.preset)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home,
      stateRoot: fixture.state,
      inspector: inspector
    )
    let enabled = try fixture.composition(enabled: true)
    let enabledInspection = inspector.inspect(
      composition: enabled, homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(enabledInspection.entries.contains { $0.status == .authorityRequired })
    _ = try coordinator.applyLocked(
      composition: enabled,
      inspection: enabledInspection,
      adoptionDigest: nil,
      themeBridges: EnvironmentThemeBridgeState(entries: [])
    )
    try coordinator.finishApplyLocked(composition: enabled)
    #expect(try ThemeRuntimeSelection.slackIsEnabled(stateRoot: fixture.state))

    let disabled = try fixture.composition(enabled: false)
    _ = try coordinator.applyLocked(
      composition: disabled,
      inspection: inspector.inspect(
        composition: disabled, homeDirectory: fixture.home, stateRoot: fixture.state),
      adoptionDigest: nil,
      themeBridges: EnvironmentThemeBridgeState(entries: [])
    )
    try coordinator.finishApplyLocked(composition: disabled)
    #expect(try !ThemeRuntimeSelection.slackIsEnabled(stateRoot: fixture.state))
    #expect(FileManager.default.fileExists(atPath: fixture.bundle.path))
  }

  @Test
  func themeChangesEmitPayloadOnlyUnderAuthorityWhileExplicitGetRemainsAvailable() async throws {
    let fixture = try SlackPresetFixture(version: "4.60.0")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))

    func runner(enabled: Bool) -> ThemeSetCommandRunner {
      ThemeSetCommandRunner(
        preflight: { _, _, _, _ in },
        activate: { package, _, stateRoot, _, _ in
          let manifest = try ThemeActivator(root: stateRoot).activate(package: package)
          return ThemeActivationResult(
            manifest: manifest,
            reconciliation: try ReconciliationRecord(manifest: manifest, results: [])
          )
        },
        slackIsEnabled: { _ in enabled }
      )
    }
    let disabled = try await runner(enabled: false).execute(
      package: package, stateRoot: fixture.state, consumerPaths: testConsumerPaths(),
      dryRun: false, expectedActiveGenerationID: nil, json: true)
    #expect(disabled.succeeded)
    #expect(try jsonObject(disabled.output)["slack_theme"] == nil)

    let explicit = try ManualThemePayloadStore(root: fixture.state).payload(
      targetID: SlackAdapter.id)
    #expect(explicit == "#1e1e2e,#cba6f7,#a6e3a1,#f38ba8\n")

    let enabled = try await runner(enabled: true).execute(
      package: package, stateRoot: fixture.state, consumerPaths: testConsumerPaths(),
      dryRun: false, expectedActiveGenerationID: nil, json: true)
    #expect(enabled.succeeded)
    #expect(
      try jsonObject(enabled.output)["slack_theme"] as? String
        == explicit.trimmingCharacters(in: .newlines)
    )
  }
}

private struct SlackPresetFixture {
  let root: URL
  let home: URL
  let state: URL
  let bundle: URL

  var preset: EnvironmentSlackPreset { EnvironmentSlackPreset(bundleURL: bundle) }

  init(version: String) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-slack-preset-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    bundle = root.appending(path: "Slack.app", directoryHint: .isDirectory)
    let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleShortVersionString": version],
      format: .xml, options: 0)
    try plist.write(to: contents.appending(path: "Info.plist"))
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))
    _ = try ThemeActivator(root: state).activate(package: package)
  }

  func composition(enabled: Bool) throws -> EnvironmentComposition {
    let profile = root.appending(path: "profile-\(enabled).toml")
    try """
    schema_version = 1
    [terminal]
    provider = "disabled"
    [shell]
    provider = "disabled"
    [editor]
    provider = "disabled"
    [tools]
    bat = false
    eza = false
    btop = false
    yazi = false
    [presets]
    slack = \(enabled)
    """.write(to: profile, atomically: true, encoding: .utf8)
    return try EnvironmentConfigurationComposer().compose(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profile: PortableProfileLoader().load(at: profile, required: true),
      stateRoot: state
    )
  }
}
