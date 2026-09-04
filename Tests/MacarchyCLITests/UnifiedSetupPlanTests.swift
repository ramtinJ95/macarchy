import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct UnifiedSetupPlanTests {
  @Test
  func liveUnifiedPlanUsesTheMachineOverlayAndRemainsReadOnly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try "schema_version = 1\n[kitty]\nfont_size = 15\n".write(
      to: state.appending(path: "machine.toml"),
      atomically: true,
      encoding: .utf8
    )
    let before = try inventory(root)

    let execution = try UnifiedSetupPlanCommandRunner.live.execute(
      context: UnifiedSetupPlanContext(
        themesRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory),
        keybindingsResourcesRoot: repositoryRoot.appending(
          path: "Keybindings", directoryHint: .isDirectory),
        desktopResourcesRoot: repositoryRoot.appending(
          path: "Desktop", directoryHint: .isDirectory),
        environmentResourcesRoot: repositoryRoot.appending(
          path: "Environment", directoryHint: .isDirectory),
        profileURL: state.appending(path: "profile.toml"),
        profileRequired: false,
        machineProfileURL: state.appending(path: "machine.toml"),
        machineProfileRequired: false,
        stateRoot: state,
        homeDirectory: home
      ),
      json: true
    )
    let report = try jsonObject(execution.output)
    let components = try #require(report["components"] as? [String: Any])
    let environment = try #require(
      (components["environment"] as? [String: Any])?["report"] as? [String: Any]
    )
    let artifacts = try #require(environment["rendered_artifacts"] as? [String: String])

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "ready")
    #expect(
      ((components["desktop"] as? [String: Any])?["report"] as? [String: Any])?["outcome"]
        as? String == "ready"
    )
    #expect(
      environment["outcome"] as? String == "ready"
    )
    #expect(artifacts["kitty/kitty.conf"]?.contains("font_size 15") == true)
    #expect(try inventory(root) == before)
  }

  @Test
  func unifiedPlanLayersProfilesDelegatesEverySelectedDomainAndDoesNotMutate() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    let portableDirectory = root.appending(path: "portable", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: portableDirectory,
      withIntermediateDirectories: true
    )
    let portable = portableDirectory.appending(path: "profile.toml")
    let machine = state.appending(path: "machine.toml")
    try """
    schema_version = 1
    [kitty]
    font_size = 13
    [tools]
    bat = false
    """.write(to: portable, atomically: true, encoding: .utf8)
    try """
    schema_version = 1
    [kitty]
    font_size = 15
    [tools]
    bat = true
    """.write(to: machine, atomically: true, encoding: .utf8)
    let before = try inventory(root)
    let calls = Mutex([String]())
    let runner = UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: { _ in false },
      desktopPlanner: { context, profile in
        calls.withLock { $0.append("desktop:\(profile.environment.tools.bat)") }
        return try component(
          """
          {
            "outcome":"ready",
            "keybindings":{
              "outcome":"ready",
              "provider_status":"adoption_required",
              "ownership":"file",
              "adoption_evidence_digest":"sha256:keybindings"
            },
            "provider":{
              "entry_point":"\(context.homeDirectory.path)/.config/yabai/yabairc",
              "status":"install_required",
              "ownership":"absent",
              "adoption_evidence_digest":null
            },
            "sketchybar":{
              "provider":{
                "entry_point":"\(context.homeDirectory.path)/.config/sketchybar/sketchybarrc",
                "status":"install_required",
                "ownership":"absent",
                "adoption_evidence_digest":"sha256:sketchybar"
              }
            },
            "actions":[{"id":"converge_desktop","message":"Converge desktop."}]
          }
          """
        )
      },
      environmentPlanner: { context, profile in
        calls.withLock { $0.append("environment:\(profile.environment.kitty.fontSize ?? 0)") }
        return try component(
          """
          {
            "outcome":"ready",
            "adoption_evidence_digest":"sha256:environment",
            "entries":[{
              "id":"kitty",
              "path":"\(context.homeDirectory.path)/.config/kitty",
              "status":"adoption_required",
              "ownership":"directory_symlink"
            }],
            "actions":[{"id":"converge_environment","message":"Converge environment."}]
          }
          """
        )
      }
    )

    let setupContext = context(
      root: root,
      home: home,
      state: state,
      profile: portable,
      machine: machine
    )
    let execution = try runner.execute(
      context: setupContext,
      json: true
    )
    let report = try jsonObject(execution.output)
    let layers = try #require(report["layers"] as? [[String: Any]])
    let providers = try #require(report["providers"] as? [String: String])
    let theme = try #require(report["theme"] as? [String: Any])
    let packages = try #require(report["packages"] as? [String: Any])
    let capabilities = try #require(report["capabilities"] as? [[String: Any]])
    let adoption = try #require(report["adoption"] as? [[String: String]])
    let permissions = try #require(report["permissions"] as? [[String: String]])

    #expect(execution.succeeded)
    #expect(report["operation"] as? String == "setup_plan")
    #expect(report["outcome"] as? String == "ready")
    #expect(report["mutated"] as? Bool == false)
    #expect(layers.map { $0["status"] as? String } == ["loaded", "loaded"])
    #expect(
      (report["field_origins"] as? [String: String])?["kitty.font_size"] == "machine"
    )
    #expect(providers["desktop"] == "yabai-skhd")
    #expect(providers["terminal"] == "kitty")
    #expect(theme["id"] as? String == "catppuccin-mocha")
    #expect(theme["status"] as? String == "activation_required")
    #expect(
      Set(capabilities.compactMap { $0["id"] as? String })
        == [
          "arm64", "atuin", "bat", "btop", "eza", "homebrew", "kitty", "macos-26",
          "neovim", "sketchybar", "skhd", "starship", "yabai", "yazi",
        ]
    )
    #expect((packages["formulae"] as? [String])?.contains("bat") == true)
    #expect((packages["casks"] as? [String]) == ["kitty"])
    #expect(Set(adoption.compactMap { $0["id"] }) == ["keybindings", "sketchybar", "environment"])
    #expect(permissions.contains { $0["id"] == "yabai_accessibility" })
    #expect(
      calls.withLock { $0 }
        == ["desktop:true", "environment:15.0"]
    )
    let human = try runner.execute(context: setupContext, json: false)
    #expect(human.output.hasPrefix("Macarchy setup plan [ready]:"))
    #expect(human.output.hasSuffix("No changes made."))
    #expect(try inventory(root) == before)
  }

  @Test
  func invalidMachineProfileBlocksBeforeAnyDelegatedPlanOrAction() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let portable = state.appending(path: "profile.toml")
    let machine = state.appending(path: "machine.toml")
    try "schema_version = 1\n[kitty]\nfont_size = 13\n".write(
      to: portable,
      atomically: true,
      encoding: .utf8
    )
    try "schema_version = 1\n[terminal]\nprovider = \"disabled\"\n".write(
      to: machine,
      atomically: true,
      encoding: .utf8
    )
    let calls = Mutex(0)
    let unexpected: UnifiedSetupPlanCommandRunner.ComponentPlanner = { _, _ in
      calls.withLock { $0 += 1 }
      return try component("{\"outcome\":\"ready\",\"actions\":[]}")
    }
    let runner = UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: { _ in true },
      desktopPlanner: unexpected,
      environmentPlanner: unexpected
    )

    let execution = try runner.execute(
      context: context(
        root: root,
        home: home,
        state: state,
        profile: portable,
        machine: machine
      ),
      json: true
    )
    let report = try jsonObject(execution.output)
    let layers = try #require(report["layers"] as? [[String: Any]])

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(layers.compactMap { $0["status"] as? String } == ["loaded", "invalid"])
    #expect((report["actions"] as? [Any])?.isEmpty == true)
    #expect(report["components"] == nil)
    #expect(calls.withLock { $0 } == 0)
  }

  @Test
  func blockedComponentSuppressesEveryActionAndReportsItsDiagnostic() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let runner = UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: { _ in true },
      desktopPlanner: { context, _ in
        try component(
          """
          {
            "outcome":"blocked",
            "keybindings":{
              "outcome":"ready",
              "provider_status":"managed",
              "ownership":"managed",
              "adoption_evidence_digest":null
            },
            "provider":{
              "entry_point":"\(context.homeDirectory.path)/.config/yabai/yabairc",
              "status":"blocked",
              "ownership":"file",
              "adoption_evidence_digest":null
            },
            "actions":[],
            "diagnostics":[{"message":"Unsafe desktop ownership."}]
          }
          """,
          succeeded: false
        )
      },
      environmentPlanner: { _, _ in
        try component("{\"outcome\":\"ready\",\"entries\":[],\"actions\":[]}")
      }
    )

    let execution = try runner.execute(
      context: context(
        root: root,
        home: home,
        state: state,
        profile: state.appending(path: "profile.toml"),
        machine: state.appending(path: "machine.toml"),
        profilesRequired: false
      ),
      json: true
    )
    let report = try jsonObject(execution.output)
    let diagnostics = try #require(report["diagnostics"] as? [[String: Any]])

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect((report["actions"] as? [Any])?.isEmpty == true)
    #expect(diagnostics.first?["code"] as? String == "desktop_plan_blocked")
    #expect(
      (diagnostics.first?["message"] as? String)?.contains("Unsafe desktop ownership") == true)
    #expect(report["components"] != nil)
  }

  private func context(
    root: URL,
    home: URL,
    state: URL,
    profile: URL,
    machine: URL,
    profilesRequired: Bool = true
  ) -> UnifiedSetupPlanContext {
    UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory),
      keybindingsResourcesRoot: root.appending(path: "Keybindings"),
      desktopResourcesRoot: root.appending(path: "Desktop"),
      environmentResourcesRoot: root.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: profilesRequired,
      machineProfileURL: machine,
      machineProfileRequired: profilesRequired,
      stateRoot: state,
      homeDirectory: home
    )
  }

  private func inventory(_ root: URL) throws -> [String] {
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
      )
    )
    return enumerator.compactMap {
      ($0 as? URL)?.path.replacingOccurrences(of: root.path, with: "")
    }
    .sorted()
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-unified-setup-plan-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private func component(_ json: String, succeeded: Bool = true) throws -> SetupComponentExecution {
  try SetupComponentExecution((output: json, succeeded: succeeded))
}
