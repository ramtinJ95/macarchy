import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct UnifiedSetupPlanTests {
  @Test
  func firstInstallPreviewsHerdrWithoutPublishingThemeAndPreservesAdoptionAfterBootstrap() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = root.appending(path: "profile.toml")
    try "schema_version = 1\n[presets]\nherdr = true\n".write(
      to: profile, atomically: true, encoding: .utf8)
    let context = try liveContext(root: root, machine: "first", profile: profile)
    let configuration = context.homeDirectory.appending(path: ".config/herdr/config.toml")
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = "[theme]\nname = \"nord\"\n"
    try original.write(to: configuration, atomically: true, encoding: .utf8)
    let before = try inventory(root)

    let first = try readyPlan(context)
    #expect(first.model.theme.status == "activation_required")
    #expect(first.report.files.contains { $0.id == "herdr_configuration" })
    #expect(try inventory(root) == before)
    #expect(try String(contentsOf: configuration, encoding: .utf8) == original)
    let approval = first.report.adoption.first { $0.id == "environment" }?.digest
    #expect(approval != nil)

    _ = try ThemeActivator(root: context.stateRoot).activate(package: first.model.themePackage)
    let active = try readyPlan(context)
    #expect(active.model.theme.status == "preserve")
    #expect(active.report.adoption.first { $0.id == "environment" }?.digest == approval)
    #expect(try String(contentsOf: configuration, encoding: .utf8) == original)

    let current = context.stateRoot.appending(path: "current")
    try FileManager.default.removeItem(at: current)
    try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: "missing")
    let invalid = try UnifiedSetupPlanCommandRunner.live.prepare(context: context).report
    #expect(invalid.outcome == "blocked")
  }

  @Test(arguments: [false, true])
  func desktopOptOutDoesNotRequireAdoptionOfExternalKeybindings(disabled: Bool) throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    if disabled {
      try fixture.writeMachineProfile("schema_version = 1\n[desktop]\nprovider = 'disabled'\n")
    }
    let plan = try fixture.planner(
      requiredAdoptions: .init(keybindings: "reviewed-keybindings")
    ).prepare(context: fixture.context).report
    #expect(plan.adoption.map(\.id) == (disabled ? [] : ["keybindings"]))
    #expect(!plan.actions.contains { $0.stage == "desktop" })
  }

  @Test
  func sparsePortableProfileProducesTheSameDelegatedIntentAcrossMachineRoots() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileText = """
      schema_version = 1
      [yabai]
      window_gap = 11
      [kitty]
      font_size = 13
      [zsh]
      hook = "portable.zsh"
      [tools]
      btop = false
      """
    let firstProfile = root.appending(path: "first/dotfiles/profile.toml")
    let secondProfile = root.appending(path: "second/dotfiles/profile.toml")
    for profile in [firstProfile, secondProfile] {
      try FileManager.default.createDirectory(
        at: profile.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try profileText.write(to: profile, atomically: true, encoding: .utf8)
      try "portable-hook-marker=1\n".write(
        to: profile.deletingLastPathComponent().appending(path: "portable.zsh"),
        atomically: true,
        encoding: .utf8
      )
    }
    let firstContext = try liveContext(root: root, machine: "first", profile: firstProfile)
    let secondContext = try liveContext(root: root, machine: "second", profile: secondProfile)
    let first = try readyPlan(firstContext)
    let second = try readyPlan(secondContext)
    let firstComponents = try #require(first.report.components)
    let secondComponents = try #require(second.report.components)
    let firstYabairc = try #require(
      firstComponents.desktop.report["rendered_yabairc"]?.string
    )
    let secondYabairc = try #require(
      secondComponents.desktop.report["rendered_yabairc"]?.string
    )
    let firstEnvironment = try normalizedArtifacts(
      firstComponents.environment.report,
      home: firstContext.homeDirectory
    )
    let secondEnvironment = try normalizedArtifacts(
      secondComponents.environment.report,
      home: secondContext.homeDirectory
    )

    #expect(first.report.providers == second.report.providers)
    #expect(first.report.fieldOrigins == second.report.fieldOrigins)
    #expect(firstYabairc.contains("window_gap 11"))
    #expect(firstYabairc == secondYabairc)
    #expect(firstComponents.desktop.report["keybindings"]?["outcome"]?.string == "ready")
    #expect(secondComponents.desktop.report["keybindings"]?["outcome"]?.string == "ready")
    #expect(
      try normalizedArtifacts(
        firstComponents.desktop.report["sketchybar"],
        home: firstContext.homeDirectory
      )
        == normalizedArtifacts(
          secondComponents.desktop.report["sketchybar"],
          home: secondContext.homeDirectory
        )
    )
    #expect(firstEnvironment == secondEnvironment)
    #expect(firstEnvironment["kitty/kitty.conf"]?.contains("font_size 13") == true)
    #expect(firstEnvironment["zsh/.zshrc"]?.contains("portable-hook-marker=1") == true)
    #expect(firstEnvironment["btop/btop.conf"] == nil)
    #expect(!first.model.capabilities.map(\.id).contains("btop"))
    #expect(first.report.files.map(\.path) != second.report.files.map(\.path))
  }

  @Test
  func machineProfileChangesOnlyItsDeclaredProviderExceptions() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = root.appending(path: "profile.toml")
    try "schema_version = 1\n[tools]\nbtop = false\n".write(
      to: profile,
      atomically: true,
      encoding: .utf8
    )
    let standardContext = try liveContext(root: root, machine: "standard", profile: profile)
    let exceptionalContext = try liveContext(root: root, machine: "exceptional", profile: profile)
    try """
    schema_version = 1
    [top_bar]
    provider = "disabled"
    [terminal]
    provider = "disabled"
    """.write(to: exceptionalContext.machineProfileURL, atomically: true, encoding: .utf8)
    let standard = try readyPlan(standardContext)
    let exceptional = try readyPlan(exceptionalContext)
    let exceptionalComponents = try #require(exceptional.report.components)
    let exceptionalEnvironmentArtifacts = try #require(
      exceptionalComponents.environment.report["rendered_artifacts"]?.object
    )

    #expect(
      standard.report.providers.merging(["top_bar": "disabled", "terminal": "disabled"]) {
        _, new in new
      } == exceptional.report.providers
    )
    #expect(exceptional.report.fieldOrigins["tools.btop"] == "portable")
    #expect(exceptional.report.fieldOrigins["top_bar.provider"] == "machine")
    #expect(exceptional.report.fieldOrigins["terminal.provider"] == "machine")
    #expect(
      Set(standard.model.capabilities.map(\.id)).subtracting([
        "kitty", "kitty-meslo-font", "sketchybar",
      ])
        == Set(exceptional.model.capabilities.map(\.id))
    )
    #expect(!standard.model.capabilities.map(\.id).contains("btop"))
    #expect(
      standard.report.components?.desktop.report["sketchybar"]?["rendered_artifacts"]?.object
        != nil
    )
    #expect(
      exceptionalComponents.desktop.report["sketchybar"]?["rendered_artifacts"]?.object == nil
    )
    #expect(
      exceptionalComponents.environment.report["terminal_provider"]?.string == "disabled"
    )
    #expect(
      exceptionalEnvironmentArtifacts["kitty/kitty.conf"] == nil
    )
  }

  @Test
  func liveUnifiedPlanUsesTheMachineOverlayAndRemainsReadOnly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    // This tests the live profile overlay, not the host's incumbent Borders job.
    try "schema_version = 1\n[focus_ring]\nprovider = \"disabled\"\n[kitty]\nfont_size = 15\n"
      .write(
        to: state.appending(path: "machine.toml"),
        atomically: true,
        encoding: .utf8
      )
    let before = try inventory(root)

    var runner = UnifiedSetupPlanCommandRunner.live
    runner.packageInventoryReader = { HomebrewPackageObservation(packages: [], issues: []) }
    let execution = try runner.execute(
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
    let adoption = try #require(report["adoption"] as? [[String: Any]])

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
    #expect(adoption.isEmpty)
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
    var runner = UnifiedSetupPlanCommandRunner(
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
      environmentPlanner: { context, profile, _ in
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

    runner.standardBrewfile = { _ in
      try SetupBrewfile.read(at: repositoryRoot.appending(path: "Environment/Brewfile"))
    }
    runner.packageInventoryReader = { .init(packages: [], issues: []) }
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
          "arm64", "atuin", "bat", "borders", "btop", "eza", "homebrew", "kitty", "macos-26",
          "neovim", "sketchybar", "skhd", "starship", "yabai", "yazi",
          "kitty-meslo-font", "zsh-autosuggestions", "zsh-syntax-highlighting", "fzf", "zoxide",
        ]
    )
    #expect((packages["formulae"] as? [String])?.contains("bat") == true)
    #expect((packages["casks"] as? [String])?.contains("kitty") == true)
    #expect(Set(adoption.compactMap { $0["id"] }) == ["keybindings", "environment"])
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
      environmentPlanner: { context, profile, _ in try unexpected(context, profile) }
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
      environmentPlanner: { _, _, _ in
        try component("{\"outcome\":\"ready\",\"entries\":[],\"actions\":[]}")
      },
      packageInventoryReader: { .init(packages: [], issues: []) },
      standardBrewfile: { _ in SetupBrewfile(packages: []) }
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
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: root.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: profilesRequired,
      machineProfileURL: machine,
      machineProfileRequired: profilesRequired,
      stateRoot: state,
      homeDirectory: home
    )
  }

  private func liveContext(
    root: URL,
    machine: String,
    profile: URL
  ) throws -> UnifiedSetupPlanContext {
    let home = root.appending(path: "\(machine)/home", directoryHint: .isDirectory)
    let state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    return UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory),
      keybindingsResourcesRoot: repositoryRoot.appending(
        path: "Keybindings", directoryHint: .isDirectory),
      desktopResourcesRoot: repositoryRoot.appending(
        path: "Desktop", directoryHint: .isDirectory),
      environmentResourcesRoot: repositoryRoot.appending(
        path: "Environment", directoryHint: .isDirectory),
      profileURL: profile,
      profileRequired: true,
      machineProfileURL: state.appending(path: "machine.toml"),
      machineProfileRequired: false,
      stateRoot: state,
      homeDirectory: home
    )
  }

  private func readyPlan(
    _ context: UnifiedSetupPlanContext
  ) throws -> (model: UnifiedSetupDesiredModel, report: UnifiedSetupPlanReport) {
    let live = UnifiedSetupPlanCommandRunner.live
    var runner = UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: live.capabilityIsAvailable,
      desktopPlanner: live.desktopPlanner,
      environmentPlanner: { context, profile, bootstrapTheme in
        let noMutation: @Sendable (URL) throws -> Void = { _ in
          throw BordersServiceError.blocked("planning must not mutate the test service")
        }
        let borders = EnvironmentBordersRuntime(
          inspect: { _ in .stopped }, preflight: { _ in .stopped },
          recoveryPreflight: { _ in .stopped },
          start: noMutation, restart: noMutation, stop: noMutation,
          request: { _, _ in
            throw BordersServiceError.blocked("planning must not request appearance")
          })
        return try SetupComponentExecution(
          EnvironmentPlanCommandRunner(
            prerequisites: .assumed, bordersRuntime: borders
          ).execute(
            resourcesRoot: context.environmentResourcesRoot,
            profileURL: context.profileURL, profileRequired: context.profileRequired,
            stateRoot: context.stateRoot, homeDirectory: context.homeDirectory,
            json: true, profile: profile, bootstrapTheme: bootstrapTheme))
      })
    runner.packageInventoryReader = { .init(packages: [], issues: []) }
    let preparation = try runner.prepare(context: context)
    guard case .ready(let model, let report) = preparation else {
      throw SetupComponentReportError(description: "Expected a ready unified setup plan")
    }
    return (model, report)
  }

  private func normalizedArtifacts(
    _ report: JSONValue?,
    home: URL
  ) throws -> [String: String] {
    let artifacts = try #require(report?["rendered_artifacts"]?.object)
    var normalized = [String: String]()
    for (path, value) in artifacts {
      normalized[path] = try #require(value.string).replacingOccurrences(
        of: home.path,
        with: "$HOME"
      )
    }
    return normalized
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
