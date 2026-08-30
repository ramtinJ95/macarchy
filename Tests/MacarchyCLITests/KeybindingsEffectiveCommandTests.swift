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
      stateRoot: fixture.stateRoot,
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

    let expectedPresentedIdentities = ["cmd-a", "cmd-x", "alt-j"]
    #expect(list.succeeded)
    #expect(show.rows.map(\.identity) == expectedPresentedIdentities)
    #expect(
      listed.compactMap { $0["identity"] as? String } == expectedPresentedIdentities
    )
    #expect(
      planned.compactMap { $0["identity"] as? String } == ["alt-j", "cmd-a", "cmd-x"]
    )
    #expect(
      listed.compactMap { $0["command_source"] as? String } == [
        "user_addition", "user_addition", "user_replacement",
      ])
    #expect(
      show.rows.compactMap(\.commandSource) == [
        "user_addition", "user_addition", "user_replacement",
      ])
    #expect(disabled.first?["identity"] as? String == "alt-k")
    #expect(disabled.first?["command_source"] as? String == "packaged_default")
    #expect(disabled.first?["metadata_source"] as? String == "packaged_default")
    #expect(listReport["generation_agreement"] as? String == "missing")
    #expect(listReport["schema_version"] as? Int == 2)
    #expect(listReport["operation"] as? String == "keybindings_list_effective")
    #expect(show.heading == "Desired Managed Keybindings")
    #expect(show.stateMessage.contains("Not configured"))
    #expect(show.rowDescription == "desired shortcuts")
    #expect(
      findings.contains {
        $0["id"] as? String == "effective.disabled"
          && $0["identities"] as? [String] == ["alt-k"]
      }
    )
    #expect(doctorReport["schema_version"] as? Int == 2)
    #expect(doctorReport["operation"] as? String == "keybindings_doctor_effective")
    #expect(plan.succeeded)
    #expect(apply.succeeded)
    #expect(applyReport["outcome"] as? String == "planned")
    #expect(applyReport["mutated"] as? Bool == false)
  }

  @Test
  func differingGenerationIsVisibleAsDesiredDriftInPopup() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let desired = fixture.inspect()
    let composition = try #require(desired.configuration.composition)
    try fixture.publish(
      configuration: try #require(composition.renderedConfiguration),
      inputDigest: sha256Digest(Data("different inputs".utf8)),
      renderedDigest: try #require(composition.renderedDigest)
    )
    let state = fixture.inspect()

    let content = try fixture.show(state)

    #expect(state.generationAgreement == .differs)
    #expect(content.heading == "Desired Managed Keybindings")
    #expect(content.stateMessage.contains("Drift detected"))
    #expect(content.stateMessage.contains("Showing desired bindings"))
  }

  @Test
  func corruptGenerationFailsListDoctorAndPopup() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let keybindings = fixture.stateRoot.appending(
      path: "keybindings", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: keybindings, withIntermediateDirectories: true)
    try Data("not a symlink".utf8).write(to: keybindings.appending(path: "current"))
    let state = fixture.inspect()

    let list = try KeybindingsListCommandRunner.live.execute(effectiveState: state, json: true)
    let doctor = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: state,
      stateRoot: fixture.stateRoot,
      json: true
    )
    let doctorReport = try fixture.json(doctor.output)

    #expect(!list.succeeded)
    #expect(!doctor.succeeded)
    #expect(doctorReport["outcome"] as? String == "unhealthy")
    #expect(throws: KeybindingsShowError.self) {
      try fixture.show(state)
    }
  }

  @Test
  func interruptedOrCorruptTransactionFailsEffectiveDoctorClosed() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.stateRoot, withIntermediateDirectories: true)
    let transaction = KeybindingApplyTransaction(
      operation: .installEntry,
      phase: .activating,
      generationID: "k-01234567-89ab-cdef-0123-456789abcdef",
      previousGenerationID: nil,
      generationCreated: true
    )
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(transaction)

    let interrupted = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: fixture.inspect(),
      stateRoot: fixture.stateRoot,
      json: true
    )
    let interruptedReport = try fixture.json(interrupted.output)
    let interruptedFindings = try #require(
      interruptedReport["findings"] as? [[String: Any]])

    #expect(!interrupted.succeeded)
    #expect(interruptedReport["outcome"] as? String == "unhealthy")
    #expect(
      interruptedFindings.contains {
        ($0["id"] as? String)?.hasPrefix("transaction.recovery.install_entry.activating.")
          == true
      }
    )

    try Data("{}".utf8).write(
      to: fixture.stateRoot.appending(path: "keybindings/transaction.json"),
      options: .atomic
    )
    let corrupt = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: fixture.inspect(),
      stateRoot: fixture.stateRoot,
      json: true
    )
    let corruptFindings = try #require(
      fixture.json(corrupt.output)["findings"] as? [[String: Any]])
    #expect(!corrupt.succeeded)
    #expect(corruptFindings.contains { $0["id"] as? String == "transaction.invalid" })
  }

  @Test
  func repeatedEffectiveDiagnosticCodesHaveStableUniqueIDs() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    try "unsupported line\nalso unsupported\n".write(
      to: fixture.profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    let state = fixture.inspect()
    let doctor = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: state,
      stateRoot: fixture.stateRoot,
      json: true
    )
    let findings = try #require(
      fixture.json(doctor.output)["findings"] as? [[String: Any]])
    let syntaxIDs = findings.compactMap { finding -> String? in
      guard let id = finding["id"] as? String, id.hasPrefix("effective.unsupported_syntax.")
      else { return nil }
      return id
    }

    #expect(syntaxIDs.count == 2)
    #expect(Set(syntaxIDs).count == 2)
    #expect(syntaxIDs.contains { $0.hasSuffix("line-1") })
    #expect(syntaxIDs.contains { $0.hasSuffix("line-2") })
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
    try "alt - j : personal south\ncmd - x : personal command\ncmd - a : tied order\n".write(
      to: profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try Self.metadata([
      ("alt-j", "Personal focus", 20),
      ("cmd-x", "Personal command", 1),
      ("cmd-a", "Tied order", 1),
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

  func show(_ state: KeybindingEffectiveState) throws -> KeybindingsPopupContent {
    try KeybindingsShowCommandLoader(
      read: readSkhdConfiguration,
      loadCatalog: { try SkhdKeybindingCatalogLoader().load(at: $0) },
      loadTheme: { _ in try theme() }
    ).load(effectiveState: state, stateRoot: stateRoot)
  }

  func publish(configuration: String, inputDigest: String, renderedDigest: String) throws {
    let generationID = "k-01234567-89ab-cdef-0123-456789abcdef"
    let keybindings = stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
    let generation = keybindings.appending(
      path: "generations/\(generationID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    try JSONEncoder().encode(
      KeybindingGenerationManifest(
        generationID: generationID,
        inputDigest: inputDigest,
        renderedDigest: renderedDigest
      )
    ).write(to: generation.appending(path: "manifest.json"))
    try Data(configuration.utf8).write(to: generation.appending(path: "skhdrc"))
    for file in ["manifest.json", "skhdrc"] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444],
        ofItemAtPath: generation.appending(path: file).path
      )
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: generation.path)
    try FileManager.default.createSymbolicLink(
      atPath: keybindings.appending(path: "current").path,
      withDestinationPath: "generations/\(generationID)"
    )
  }

  func remove() {
    let generation = stateRoot.appending(
      path: "keybindings/generations/k-01234567-89ab-cdef-0123-456789abcdef"
    )
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: generation.path)
    try? FileManager.default.removeItem(at: root)
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
