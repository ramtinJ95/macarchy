import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct GuidedSetupTests {
  @Test
  func questionnaireEmitsOnlySelectionsThatDifferFromDefaults() throws {
    let responses = Mutex([
      "no", "", "no", "no",
      "no", "no", "", "no", "",
      "yes", "no", "yes", "no", "yes", "no",
    ])
    let answers = try GuidedSetupQuestionnaire(
      io: GuidedSetupIO(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { _ in }
      )
    ).collect()
    let profile = try PortableProfileLoader().decode(
      answers.profileTOML,
      source: URL(filePath: "/tmp/profile.toml")
    )

    #expect(profile.desktop.provider == .disabled)
    #expect(profile.topBar == .sketchybar)
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
    #expect(!answers.profileTOML.contains("[top_bar]"))
    #expect(!answers.profileTOML.contains("eza = true"))
  }

  @Test
  func guidedSetupWritesPlansApprovesAndDelegatesToUnifiedApply() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    let responses = Mutex(["yes", "yes", "yes"])
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
        requiredAdoptions: UnifiedSetupAdoptionApprovals(yabai: approval),
        plannedStages: [.desktop]
      ),
      apply: { receivedContext, _, installDependencies, adoptions in
        events.withLock { $0.append("apply") }
        #expect(receivedContext.profileURL == context.profileURL)
        #expect(installDependencies)
        #expect(adoptions == UnifiedSetupAdoptionApprovals(yabai: approval))
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
      apply: { _, _, _, _ in
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

  @Test
  func adoptionRequiresAnExplicitYesBeforeMutation() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    let approval = "sha256:reviewed-yabai"
    let responses = Mutex([""])
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(
        requiredAdoptions: UnifiedSetupAdoptionApprovals(yabai: approval)
      ),
      apply: { _, _, _, _ in
        Issue.record("Apply must not run when adoption confirmation defaults to no")
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
      answers: GuidedSetupAnswers()
    )

    #expect(execution.succeeded)
    #expect(execution.output.contains("stopped before mutation"))
    #expect(FileManager.default.fileExists(atPath: context.profileURL.path))
  }

  @Test
  func finalApplyConfirmationDefaultsToNo() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = guidedContext(fixture)
    let responses = Mutex([""])
    let runner = GuidedSetupCommandRunner(
      planner: fixture.planner(),
      apply: { _, _, _, _ in
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
      answers: GuidedSetupAnswers()
    )

    #expect(execution.succeeded)
    #expect(execution.output.contains("stopped before mutation"))
  }

  private func guidedContext(_ fixture: ApplyFixture) -> UnifiedSetupPlanContext {
    let context = fixture.context
    return UnifiedSetupPlanContext(
      themesRoot: context.themesRoot,
      keybindingsResourcesRoot: context.keybindingsResourcesRoot,
      desktopResourcesRoot: context.desktopResourcesRoot,
      environmentResourcesRoot: context.environmentResourcesRoot,
      profileURL: context.profileURL,
      profileRequired: true,
      machineProfileURL: context.machineProfileURL,
      machineProfileRequired: false,
      stateRoot: context.stateRoot,
      homeDirectory: context.homeDirectory
    )
  }
}
