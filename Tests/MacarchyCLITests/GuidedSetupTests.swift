import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct GuidedSetupTests {
  @Test
  func menuEmitsOnlySelectionsThatDifferFromDefaults() throws {
    let toggled = Set([0, 2, 3, 4, 7, 8, 10, 12, 14, 16, 20, 21])
    var keys = [String]()
    for index in 0...21 {
      if toggled.contains(index) { keys.append(" ") }
      if index < 21 { keys.append("down") }
    }
    keys.append("enter")
    let responses = Mutex(keys)
    let answers = try GuidedSetupSelectionMenu(
      io: GuidedSetupIO(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { _ in }
      ),
      packages: [.init(kind: .cask, name: "spotify"), .init(kind: .formula, name: "jq")]
    ).collect()
    let profile = try PortableProfileLoader().decode(
      answers.profileTOML,
      source: URL(filePath: "/tmp/profile.toml")
    )

    #expect(profile.desktop.provider == .disabled)
    #expect(profile.topBar == .sketchybar)
    #expect(profile.environment.focusRing == .disabled)
    #expect(profile.environment.terminal == .disabled)
    #expect(profile.environment.shell == .disabled)
    #expect(profile.environment.prompt == .disabled)
    #expect(profile.environment.history == .disabled)
    #expect(profile.environment.editor == .disabled)
    #expect(!profile.environment.tools.bat)
    #expect(profile.environment.tools.eza)
    #expect(!profile.environment.tools.btop)
    #expect(profile.environment.tools.yazi)
    #expect(profile.environment.presets.codex)
    #expect(!profile.environment.presets.herdr)
    #expect(profile.environment.presets.pi)
    #expect(!profile.environment.presets.slack)
    #expect(profile.environment.presets.spicetify)
    #expect(!profile.environment.presets.tuicr)
    #expect(!profile.macOSPreferences.enabled)
    #expect(!answers.profileTOML.contains("[top_bar]"))
    #expect(!answers.profileTOML.contains("eza = true"))
    #expect(profile.packages.layers.first?.excludedFormulae == ["jq"])
    #expect(profile.packages.layers.first?.excludedCasks == ["spotify"])
  }

  @Test(arguments: [false, true])
  func packageOptOutsUseTheReviewedLayeredPlan(machineRestoresJq: Bool) async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    try fixture.writeMachineProfile(
      "schema_version = 1\n[packages]\nexclude_casks = [\"docker\"]\n"
        + (machineRestoresJq ? "brewfile = \"Brewfile\"\n" : ""))
    if machineRestoresJq {
      try "brew \"jq\"\n".write(
        to: fixture.state.appending(path: "Brewfile"), atomically: true, encoding: .utf8)
    }
    let machineBytes = try Data(contentsOf: context.machineProfileURL)
    var answers = GuidedSetupAnswers()
    answers.packageExclusions = try SetupPackageAdoptionCommandRunner.parseTargets([
      "formula:jq", "cask:spotify",
    ])
    let transcript = Mutex("")
    let applied = Mutex(false)
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(),
      apply: { _, _, packageApproval, preferencesApproval, adoptions in
        applied.withLock { $0 = true }
        #expect(packageApproval?.hasPrefix("sha256:") == true)
        #expect(preferencesApproval == nil)
        #expect(adoptions == .none)
        return ("applied", true)
      },
      io: GuidedSetupIO(
        read: { "yes" }, write: { output in transcript.withLock { $0 += output } })
    )
    let result = try await runner.execute(
      context: context, consumerPaths: testConsumerPaths(), answers: answers)
    #expect(result.succeeded == !machineRestoresJq)
    #expect(applied.withLock { $0 } == !machineRestoresJq)
    let profile = try PortableProfileLoader().load(at: context.profileURL, required: true)
    #expect(profile.packages.layers.first?.excludedFormulae == ["jq"])
    #expect(profile.packages.layers.first?.excludedCasks == ["spotify"])
    #expect(try Data(contentsOf: context.machineProfileURL) == machineBytes)
    let inventory = try fixture.planner().packageInventory(
      context: context, adoptionState: .available(nil))
    #expect(inventory.proposed.contains { $0.identity.key == "formula:jq" } == machineRestoresJq)
    #expect(!inventory.proposed.contains { ["spotify", "docker"].contains($0.identity.name) })
    #expect(transcript.withLock { $0.contains("Excluded cask:docker by machine") })
    if machineRestoresJq {
      #expect(result.output.contains("override") && result.output.contains("formula:jq"))
    } else {
      #expect(transcript.withLock { $0.contains("--approve-packages") })
    }
  }

  @Test
  func requiredProviderExclusionBlocksBeforeApproval() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    var answers = GuidedSetupAnswers()
    answers.packageExclusions = [.init(kind: .formula, name: "bat")]
    let transcript = Mutex("")
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(),
      apply: { _, _, _, _, _ in
        Issue.record("A required-provider exclusion must block apply")
        return ("unexpected", false)
      },
      io: GuidedSetupIO(
        read: {
          Issue.record("A blocked plan must not ask for approval")
          return nil
        },
        write: { output in transcript.withLock { $0 += output } })
    )
    let result = try await runner.execute(
      context: context, consumerPaths: testConsumerPaths(), answers: answers)
    #expect(!result.succeeded)
    #expect(transcript.withLock { $0.contains("excludes required formula:bat") })
    #expect(FileManager.default.fileExists(atPath: context.profileURL.path))
  }

  @Test
  func closedMenuDoesNotPublishAProfile() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    let responses = Mutex(["down", " "])
    let io = GuidedSetupIO(
      read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } }, write: { _ in })
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(),
      apply: { _, _, _, _, _ in
        Issue.record("A closed menu must not apply")
        return ("unexpected", false)
      },
      io: io,
      select: { try GuidedSetupSelectionMenu(io: io, packages: $0).collect() }
    )
    await #expect(throws: GuidedSetupError.self) {
      try await runner.execute(context: context, consumerPaths: testConsumerPaths())
    }
    #expect(!FileManager.default.fileExists(atPath: context.profileURL.path))
  }

  @Test
  func guidedSetupWritesPlansApprovesAndDelegatesToUnifiedApply() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    let responses = Mutex(["yes"])
    let events = Mutex([String]())
    let approval = "sha256:reviewed-yabai"
    var answers = GuidedSetupAnswers()
    answers.topBar = false
    answers.history = false
    answers.btop = false
    answers.pi = true
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(
        available: { $0.id != "kitty" },
        requiredAdoptions: UnifiedSetupAdoptionApprovals(
          yabai: approval, keybindings: "sha256:reviewed-keys"),
        plannedStages: [.desktop]
      ),
      apply: { receivedContext, _, packageApproval, preferencesApproval, adoptions in
        events.withLock { $0.append("apply") }
        #expect(receivedContext.profileURL == context.profileURL)
        #expect(packageApproval?.hasPrefix("sha256:") == true)
        #expect(preferencesApproval == nil)
        #expect(
          adoptions
            == UnifiedSetupAdoptionApprovals(yabai: approval, keybindings: "sha256:reviewed-keys"))
        let profile = try PortableProfileLoader().load(
          at: receivedContext.profileURL,
          required: true
        )
        #expect(profile.topBar == .disabled)
        #expect(profile.environment.history == .disabled)
        #expect(!profile.environment.tools.btop)
        #expect(profile.environment.presets.pi)
        return ("applied", true)
      },
      io: GuidedSetupIO(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { output in
          if output.contains("Macarchy setup plan") {
            events.withLock { $0.append("plan") }
          }
        }
      )
    )

    let execution = try await runner.execute(
      context: context,
      consumerPaths: testConsumerPaths(),
      answers: answers
    )

    #expect(execution.succeeded)
    #expect(execution.output == "applied")
    #expect(events.withLock { $0 } == ["plan", "apply"])
    #expect(responses.withLock { $0.isEmpty })
  }

  @Test
  func profileWriterNeverReplacesAnExistingProfile() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let profileURL = fixture.root.appending(path: "profile.toml")
    try "existing\n".write(to: profileURL, atomically: true, encoding: .utf8)

    #expect(throws: GuidedSetupError.self) {
      try GuidedSetupProfileWriter.write("replacement\n", to: profileURL)
    }
    #expect(try String(contentsOf: profileURL, encoding: .utf8) == "existing\n")
  }

  @Test
  func profileWriterDoesNotFollowAnExistingProfileLink() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let profileURL = fixture.root.appending(path: "profile.toml")
    let external = fixture.root.appending(path: "external-profile.toml")
    try "external\n".write(to: external, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: profileURL,
      withDestinationURL: external
    )

    #expect(throws: GuidedSetupError.self) {
      try GuidedSetupProfileWriter.write("replacement\n", to: profileURL)
    }
    #expect(try String(contentsOf: external, encoding: .utf8) == "external\n")
  }

  @Test
  func externalPrerequisiteStopsAfterTheVisiblePlan() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    let transcript = Mutex("")
    var answers = GuidedSetupAnswers()
    answers.pi = true
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(available: { _ in false }),
      apply: { _, _, _, _, _ in
        Issue.record("Apply must not run with an external prerequisite")
        return ("unexpected", false)
      },
      io: GuidedSetupIO(
        read: { nil },
        write: { output in transcript.withLock { $0 += output } }
      )
    )

    let execution = try await runner.execute(
      context: context,
      consumerPaths: testConsumerPaths(),
      answers: answers
    )
    let output = transcript.withLock { $0 }

    #expect(!execution.succeeded)
    #expect(execution.output.contains("external prerequisites"))
    #expect(output.contains("Macarchy setup plan [ready]"))
    #expect(output.contains("Permissions:"))
    #expect(output.contains("yabai_accessibility"))
    #expect(output.contains("npm install --global @earendil-works/pi-coding-agent"))
    #expect(FileManager.default.fileExists(atPath: context.profileURL.path))
  }

  @Test(arguments: ["", "no"])
  func singleConfirmationDefaultsToNo(answer: String) async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    let responses = Mutex([answer])
    var answers = GuidedSetupAnswers()
    answers.packageExclusions = [.init(kind: .cask, name: "spotify")]
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(
        requiredAdoptions: .init(
          yabai: "sha256:reviewed-yabai", keybindings: "sha256:reviewed-keys")),
      apply: { _, _, _, _, _ in
        Issue.record("Apply must not run without final confirmation")
        return ("unexpected", false)
      },
      io: GuidedSetupIO(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { _ in }
      )
    )

    let execution = try await runner.execute(
      context: context,
      consumerPaths: testConsumerPaths(),
      answers: answers
    )

    #expect(execution.succeeded)
    #expect(execution.output.contains("stopped before mutation"))
    let profile = try PortableProfileLoader().load(at: context.profileURL, required: true)
    #expect(profile.packages.layers.first?.excludedCasks == ["spotify"])
  }

  @Test(arguments: [1, 2, 3])
  func menuKeepsNativeSelectionSeparateFromItsBooleanValue(toggles: Int) throws {
    let responses = Mutex(
      Array(repeating: "down", count: 18) + Array(repeating: " ", count: toggles) + ["enter"])
    let answers = try GuidedSetupSelectionMenu(
      io: .init(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } }, write: { _ in }
      ), packages: []
    ).collect()
    let profile = try PortableProfileLoader().decode(
      answers.profileTOML, source: URL(filePath: "/tmp/profile.toml"))
    #expect(
      profile.macOSPreferences.selected == (toggles == 3 ? [:] : [.dockAutohide: toggles == 1]))
    #expect(!answers.profileTOML.contains("finder_show_extensions"))
  }

  @Test(arguments: [false, true])
  func singleConfirmationIncludesNativeChanges(approvePreferences: Bool) async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let os = PreferencesTests.MemoryPreferences()
    let lifecycle = PreferencesLifecycle(native: os.native)
    let context = guidedContext(fixture)
    let responses = Mutex([approvePreferences ? "yes" : ""])
    let applied = Mutex(false)
    let transcript = Mutex("")
    let planner = fixture.planner(preferences: lifecycle)
    var answers = GuidedSetupAnswers()
    answers.finderShowExtensions = true
    let runner = GuidedSetupCommandRunner(
      planner: planner,
      apply: { received, _, _, preferencesApproval, _ in
        applied.withLock { $0 = true }
        let expected = try planner.prepare(context: received).report.preferencesApprovalDigest
        #expect(preferencesApproval == expected)
        #expect(preferencesApproval != nil)
        return ("applied", true)
      },
      io: .init(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { output in transcript.withLock { $0 += output } })
    )
    let result = try await runner.execute(
      context: context, consumerPaths: testConsumerPaths(), answers: answers)
    #expect(result.succeeded)
    #expect(applied.withLock { $0 } == approvePreferences)
    #expect(transcript.withLock { $0.contains("Native preference approval:") })
    #expect(os.state.withLock { $0.writes.isEmpty })
  }

  @Test
  func menuContinuesDirectlyThroughReviewIntoApply() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let responses = Mutex(["enter", "yes"])
    let io = GuidedSetupIO(
      read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
      write: { _ in })
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(),
      apply: { context, _, packageApproval, _, _ in
        #expect(packageApproval != nil)
        let saved = try String(contentsOf: context.profileURL, encoding: .utf8)
        #expect(saved.hasPrefix("schema_version = 1\n"))
        #expect(saved.contains("../macarchy-user/zshrc"))
        #expect(saved.contains("../macarchy-user/neovim"))
        return ("applied including desktop", true)
      },
      io: io,
      select: { try GuidedSetupSelectionMenu(io: io, packages: $0).collect() }
    )
    let result = try await runner.execute(
      context: guidedContext(fixture), consumerPaths: testConsumerPaths())
    #expect(result.succeeded)
    #expect(result.output == "applied including desktop")
    #expect(responses.withLock { $0.isEmpty })
  }

  @Test(arguments: [1, 2])
  func menuWrapsToPackageAndTogglesExclusion(toggles: Int) throws {
    let responses = Mutex(["up"] + Array(repeating: " ", count: toggles) + ["enter"])
    let answers = try GuidedSetupSelectionMenu(
      io: .init(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { _ in }),
      packages: [.init(kind: .formula, name: "jq")]
    ).collect()
    #expect(answers.packageExclusions == (toggles == 1 ? [.init(kind: .formula, name: "jq")] : []))
  }

  @Test
  func disabledShellPreventsContradictoryPromptSelection() throws {
    let responses = Mutex(Array(repeating: "down", count: 4) + [" ", "down", " ", "enter"])
    let answers = try GuidedSetupSelectionMenu(
      io: .init(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { _ in }), packages: []
    ).collect()
    #expect(!answers.shell && !answers.prompt && !answers.history)
  }

  private func guidedContext(_ fixture: ApplyFixture) -> UnifiedSetupPlanContext {
    let context = fixture.context
    return UnifiedSetupPlanContext(
      themesRoot: context.themesRoot,
      keybindingsResourcesRoot: context.keybindingsResourcesRoot,
      desktopResourcesRoot: context.desktopResourcesRoot,
      environmentResourcesRoot: context.themesRoot.deletingLastPathComponent().appending(
        path: "Environment"),
      profileURL: context.profileURL,
      profileRequired: true,
      machineProfileURL: context.machineProfileURL,
      machineProfileRequired: false,
      stateRoot: context.stateRoot,
      homeDirectory: context.homeDirectory
    )
  }
}
