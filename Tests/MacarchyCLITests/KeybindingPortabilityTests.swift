import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingPortabilityTests {
  @Test
  func cleanProfileInheritsEveryPackagedDefault() throws {
    let environment = try isolatedEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.root) }

    let execution = try plan(
      resources: package(named: "package-v1"),
      profile: environment.home.appending(path: ".config/macarchy/profile.toml"),
      profileRequired: false,
      environment: environment
    )
    let report = try jsonObject(execution.output)
    let summary = try #require(report["summary"] as? [String: Any])
    let bindings = try #require(report["bindings"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(summary["effective"] as? Int == 3)
    #expect(summary["packaged_defaults"] as? Int == 3)
    #expect(summary["user_replacements"] as? Int == 0)
    #expect(summary["user_additions"] as? Int == 0)
    #expect(summary["disabled_defaults"] as? Int == 0)
    #expect(bindings.map { $0["identity"] as? String } == ["alt-j", "alt-k", "cmd-b"])
    #expect(bindings.allSatisfy { $0["command_source"] as? String == "packaged_default" })
    #expect(
      report["rendered_skhdrc"] as? String
        == """
        alt - j : package focus south
        alt - k : package focus north
        cmd - b : package open browser v1

        """
    )
  }

  @Test
  func sparseProfileReplacesDisablesAddsAndInheritsUntouchedDefaults() throws {
    let environment = try isolatedEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.root) }
    let profile = portableInputs.appending(path: "profile.toml")
    let before = try portableSnapshot(at: portableInputs)

    let execution = try plan(
      resources: package(named: "package-v1"),
      profile: profile,
      profileRequired: true,
      environment: environment
    )
    let report = try jsonObject(execution.output)
    let summary = try #require(report["summary"] as? [String: Any])
    let bindings = try #require(report["bindings"] as? [[String: Any]])
    let disabled = try #require(report["disabled_defaults"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(summary["effective"] as? Int == 3)
    #expect(summary["packaged_defaults"] as? Int == 3)
    #expect(summary["user_replacements"] as? Int == 1)
    #expect(summary["user_additions"] as? Int == 1)
    #expect(summary["disabled_defaults"] as? Int == 1)
    #expect(bindings.map { $0["identity"] as? String } == ["alt-j", "cmd-b", "cmd-x"])
    #expect(try binding("alt-j", in: bindings)["command_source"] as? String == "user_replacement")
    #expect(try binding("alt-j", in: bindings)["metadata_source"] as? String == "user_overlay")
    #expect(try binding("cmd-b", in: bindings)["command_source"] as? String == "packaged_default")
    #expect(try binding("cmd-b", in: bindings)["metadata_source"] as? String == "packaged_default")
    #expect(try binding("cmd-x", in: bindings)["command_source"] as? String == "user_addition")
    #expect(disabled.map { $0["identity"] as? String } == ["alt-k"])
    #expect(try portableSnapshot(at: portableInputs) == before)
  }

  @Test
  func packagedUpdateChangesOnlyUntouchedEffectiveBehaviorWithoutRewritingInputs() throws {
    let firstEnvironment = try isolatedEnvironment()
    let secondEnvironment = try isolatedEnvironment()
    defer {
      try? FileManager.default.removeItem(at: firstEnvironment.root)
      try? FileManager.default.removeItem(at: secondEnvironment.root)
    }
    let profile = portableInputs.appending(path: "profile.toml")
    let before = try portableSnapshot(at: portableInputs)

    let first = try jsonObject(
      plan(
        resources: package(named: "package-v1"),
        profile: profile,
        profileRequired: true,
        environment: firstEnvironment
      ).output
    )
    let second = try jsonObject(
      plan(
        resources: package(named: "package-v2"),
        profile: profile,
        profileRequired: true,
        environment: secondEnvironment
      ).output
    )
    let firstBindings = try #require(first["bindings"] as? [[String: Any]])
    let secondBindings = try #require(second["bindings"] as? [[String: Any]])

    #expect(
      try binding("alt-j", in: firstBindings)["command"] as? String == "personal focus south")
    #expect(
      try binding("alt-j", in: secondBindings)["command"] as? String == "personal focus south")
    #expect(
      try binding("cmd-x", in: firstBindings)["command"] as? String == "personal open extra")
    #expect(
      try binding("cmd-x", in: secondBindings)["command"] as? String == "personal open extra")
    #expect(
      try binding("cmd-b", in: firstBindings)["command"] as? String == "package open browser v1")
    #expect(
      try binding("cmd-b", in: secondBindings)["command"] as? String == "package open browser v2")
    #expect(first["rendered_digest"] as? String != second["rendered_digest"] as? String)
    #expect(first["proposed_input_digest"] as? String != second["proposed_input_digest"] as? String)
    #expect(try portableSnapshot(at: portableInputs) == before)
  }

  @Test
  func isolatedApplyPublishesDeterministicBytesOutsidePortableInputs() throws {
    let environment = try isolatedEnvironment(createSkhdDirectory: true)
    defer { try? FileManager.default.removeItem(at: environment.root) }
    let dotfiles = environment.root.appending(path: "dotfiles", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: portableInputs, to: dotfiles)
    let profile = dotfiles.appending(path: "profile.toml")
    let before = try portableSnapshot(at: dotfiles)

    let firstPlan = try plan(
      resources: package(named: "package-v1"),
      profile: profile,
      profileRequired: true,
      environment: environment
    )
    let secondPlan = try plan(
      resources: package(named: "package-v1"),
      profile: profile,
      profileRequired: true,
      environment: environment
    )
    #expect(firstPlan.output == secondPlan.output)

    let lifecycle = KeybindingLifecycleController(
      preflight: {},
      restart: {},
      reload: {},
      verifyProcess: {}
    )
    let applied = try KeybindingsApplyCommandRunner(lifecycle: lifecycle).execute(
      resourcesRoot: package(named: "package-v1"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: environment.stateRoot,
      homeDirectory: environment.home,
      json: true
    )
    let applyReport = try jsonObject(applied.output)
    let planned = try jsonObject(firstPlan.output)
    let expected = try #require(planned["rendered_skhdrc"] as? String)
    let generated = try String(
      contentsOf: environment.stateRoot.appending(path: "keybindings/current/skhdrc"),
      encoding: .utf8
    )

    #expect(applied.succeeded)
    #expect(applyReport["outcome"] as? String == "applied")
    #expect(generated == expected)
    #expect(try portableSnapshot(at: dotfiles) == before)
    #expect(
      try recursiveInventory(at: dotfiles)
        == ["keybindings-metadata.toml", "keybindings.skhdrc", "profile.toml"]
    )
    #expect(
      FileManager.default.fileExists(
        atPath: environment.stateRoot.appending(path: "keybindings/current").path
      )
    )
  }

  private func plan(
    resources: URL,
    profile: URL,
    profileRequired: Bool,
    environment: IsolatedKeybindingEnvironment
  ) throws -> (output: String, succeeded: Bool) {
    try KeybindingsPlanCommandRunner.live.execute(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: profileRequired,
      stateRoot: environment.stateRoot,
      homeDirectory: environment.home,
      json: true
    )
  }

  private func binding(
    _ identity: String,
    in bindings: [[String: Any]]
  ) throws -> [String: Any] {
    try #require(bindings.first { $0["identity"] as? String == identity })
  }

  private func portableSnapshot(at root: URL) throws -> [String: Data] {
    try Dictionary(
      uniqueKeysWithValues: recursiveInventory(at: root).map { path in
        (path, try Data(contentsOf: root.appending(path: path)))
      }
    )
  }

  private func recursiveInventory(at root: URL) throws -> [String] {
    let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))
    var paths: [String] = []
    for case let path as String in enumerator {
      let file = root.appending(path: path)
      let values = try file.resourceValues(forKeys: [.isRegularFileKey])
      if values.isRegularFile == true {
        paths.append(path)
      }
    }
    return paths.sorted()
  }

  private func isolatedEnvironment(
    createSkhdDirectory: Bool = false
  ) throws -> IsolatedKeybindingEnvironment {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-portability-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let stateRoot = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    if createSkhdDirectory {
      try FileManager.default.createDirectory(
        at: home.appending(path: ".config/skhd", directoryHint: .isDirectory),
        withIntermediateDirectories: true
      )
    }
    return IsolatedKeybindingEnvironment(root: root, home: home, stateRoot: stateRoot)
  }

  private func package(named name: String) -> URL {
    fixtureRoot.appending(path: name, directoryHint: .isDirectory)
  }

  private var portableInputs: URL {
    fixtureRoot.appending(path: "portable", directoryHint: .isDirectory)
  }

  private var fixtureRoot: URL {
    repositoryRoot.appending(
      path: "Tests/Fixtures/Keybindings/Portability",
      directoryHint: .isDirectory
    )
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func jsonObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }
}

private struct IsolatedKeybindingEnvironment {
  let root: URL
  let home: URL
  let stateRoot: URL
}
