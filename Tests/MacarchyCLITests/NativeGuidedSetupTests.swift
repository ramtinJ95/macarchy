import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct NativeGuidedSetupTests {
  @Test
  func cancelResumeCreateConnectEditAndReapply() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = context(fixture)
    let planner = planner(fixture)
    let apply = runner(planner: planner)
    let transcript = Mutex("")
    let responses = Mutex(["no", "yes"])
    let guided = GuidedSetupCommandRunner(
      planner: planner,
      apply: { context, paths, packages, preferences, adoptions in
        try await apply.execute(
          context: context, consumerPaths: paths, packageApproval: packages,
          preferencesApproval: preferences, adoptions: adoptions, json: true)
      },
      io: GuidedSetupIO(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { output in transcript.withLock { $0 += output } }))
    let cancelled = try await guided.execute(
      context: context, consumerPaths: testConsumerPaths(), answers: answers())
    #expect(cancelled.succeeded, "\(cancelled.output)")
    #expect(cancelled.output.contains("--resume"))
    let profileBytes = try Data(contentsOf: context.profileURL)
    for provider in EnvironmentNativeSeed.Provider.allCases {
      let source = UnifiedSetupNativeStarters.destination(provider, context: context)
      #expect(!FileManager.default.fileExists(atPath: source.path))
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: UnifiedSetupNativeStarters.destination(.zsh, context: context)
          .deletingLastPathComponent().path))
    #expect(try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership() == nil)
    let applied = try await guided.execute(
      context: context, consumerPaths: testConsumerPaths(), resume: true)
    #expect(applied.succeeded, "\(applied.output)\n\(transcript.withLock { $0 })")
    #expect(responses.withLock { $0.isEmpty })
    #expect(try Data(contentsOf: context.profileURL) == profileBytes)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership())
    let profile = try PortableProfileLoader().load(at: context.profileURL, required: true)
    let resolver = EnvironmentConfigurationSourceResolver(
      homeDirectory: context.homeDirectory, stateRoot: context.stateRoot)
    for provider in EnvironmentNativeSeed.Provider.allCases {
      let source = UnifiedSetupNativeStarters.destination(provider, context: context)
      #expect(provider.source(in: profile.environment)?.path == source.path)
      #expect(FileManager.default.fileExists(atPath: source.path))
      let selected = resolver.resolve(provider, profile: profile)
      #expect(selected.status == .editable, "\(selected.message)")
      #expect(selected.source == source.path)
      if provider != .kitty && provider != .zsh {
        #expect(ownership.records.first { $0.id == provider.entryID }?.managedTarget == source.path)
        let receiptSelected = resolver.resolve(provider, profile: .defaults)
        #expect(receiptSelected.status == .editable, "\(receiptSelected.message)")
        #expect(receiptSelected.authority == "native_ownership")
        #expect(receiptSelected.source == source.path)
      }
    }
    let source = UnifiedSetupNativeStarters.destination(.zsh, context: context)
    let edited = try String(contentsOf: source, encoding: .utf8) + "export PERSONAL=edited\n"
    try edited.write(to: source, atomically: true, encoding: .utf8)
    let lock = UnifiedSetupNativeStarters.destination(.neovim, context: context)
      .appending(path: "lazy-lock.json")
    try "{}\n".write(to: lock, atomically: true, encoding: .utf8)
    let repeated = try await apply.execute(
      context: context, consumerPaths: testConsumerPaths(), json: true)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(
      try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership()?.generationID
        == ownership.generationID)
    #expect(try String(contentsOf: source, encoding: .utf8) == edited)
    #expect(try String(contentsOf: lock, encoding: .utf8) == "{}\n")
    #expect(transcript.withLock { $0 }.contains("Writable native starters"))
    let changedProfile = try PortableProfileLoader().decode(
      "schema_version = 1\n[starship]\nnative_configuration = \"../different.toml\"\n",
      source: context.profileURL)
    #expect(resolver.resolve(.starship, profile: changedProfile).status == .connectionRequired)
    let publicPrompt = context.homeDirectory.appending(path: ".config/starship.toml")
    try FileManager.default.removeItem(at: publicPrompt)
    try FileManager.default.createSymbolicLink(at: publicPrompt, withDestinationURL: source)
    #expect(resolver.resolve(.starship, profile: profile).status == .blocked)
  }

  @Test(arguments: ["approval", "destination"])
  func changedConsentOrDestinationStopsBeforeProviderMutation(change: String) async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = context(fixture)
    let planner = planner(fixture)
    let apply = runner(planner: planner)
    let source = UnifiedSetupNativeStarters.destination(.zsh, context: context)
    let guided = GuidedSetupCommandRunner(
      planner: planner,
      apply: { received, paths, packages, preferences, adoptions in
        var received = received
        if change == "approval" {
          received.nativeStarterApprovals["zsh"] = "stale"
        } else {
          try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: false)
          try "personal replacement\n".write(to: source, atomically: true, encoding: .utf8)
        }
        return try await apply.execute(
          context: received, consumerPaths: paths, packageApproval: packages,
          preferencesApproval: preferences, adoptions: adoptions, json: true)
      }, io: GuidedSetupIO(read: { "yes" }, write: { _ in }))
    let result = try await guided.execute(
      context: context, consumerPaths: testConsumerPaths(), answers: answers())
    #expect(!result.succeeded)
    #expect(try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership() == nil)
    #expect(throws: (any Error).self) {
      try ReconciliationStatusStore(root: context.stateRoot).activeManifest()
    }
    if change == "destination" {
      #expect(try String(contentsOf: source, encoding: .utf8) == "personal replacement\n")
    } else {
      #expect(!FileManager.default.fileExists(atPath: source.deletingLastPathComponent().path))
    }
  }

  private func answers() -> GuidedSetupAnswers {
    var answers = GuidedSetupAnswers()
    answers.desktop = false
    answers.topBar = false
    answers.focusRing = false
    answers.bat = false
    answers.eza = false
    answers.btop = false
    answers.yazi = false
    return answers
  }

  private func context(_ fixture: ApplyFixture) -> UnifiedSetupPlanContext {
    let old = fixture.context
    return UnifiedSetupPlanContext(
      themesRoot: old.themesRoot, keybindingsResourcesRoot: old.keybindingsResourcesRoot,
      desktopResourcesRoot: old.desktopResourcesRoot,
      environmentResourcesRoot: old.themesRoot.deletingLastPathComponent().appending(
        path: "Environment"),
      profileURL: old.profileURL, profileRequired: true, machineProfileURL: old.machineProfileURL,
      machineProfileRequired: false, stateRoot: old.stateRoot, homeDirectory: old.homeDirectory)
  }

  private func planner(_ fixture: ApplyFixture) -> UnifiedSetupPlanCommandRunner {
    UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: { _ in true },
      desktopPlanner: fixture.planner().desktopPlanner,
      environmentPlanner: UnifiedSetupPlanCommandRunner.live.environmentPlanner,
      packageInventoryReader: { .init(packages: [], issues: []) },
      standardBrewfile: { _ in SetupBrewfile(packages: []) })
  }

  private func runner(planner: UnifiedSetupPlanCommandRunner) -> UnifiedSetupApplyCommandRunner {
    UnifiedSetupApplyCommandRunner(
      planner: planner,
      themeInspection: { model, _, _ in
        .init(
          succeeded: true, status: model.theme.status,
          generationID: model.theme.currentGenerationID, message: "fixture")
      },
      packageInstaller: .init(apply: { _, _ in
        Issue.record("Native onboarding fixture must not invoke Homebrew")
        return .init(status: 1, diagnostic: "unexpected")
      }), capabilityIsAvailable: { _ in true }, writePreMutationPlan: { _ in },
      themeApply: { package, state in
        let manifest = try ThemeActivator(root: state).activate(package: package)
        try SetupCoreOwnershipStore(stateRoot: state).write(
          SetupCoreOwnership(themeGenerationID: manifest.generationID, originalAppearance: .light))
        return try component(#"{"outcome":"applied","committed":true}"#)
      },
      desktopApply: { _, _, _, _, _ in
        Issue.record("Disabled desktop must not apply")
        return try component(#"{"outcome":"no_change","mutated":false}"#)
      },
      environmentApply: { context, profile, paths, approvals, adapters in
        try await SetupComponentExecution(
          EnvironmentApplyCommandRunner(
            prerequisites: .assumed, theme: nil, verifier: .assumed,
            neovim: .init { _, _ in
              Issue.record("Native starter must not restore or download plugins")
              return nil
            }
          ).execute(
            resourcesRoot: context.environmentResourcesRoot, profileURL: context.profileURL,
            profileRequired: true, stateRoot: context.stateRoot,
            homeDirectory: context.homeDirectory,
            consumerPaths: paths, adopt: approvals.environment, json: true, deferFinalization: true,
            enabledThemeAdapterIDs: adapters, profile: profile))
      })
  }
}

private func component(_ json: String) throws -> SetupComponentExecution {
  try SetupComponentExecution((output: json, succeeded: true))
}
