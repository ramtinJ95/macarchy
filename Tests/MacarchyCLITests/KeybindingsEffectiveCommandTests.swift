import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingsEffectiveCommandTests {
  @Test
  func listShowDoctorPlanAndApplyPreviewConsumeOneAttributedEffectiveState() throws {
    let fixture = try EffectiveCommandFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let state = fixture.inspect()

    let list = try KeybindingsListCommandRunner.live.execute(effectiveState: state, json: true)
    let listReport = try fixture.json(list.output)
    let listed = try #require(listReport["bindings"] as? [[String: Any]])
    let disabled = try #require(listReport["disabled_defaults"] as? [[String: Any]])

    let show = try KeybindingsShowCommandLoader(
      read: readSkhdConfiguration,
      loadCatalog: { try SkhdKeybindingCatalogLoader().load(at: $0) },
      loadTheme: { _ in try fixture.theme() }
    ).load(effectiveState: state, stateRoot: fixture.stateRoot)

    let doctor = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: state,
      json: true
    )
    let doctorReport = try fixture.json(doctor.output)
    let findings = try #require(doctorReport["findings"] as? [[String: Any]])

    let plan = try KeybindingsPlanCommandRunner.live.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let planReport = try fixture.json(plan.output)
    let planned = try #require(planReport["bindings"] as? [[String: Any]])

    let apply = try KeybindingsApplyCommandRunner(
      lifecycle: KeybindingLifecycleController(
        preflight: {},
        restart: {},
        reload: {},
        verifyProcess: {}
      )
    ).preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let applyReport = try fixture.json(apply.output)

    let expectedIdentities = ["alt-j", "cmd-x"]
    #expect(list.succeeded)
    #expect(show.rows.map(\.identity) == expectedIdentities)
    #expect(listed.compactMap { $0["identity"] as? String } == expectedIdentities)
    #expect(planned.compactMap { $0["identity"] as? String } == expectedIdentities)
    #expect(
      listed.compactMap { $0["command_source"] as? String } == [
        "user_replacement", "user_addition",
      ])
    #expect(show.rows.compactMap(\.commandSource) == ["user_replacement", "user_addition"])
    #expect(disabled.first?["identity"] as? String == "alt-k")
    #expect(disabled.first?["command_source"] as? String == "packaged_default")
    #expect(listReport["generation_agreement"] as? String == "missing")
    #expect(
      findings.contains {
        $0["id"] as? String == "effective.disabled"
          && $0["identities"] as? [String] == ["alt-k"]
      }
    )
    #expect(plan.succeeded)
    #expect(apply.succeeded)
    #expect(applyReport["outcome"] as? String == "planned")
    #expect(applyReport["mutated"] as? Bool == false)
  }
}

private struct EffectiveCommandFixture {
  let root: URL
  let home: URL
  let resources: URL
  let profile: URL
  let stateRoot: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-effective-command-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    resources = root.appending(path: "resources", directoryHint: .isDirectory)
    profile = root.appending(path: "dotfiles/profile.toml")
    stateRoot = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    for directory in [
      resources,
      profile.deletingLastPathComponent(),
      home.appending(path: ".config/skhd", directoryHint: .isDirectory),
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    try "alt - j : default south\nalt - k : default north\n".write(
      to: resources.appending(path: "defaults.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try Self.metadata([
      ("alt-j", "Focus south", 1),
      ("alt-k", "Focus north", 2),
    ]).write(
      to: resources.appending(path: "metadata.toml"),
      atomically: true,
      encoding: .utf8
    )
    try """
    schema_version = 1
    [keybindings]
    override = "personal.skhdrc"
    metadata = "personal-metadata.toml"
    disabled = ["alt-k"]
    """.write(to: profile, atomically: true, encoding: .utf8)
    try "alt - j : personal south\ncmd - x : personal command\n".write(
      to: profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try Self.metadata([
      ("alt-j", "Personal focus", 1),
      ("cmd-x", "Personal command", 2),
    ]).write(
      to: profile.deletingLastPathComponent().appending(path: "personal-metadata.toml"),
      atomically: true,
      encoding: .utf8
    )
  }

  func inspect() -> KeybindingEffectiveState {
    KeybindingEffectiveStateInspector().inspect(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: true,
      stateRoot: stateRoot
    )
  }

  func json(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  func theme() throws -> NormalizedTheme {
    let fixture = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures/Golden/catppuccin-mocha/theme.json")
    return try JSONDecoder().decode(NormalizedTheme.self, from: Data(contentsOf: fixture))
  }

  private static func metadata(_ records: [(String, String, Int)]) -> String {
    records.reduce(into: "schema_version = 1\n") { text, record in
      text += """

        [[bindings]]
        identity = "\(record.0)"
        label = "\(record.1)"
        category = "Test"
        order = \(record.2)
        """
    }
  }
}
