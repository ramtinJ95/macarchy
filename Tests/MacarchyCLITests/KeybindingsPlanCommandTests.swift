import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingsPlanCommandTests {
  private let runner = KeybindingsPlanCommandRunner.live

  @Test
  func packagedDefaultsProduceAReadOnlyLiveOwnershipPlan() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let execution = try runner.execute(
      resourcesRoot: repositoryRoot.appending(path: "Keybindings", directoryHint: .isDirectory),
      profileURL: home.appending(path: ".config/macarchy/profile.toml"),
      profileRequired: false,
      stateRoot: home.appending(path: ".config/macarchy", directoryHint: .isDirectory),
      homeDirectory: home,
      json: true
    )
    let report = try jsonObject(execution.output)
    let summary = try #require(report["summary"] as? [String: Any])
    let actions = try #require(report["actions"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "ready")
    #expect(report["mutated"] as? Bool == false)
    #expect(summary["effective"] as? Int == 48)
    #expect(summary["packaged_defaults"] as? Int == 48)
    #expect(
      actions.map { $0["id"] as? String }
        == ["publish_generation", "install_provider_entry"]
    )
  }

  @Test
  func profileReplacementAdditionDisableAndMetadataShareOnePlanModel() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try """
    schema_version = 1
    [keybindings]
    override = "personal.skhdrc"
    metadata = "personal-metadata.toml"
    disabled = ["alt-k"]
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    try "cmd - x : custom\nalt - j : replacement\n".write(
      to: fixture.profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try metadata([
      ("alt-j", "Personal focus", 1),
      ("cmd-x", "Custom", 2),
    ]).write(
      to: fixture.profile.deletingLastPathComponent().appending(path: "personal-metadata.toml"),
      atomically: true,
      encoding: .utf8
    )

    let execution = try execute(fixture, json: true, profileRequired: true)
    let report = try jsonObject(execution.output)
    let summary = try #require(report["summary"] as? [String: Any])
    let bindings = try #require(report["bindings"] as? [[String: Any]])
    let disabled = try #require(report["disabled_defaults"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(summary["effective"] as? Int == 2)
    #expect(summary["user_replacements"] as? Int == 1)
    #expect(summary["user_additions"] as? Int == 1)
    #expect(summary["disabled_defaults"] as? Int == 1)
    #expect(bindings.map { $0["identity"] as? String } == ["alt-j", "cmd-x"])
    #expect(disabled.map { $0["identity"] as? String } == ["alt-k"])
    #expect((report["rendered_skhdrc"] as? String)?.hasSuffix("\n") == true)

    let human = try execute(fixture, json: false, profileRequired: true)
    #expect(human.output.contains("- proposed input digest:"))
    #expect(human.output.contains("- rendered digest:"))
    #expect(human.output.contains("--- begin exact bytes ---"))
    #expect(human.output.contains(report["rendered_digest"] as? String ?? "missing"))
  }

  @Test
  func unknownDisableBlocksThePlanWithoutActions() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try """
    schema_version = 1
    [keybindings]
    disabled = ["cmd-z"]
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let execution = try execute(fixture, json: true, profileRequired: true)
    let report = try jsonObject(execution.output)
    let diagnostics = try #require(report["diagnostics"] as? [[String: Any]])
    let actions = try #require(report["actions"] as? [Any])

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(actions.isEmpty)
    #expect(diagnostics.map { $0["code"] as? String } == ["unknown_disabled_identity"])
  }

  @Test
  func validMatchingGenerationAndManagedEntryAreANoOp() throws {
    let fixture = try planFixture()
    var generation: URL?
    defer {
      if let generation {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: generation.path
        )
      }
      try? FileManager.default.removeItem(at: fixture.root)
    }
    try FileManager.default.createDirectory(
      at: fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: fixture.home.appending(path: ".config/skhd/skhdrc").path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )

    let initial = try execute(fixture, json: true, profileRequired: false)
    let initialReport = try jsonObject(initial.output)
    let rendered = try #require(initialReport["rendered_skhdrc"] as? String)
    let renderedDigest = try #require(initialReport["rendered_digest"] as? String)
    let inputDigest = try #require(initialReport["proposed_input_digest"] as? String)
    generation = try publishGeneration(
      stateRoot: fixture.stateRoot,
      rendered: rendered,
      renderedDigest: renderedDigest,
      inputDigest: inputDigest
    )
    try writeOwnershipClaim(fixture)

    let execution = try execute(fixture, json: false, profileRequired: false)

    #expect(execution.succeeded)
    #expect(execution.output.contains("Macarchy keybindings plan [no_change]:"))
    #expect(execution.output.contains("Actions: none"))
    #expect(execution.output.hasSuffix("No changes made."))
  }

  @Test
  func matchingBytesWithDifferentValidatedInputStillPlanReplacement() throws {
    let fixture = try planFixture()
    var generation: URL?
    defer {
      if let generation {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: generation.path
        )
      }
      try? FileManager.default.removeItem(at: fixture.root)
    }
    try FileManager.default.createDirectory(
      at: fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: fixture.home.appending(path: ".config/skhd/skhdrc").path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )
    let initial = try execute(fixture, json: true, profileRequired: false)
    let initialReport = try jsonObject(initial.output)
    let rendered = try #require(initialReport["rendered_skhdrc"] as? String)
    let renderedDigest = try #require(initialReport["rendered_digest"] as? String)
    generation = try publishGeneration(
      stateRoot: fixture.stateRoot,
      rendered: rendered,
      renderedDigest: renderedDigest,
      inputDigest: sha256Digest(Data("different validated input".utf8))
    )
    try writeOwnershipClaim(fixture)

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let actions = try #require(report["actions"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "ready")
    #expect(actions.map { $0["id"] as? String } == ["publish_generation"])
  }

  @Test
  func adoptionPlanReportsExactExistingBehaviorDelta() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let dotfiles = fixture.root.appending(path: "dotfiles-skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    try "alt - j : personal replacement\ncmd - x : personal only\n".write(
      to: dotfiles.appending(path: "skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    let configuration = fixture.home.appending(path: ".config", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: configuration.appending(path: "skhd", directoryHint: .isDirectory),
      withDestinationURL: dotfiles
    )

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let delta = try #require(report["adoption_delta"] as? [String: Any])
    let added = try #require(delta["added"] as? [[String: Any]])
    let removed = try #require(delta["removed"] as? [[String: Any]])
    let changed = try #require(delta["changed"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(added.map { $0["identity"] as? String } == ["alt-k"])
    #expect(removed.map { $0["identity"] as? String } == ["cmd-x"])
    #expect(changed.map { $0["identity"] as? String } == ["alt-j"])
  }

  @Test
  func matchingUnclaimedLinkUsesCurrentGenerationForAdoptionDelta() throws {
    let fixture = try planFixture()
    var generation: URL?
    defer {
      if let generation {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: generation.path
        )
      }
      try? FileManager.default.removeItem(at: fixture.root)
    }
    try FileManager.default.createDirectory(
      at: fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: fixture.home.appending(path: ".config/skhd/skhdrc").path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )
    let existing = "cmd - x : existing generation\n"
    generation = try publishGeneration(
      stateRoot: fixture.stateRoot,
      rendered: existing,
      renderedDigest: sha256Digest(Data(existing.utf8)),
      inputDigest: sha256Digest(Data("existing input".utf8))
    )

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let delta = try #require(report["adoption_delta"] as? [String: Any])
    let added = try #require(delta["added"] as? [[String: Any]])
    let removed = try #require(delta["removed"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(added.map { $0["identity"] as? String } == ["alt-j", "alt-k"])
    #expect(removed.map { $0["identity"] as? String } == ["cmd-x"])
  }

  @Test
  func requiredFailureBoundariesBlockWithoutActions() throws {
    let cases: [(profile: String, override: String?)] = [
      (
        "schema_version = 1\n[keybindings]\noverride = \"personal.skhdrc\"\n",
        "alt - j : first\nalt - j : duplicate\n"
      ),
      (
        "schema_version = 1\n[keybindings]\noverride = \"personal.skhdrc\"\ndisabled = [\"alt-j\"]\n",
        "alt - j : contradiction\n"
      ),
      (
        "schema_version = 1\n[keybindings]\noverride = \"missing.skhdrc\"\n",
        nil
      ),
    ]

    for testCase in cases {
      let fixture = try planFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      try testCase.profile.write(to: fixture.profile, atomically: true, encoding: .utf8)
      if let override = testCase.override {
        try override.write(
          to: fixture.profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
          atomically: true,
          encoding: .utf8
        )
      }

      let execution = try execute(fixture, json: true, profileRequired: true)
      let report = try jsonObject(execution.output)

      #expect(!execution.succeeded)
      #expect(report["outcome"] as? String == "blocked")
      #expect((report["actions"] as? [Any])?.isEmpty == true)
      #expect((report["diagnostics"] as? [Any])?.isEmpty == false)
    }
  }

  @Test
  func pendingApplyTransactionBlocksOrdinaryPlanning() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.stateRoot.appending(path: "keybindings", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(
      KeybindingApplyTransaction(
        operation: .installEntry,
        phase: .currentSelected,
        generationID: "k-01234567-89ab-cdef-0123-456789abcdef",
        previousGenerationID: nil,
        generationCreated: true
      )
    )

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let diagnostics = try #require(report["diagnostics"] as? [[String: Any]])

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(diagnostics.contains { $0["code"] as? String == "keybinding_recovery_required" })
  }

  private func execute(
    _ fixture: PlanFixture,
    json: Bool,
    profileRequired: Bool
  ) throws -> (output: String, succeeded: Bool) {
    try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: profileRequired,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: json
    )
  }

  private func planFixture() throws -> PlanFixture {
    let root = try temporaryDirectory()
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let profileDirectory = root.appending(path: "dotfiles", directoryHint: .isDirectory)
    let resources = root.appending(path: "resources", directoryHint: .isDirectory)
    for directory in [home, profileDirectory, resources] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try "alt - j : default south\nalt - k : default north\n".write(
      to: resources.appending(path: "defaults.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try metadata([
      ("alt-j", "Focus below", 10),
      ("alt-k", "Focus above", 20),
    ]).write(
      to: resources.appending(path: "metadata.toml"),
      atomically: true,
      encoding: .utf8
    )
    return PlanFixture(
      root: root,
      home: home,
      resources: resources,
      profile: profileDirectory.appending(path: "profile.toml"),
      stateRoot: home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    )
  }

  private func publishGeneration(
    stateRoot: URL,
    rendered: String,
    renderedDigest: String,
    inputDigest: String
  ) throws -> URL {
    let generationID = "k-01234567-89ab-cdef-0123-456789abcdef"
    let keybindings = stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
    let generation = keybindings.appending(
      path: "generations/\(generationID)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    let manifest = KeybindingGenerationManifest(
      generationID: generationID,
      inputDigest: inputDigest,
      renderedDigest: renderedDigest
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: generation.appending(path: "manifest.json"))
    try Data(rendered.utf8).write(to: generation.appending(path: "skhdrc"))
    for file in ["manifest.json", "skhdrc"] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444],
        ofItemAtPath: generation.appending(path: file).path
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555],
      ofItemAtPath: generation.path
    )
    try FileManager.default.createSymbolicLink(
      atPath: keybindings.appending(path: "current").path,
      withDestinationPath: "generations/\(generationID)"
    )
    return generation
  }

  private func metadata(_ records: [(String, String, Int)]) -> String {
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

  private func jsonObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func writeOwnershipClaim(_ fixture: PlanFixture) throws {
    let setup = fixture.stateRoot.appending(path: "state/setup", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
    let target = KeybindingProviderInspector.managedTarget
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let record = SetupOwnershipRecord(
      id: KeybindingProviderInspector.ownershipID,
      phase: .applied,
      kind: .symbolicLink,
      targetPath: entry.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(target.utf8)),
      linkDestination: target
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(SetupOwnershipManifest(records: [record])).write(
      to: setup.appending(path: "ownership.json")
    )
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybindings-plan-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private struct PlanFixture {
  let root: URL
  let home: URL
  let resources: URL
  let profile: URL
  let stateRoot: URL
}
