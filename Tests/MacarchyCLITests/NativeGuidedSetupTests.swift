import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct NativeGuidedSetupTests {
  @Test func fullResumeReviewIncludesNativeStartersAndReplacementInventory() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = context(fixture)
    var intent = answers()
    intent.terminal = false
    intent.prompt = false
    intent.history = false
    intent.editor = false
    let source = EnvironmentNativeSeed.Provider.zsh.standardURL(
      homeDirectory: context.homeDirectory)
    let original = "export PERSONAL_ORIGINAL=1\n"
    try original.write(to: source, atomically: true, encoding: .utf8)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let path = try encoder.encode(
      UnifiedSetupNativeStarters.profilePath(.zsh, context: context))
    _ = try GuidedSetupProfileWriter.write(
      answers: intent,
      nativeSources: "[zsh]\nconfiguration = " + String(decoding: path, as: UTF8.self),
      to: context.profileURL)
    let options = try Macarchy.Setup.Guided.parse(["--resume", "--full"])
    let transcript = Mutex("")
    var guided = GuidedSetupCommandRunner(
      packageTrust: .testAlreadyTrusted, planner: planner(fixture),
      apply: { _, _, _, _, _, _ in
        Issue.record("Inventory review must not apply after cancellation")
        return ("unexpected", false)
      },
      io: .init(read: { "no" }, write: { text in transcript.withLock { $0 += text } }))
    guided.fullReview = options.full
    guided.selectReplacements = { Set($0.map { $0.provider.rawValue }) }
    let result = try await guided.execute(
      context: context, consumerPaths: testConsumerPaths(), resume: options.resume)
    let text = transcript.withLock { $0 }
    #expect(result.succeeded, "Declining a reviewed apply is a successful no-op")
    #expect(result.output.contains("stopped before installation or configuration mutation"))
    #expect(text.contains("Writable native starters"))
    #expect(text.contains("- zsh: " + source.path))
    #expect(text.contains("- Back up and replace:"))
    #expect(text.contains("# User-owned configuration."))
    #expect(text.contains("Core capabilities:"))
    #expect(try String(contentsOf: source, encoding: .utf8) == original)
    #expect(
      try SetupNativeReplacement(
        homeDirectory: context.homeDirectory, stateRoot: context.stateRoot
      ).read().records.isEmpty)
  }

  @Test
  func retainedLegacyGuidedProfileResumesWithoutRelocatingSources() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = context(fixture)
    let planner = planner(fixture)
    let apply = runner(planner: planner)
    let guided = GuidedSetupCommandRunner(
      packageTrust: .testAlreadyTrusted,
      planner: planner,
      apply: { context, paths, packages, preferences, adoptions, reviewedPlan in
        try await apply.execute(
          context: context, consumerPaths: paths, packageApproval: packages,
          preferencesApproval: preferences, adoptions: adoptions, reviewedPlan: reviewedPlan,
          json: true)
      },
      io: GuidedSetupIO(read: { "yes" }, write: { _ in }))
    let retained = """
      schema_version = 1
      [desktop]
      provider = "disabled"
      [top_bar]
      provider = "disabled"
      [focus_ring]
      provider = "disabled"
      [tools]
      bat = false
      eza = false
      btop = false
      yazi = false
      [zsh]
      configuration = "../macarchy-user/zshrc"
      [kitty]
      configuration = "../macarchy-user/kitty.conf"
      [atuin]
      native_configuration = "../macarchy-user/atuin.toml"
      [starship]
      native_configuration = "../macarchy-user/starship.toml"
      [neovim]
      native_configuration = "../macarchy-user/neovim"
      """
    try retained.write(to: context.profileURL, atomically: true, encoding: .utf8)
    let result = try await guided.execute(
      context: context, consumerPaths: testConsumerPaths(), resume: true)
    #expect(result.succeeded, "\(result.output)")
    #expect(try String(contentsOf: context.profileURL, encoding: .utf8) == retained)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership())
    #expect(ownership.standardNativeEntries == nil)
    for (id, name) in [
      (EnvironmentEntryID.zsh, "zshrc"), (.kitty, "kitty.conf"),
      (.atuinConfiguration, "atuin.toml"), (.starship, "starship.toml"), (.neovim, "neovim"),
    ] {
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.home.appending(path: ".config/macarchy-user/\(name)").path))
      #expect(ownership.records.contains { $0.id == id })
    }
  }

  @Test
  func cancelResumeCreateConnectEditAndReapply() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = context(fixture)
    let planner = planner(fixture)
    let preparations = Mutex(0)
    let apply = runner(
      planner: planner,
      neovim: EnvironmentNeovimPreparer { _, _ in
        preparations.withLock { $0 += 1 }
        return EnvironmentVerification(id: "neovim_plugins", status: "verified", message: "fixture")
      })
    let transcript = Mutex("")
    let responses = Mutex(["no", "yes"])
    let guided = GuidedSetupCommandRunner(
      packageTrust: .testAlreadyTrusted,
      planner: planner,
      apply: { context, paths, packages, preferences, adoptions, reviewedPlan in
        try await apply.execute(
          context: context, consumerPaths: paths, packageApproval: packages,
          preferencesApproval: preferences, adoptions: adoptions, reviewedPlan: reviewedPlan,
          json: true)
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
      let source = provider.standardURL(homeDirectory: context.homeDirectory)
      #expect(!FileManager.default.fileExists(atPath: source.path))
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: EnvironmentNativeSeed.Provider.kitty.standardURL(
          homeDirectory: context.homeDirectory
        )
        .deletingLastPathComponent().path))
    #expect(try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership() == nil)
    #expect(preparations.withLock { $0 } == 0)
    #expect(transcript.withLock { $0 }.contains("prepare_fresh_neovim_plugins"))
    let applied = try await guided.execute(
      context: context, consumerPaths: testConsumerPaths(), resume: true)
    #expect(applied.succeeded, "\(applied.output)\n\(transcript.withLock { $0 })")
    #expect(preparations.withLock { $0 } == 1)
    #expect(responses.withLock { $0.isEmpty })
    #expect(try Data(contentsOf: context.profileURL) == profileBytes)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership())
    let profile = try PortableProfileLoader().load(at: context.profileURL, required: true)
    let resolver = EnvironmentConfigurationSourceResolver(
      homeDirectory: context.homeDirectory, stateRoot: context.stateRoot)
    for provider in EnvironmentNativeSeed.Provider.allCases {
      let source = provider.standardURL(homeDirectory: context.homeDirectory)
      #expect(provider.source(in: profile.environment)?.path == source.path)
      #expect(FileManager.default.fileExists(atPath: source.path))
      let selected = resolver.resolve(provider, profile: profile)
      #expect(selected.status == .editable, "\(selected.message)")
      #expect(selected.source == source.path)
      #expect(ownership.records.first { $0.id == provider.entryID } == nil)
      #expect(ownership.standardNativeEntries?.contains(provider.entryID) == true)
      let receiptSelected = resolver.resolve(provider, profile: .defaults)
      #expect(receiptSelected.status == .editable, "\(receiptSelected.message)")
      #expect(receiptSelected.authority == "native_ownership")
      #expect(receiptSelected.source == source.path)
    }
    let source = EnvironmentNativeSeed.Provider.zsh.standardURL(
      homeDirectory: context.homeDirectory)
    let edited = try String(contentsOf: source, encoding: .utf8) + "export PERSONAL=edited\n"
    try edited.write(to: source, atomically: true, encoding: .utf8)
    let lock = EnvironmentNativeSeed.Provider.neovim.standardURL(
      homeDirectory: context.homeDirectory
    )
    .appending(path: "lazy-lock.json")
    try "{}\n".write(to: lock, atomically: true, encoding: .utf8)
    let repeated = try await apply.execute(
      context: context, consumerPaths: testConsumerPaths(), json: true)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(preparations.withLock { $0 } == 1)
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
    let source = EnvironmentNativeSeed.Provider.zsh.standardURL(
      homeDirectory: context.homeDirectory)
    let guided = GuidedSetupCommandRunner(
      packageTrust: .testAlreadyTrusted,
      planner: planner,
      apply: { received, paths, packages, preferences, adoptions, reviewedPlan in
        var received = received
        if change == "approval" {
          received.nativeStarterApprovals["zsh"] = "stale"
        } else {
          try "personal replacement\n".write(to: source, atomically: true, encoding: .utf8)
        }
        return try await apply.execute(
          context: received, consumerPaths: paths, packageApproval: packages,
          preferencesApproval: preferences, adoptions: adoptions, reviewedPlan: reviewedPlan,
          json: true)
      }, io: GuidedSetupIO(read: { "yes" }, write: { _ in }))
    let result = try await guided.execute(
      context: context, consumerPaths: testConsumerPaths(), answers: answers())
    #expect(!result.succeeded)
    #expect(try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership() == nil)
    #expect(throws: (any Error).self) {
      try ThemeGenerationReader(root: context.stateRoot).activeManifest()
    }
    if change == "destination" {
      #expect(try String(contentsOf: source, encoding: .utf8) == "personal replacement\n")
    } else {
      #expect(!FileManager.default.fileExists(atPath: source.path))
    }
  }

  @Test(arguments: ["cancel", "keep", "apply"])
  func existingConfigsCrossGuidedConsentReapplyAndUnifiedTeardown(choice: String) async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let context = context(fixture)
    let planner = planner(fixture)
    let apply = runner(
      planner: planner,
      neovim: .init { _, _ in
        .init(id: "neovim_plugins", status: "verified", message: "fixture")
      })
    let shell = context.homeDirectory.appending(path: ".zshrc")
    let kitty = context.homeDirectory.appending(path: ".config/kitty/kitty.conf")
    let target = fixture.root.appending(path: "personal-kitty.conf")
    try FileManager.default.createDirectory(
      at: kitty.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = "export PERSONAL_ORIGINAL=1\n"
    try original.write(to: shell, atomically: true, encoding: .utf8)
    try "font_size 17\n".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: kitty.path, withDestinationPath: target.path)
    let transcript = Mutex("")
    let calls = Mutex(0)
    var guided = GuidedSetupCommandRunner(
      packageTrust: .testAlreadyTrusted, planner: planner,
      apply: { received, paths, packages, preferences, adoptions, reviewedPlan in
        calls.withLock { $0 += 1 }
        return try await apply.execute(
          context: received, consumerPaths: paths,
          packageApproval: packages, preferencesApproval: preferences, adoptions: adoptions,
          reviewedPlan: reviewedPlan, json: true)
      },
      io: .init(
        read: { choice == "cancel" ? "no" : "yes" },
        write: { text in transcript.withLock { $0 += text } }))
    guided.selectReplacements = { proposals in
      #expect(Set(proposals.map { $0.provider.rawValue }) == ["zsh", "kitty"])
      return choice == "keep" ? [] : Set(proposals.map { $0.provider.rawValue })
    }
    let result = try await guided.execute(
      context: context, consumerPaths: testConsumerPaths(), answers: answers())
    let store = SetupNativeReplacement(
      homeDirectory: context.homeDirectory, stateRoot: context.stateRoot)
    if choice != "apply" {
      #expect(calls.withLock { $0 } == 0)
      #expect(try store.read().records.isEmpty)
      #expect(try String(contentsOf: shell, encoding: .utf8) == original)
      #expect(try FileManager.default.destinationOfSymbolicLink(atPath: kitty.path) == target.path)
      if choice == "keep" { #expect(transcript.withLock { $0 }.contains("connect/migrate")) }
      return
    }
    #expect(result.succeeded, "\(result.output)\n\(transcript.withLock { $0 })")
    let records = try store.read().records
    #expect(records.count == 2)
    #expect(transcript.withLock { $0 }.contains("Back up and replace"))
    let edited = try String(contentsOf: shell, encoding: .utf8) + "export PERSONAL_EDIT=1\n"
    try edited.write(to: shell, atomically: true, encoding: .utf8)
    let repeated = try await apply.execute(
      context: context, consumerPaths: testConsumerPaths(), json: true)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(try store.read().records == records)
    #expect(try String(contentsOf: shell, encoding: .utf8) == edited)
    // Removing an apply-only theme seam is a personal edit, not permission to
    // block restoring the original or to discard these edited starter bytes.
    let editedKitty = "font_size 31\n# personal starter edits, no managed include\n"
    try editedKitty.write(to: kitty, atomically: true, encoding: .utf8)
    #expect(!(try planner.prepare(context: context)).succeeded)
    let teardownPlan = try planner.prepare(context: context, purpose: .teardown)
    let teardownText = try teardownPlan.report.render(json: false)
    #expect(teardownPlan.succeeded, "\(teardownText)")
    for seed in try UnifiedSetupNativeStarters.prepare(
      context: context,
      profile: context.loadProfile().profile,
      theme: ThemePackageLoader().load(
        packageURL: context.themesRoot.appending(path: "catppuccin-mocha")),
      forTeardown: true)
    {
      #expect(throws: (any Error).self) { try seed.seed(approval: seed.plan().approval) }
    }
    let teardown = UnifiedSetupTeardownCommandRunner(
      planner: planner,
      environmentTeardown: { context, paths, dryRun in
        try await EnvironmentTeardownCommandRunner().report(
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory, consumerPaths: paths, dryRun: dryRun,
          withinUnifiedSetup: true)
      }, desktopTeardown: { _, _, dryRun in desktopTeardownStub(dryRun: dryRun, mutated: false) },
      themeTeardown: { _, _, _, dryRun in
        .init(
          succeeded: true, mutated: !dryRun, outcome: dryRun ? "planned" : "restored",
          message: "fixture", details: nil)
      })
    let restored = try await teardown.execute(
      context: context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
    #expect(restored.succeeded, "\(restored.output)")
    #expect(try String(contentsOf: shell, encoding: .utf8) == original)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: kitty.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8) == "font_size 17\n")
    let shellRecord = try #require(try store.read().records.first { $0.proposal.provider == .zsh })
    #expect(
      try String(contentsOfFile: #require(shellRecord.displacedStarter), encoding: .utf8) == edited)
    #expect(try String(contentsOfFile: shellRecord.proposal.backup, encoding: .utf8) == original)
    #expect(restored.output.contains(shellRecord.proposal.backup))
    let kittyRecord = try #require(
      try store.read().records.first { $0.proposal.provider == .kitty })
    #expect(
      try String(contentsOfFile: #require(kittyRecord.displacedStarter), encoding: .utf8)
        == editedKitty)
    // The declared standard source is now the original, without our theme seam.
    #expect(try planner.prepare(context: context, purpose: .teardown).succeeded)
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

  private func runner(
    planner: UnifiedSetupPlanCommandRunner,
    neovim: EnvironmentNeovimPreparer = .init { _, _ in
      Issue.record("This native connection must not prepare plugins")
      return nil
    }
  ) -> UnifiedSetupApplyCommandRunner {
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
        return themeReportStub()
      },
      desktopApply: { _, _, _, _, _ in
        Issue.record("Disabled desktop must not apply")
        return desktopApplyStub("no_change", mutated: false)
      },
      environmentApply: { context, profile, paths, approvals, adapters in
        try await EnvironmentApplyCommandRunner(
          prerequisites: .assumed, theme: nil, verifier: .assumed,
          neovim: neovim
        ).report(
          resourcesRoot: context.environmentResourcesRoot, profileURL: context.profileURL,
          profileRequired: true, stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          consumerPaths: paths, adopt: approvals.environment, deferFinalization: true,
          withinUnifiedSetup: true, enabledThemeAdapterIDs: adapters, profile: profile)
      })
  }
}
