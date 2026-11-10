import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SetupThemeTeardownTests {

  @Test(arguments: [false, true])
  func teardownAfterSwitchesAndUndoUsesTheCurrentGeneration(undo: Bool) async throws {
    let fixture = try ApplyFixture()
    let bootstrap = try fixture.activateSetupOwnedTheme()
    defer { removeTemporaryRoot(fixture.root) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let repository = ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes"))
    let activation = ThemeActivationService.reconciling([], onCommittedLocked: { _ in })
    let paths = testConsumerPaths()
    for id in undo ? ["tokyo-night", "kanagawa-wave", "catppuccin-mocha"] : ["tokyo-night"] {
      let set = try await activation.execute(
        repository: repository, themeID: id, stateRoot: fixture.state,
        consumerPaths: paths, dryRun: false, json: true)
      #expect(set.succeeded, "\(set.output)")
    }
    if undo {
      let result = try await ThemeUndoCommandRunner(
        activeManifest: { try ThemeGenerationReader(root: $0).activeManifest() },
        loadHistory: { try ThemeHistoryStore(root: $0).load() }, activation: activation
      ).execute(
        repository: repository, stateRoot: fixture.state, consumerPaths: paths, dryRun: false)
      #expect(result.succeeded, "\(result.output)")
    }
    let active = try ThemeGenerationReader(root: fixture.state).activeManifest()
    #expect(active.generationID != bootstrap.generationID)
    #expect(active.themeID == (undo ? "kanagawa-wave" : "tokyo-night"))
    let appearance = FakeAppearance(.dark)
    // Stale-generation wallpaper is still Macarchy's value after switches and undo.
    let wallpaper = FakeWallpaper(
      showing: fixture.state.appending(
        path: "generations/\(bootstrap.generationID)/generated/wallpaper.png"))
    try WallpaperOriginalStore(root: fixture.state).persist([
      WallpaperOriginal(
        displayUUID: "uuid-1", displayName: "Built-in", imagePath: "/o/original.png",
        presentation: WallpaperPresentation(), recordedAt: "2026-11-08T00:00:00Z")
    ])
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in
        WallpaperOriginalRestorer(
          root: root, control: wallpaper.control, originalExists: { _ in true })
      })
    let preview = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: true)
    #expect(preview.outcome == "planned")
    #expect(preview.plannedThemeGenerationID == active.generationID)
    #expect(appearance.applied().isEmpty)
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.state).read() == ownership)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == active.generationID)
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership,
      expectedGenerationID: preview.plannedThemeGenerationID, dryRun: false)
    #expect(result.succeeded, "\(result.message)")
    #expect(appearance.current() == .light)
    #expect(wallpaper.current().path == "/o/original.png")
    #expect(try ThemeGenerationReader(root: fixture.state).activeManifestIfPresent() == nil)
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.state).read() == nil)
  }

  @Test func comparesAppearanceWithTheActiveThemeNotTheBootstrapOrProfile() async throws {
    let fixture = try ApplyFixture()
    let bootstrap = try fixture.activateSetupOwnedTheme()
    defer { removeTemporaryRoot(fixture.root) }
    let store = SetupCoreOwnershipStore(stateRoot: fixture.state)
    try store.remove()
    let ownership = SetupCoreOwnership(
      themeGenerationID: bootstrap.generationID, originalAppearance: .dark)
    try store.write(ownership)
    let packageURL = fixture.root.appending(path: "light-theme")
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Themes/tokyo-night"), to: packageURL)
    let manifestURL = packageURL.appending(path: "theme.toml")
    try String(contentsOf: manifestURL, encoding: .utf8)
      .replacingOccurrences(of: #"appearance = "dark""#, with: #"appearance = "light""#)
      .write(to: manifestURL, atomically: true, encoding: .utf8)
    _ = try ThemeActivator(root: fixture.state).activate(
      package: ThemePackageLoader().load(packageURL: packageURL))
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: false)
    #expect(result.succeeded)
    #expect(appearance.applied() == [.dark])
    #expect(!result.message.contains("Kept the macOS"))
  }

  @Test func aSwitchBetweenStagePreflightAndRetirementRefusesBeforeNativeWrites() async throws {
    let fixture = try ApplyFixture()
    let bootstrap = try fixture.activateSetupOwnedTheme()
    defer { removeTemporaryRoot(fixture.root) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let replacement = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    let appearance = FakeAppearance(.dark)
    let wallpaper = FakeWallpaper(
      showing: fixture.state.appending(
        path: "generations/\(bootstrap.generationID)/generated/wallpaper.png"))
    let teardown = SetupThemeTeardown(
      appearance: { root in
        SetupAppearanceControl(
          read: {
            _ = try ThemeActivator(root: root).activate(package: replacement)
            return appearance.current()
          }, apply: appearance.control.apply)
      },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: false)
    #expect(!result.succeeded)
    #expect(!result.mutated)
    #expect(result.message.contains("Retry setup teardown"))
    #expect(appearance.applied().isEmpty)
    #expect(wallpaper.current().path.contains(bootstrap.generationID))
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.state).read() == ownership)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().themeID == "tokyo-night")
  }

  @Test func aSwitchAfterAggregatePreviewRefusesBeforeCreatingTheJournal() async throws {
    let fixture = try ApplyFixture()
    _ = try fixture.activateSetupOwnedTheme()
    defer { removeTemporaryRoot(fixture.root) }
    let replacement = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    let appearance = FakeAppearance(.dark)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let stage = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) })
    let runner = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(),
      environmentTeardown: { _, _, _ in environmentReportStub("no_change", mutated: false) },
      desktopTeardown: { _, _, _ in desktopTeardownStub("no_change", message: "desktop") },
      themeTeardown: { state, ownership, expected, dryRun in
        #expect(dryRun)
        let preview = try await stage.run(
          stateRoot: state, ownership: ownership, expectedGenerationID: expected, dryRun: dryRun)
        _ = try ThemeActivator(root: state).activate(package: replacement)
        return preview
      })
    let result = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
    #expect(!result.succeeded)
    let report = try jsonObject(result.output)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect(result.output.contains("Retry setup teardown"))
    #expect(appearance.applied().isEmpty)
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test func aggregatePinsPreflightAndARetryCanFinishAfterAConcurrentSwitch() async throws {
    let fixture = try ApplyFixture()
    _ = try fixture.activateSetupOwnedTheme()
    defer { removeTemporaryRoot(fixture.root) }
    let replacement = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    let appearance = FakeAppearance(.dark)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let stage = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) })
    let runner = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(),
      environmentTeardown: { context, _, dryRun in
        if !dryRun {
          _ = try ThemeActivator(root: context.stateRoot).activate(package: replacement)
        }
        return environmentTeardownStub(dryRun: dryRun, mutated: !dryRun)
      },
      desktopTeardown: { _, _, _ in desktopTeardownStub("no_change", message: "desktop") },
      themeTeardown: { state, ownership, expected, dryRun in
        try await stage.run(
          stateRoot: state, ownership: ownership, expectedGenerationID: expected, dryRun: dryRun)
      })
    let first = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
    #expect(!first.succeeded)
    #expect(first.output.contains("Retry setup teardown"))
    #expect(appearance.applied().isEmpty)
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read()?.stages == [.theme])
    let retry = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
    #expect(retry.succeeded, "\(retry.output)")
    #expect(appearance.current() == .light)
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
    #expect(try ThemeGenerationReader(root: fixture.state).activeManifestIfPresent() == nil)
  }

  @Test(arguments: [false, true])
  func aPreexistingCanonicalThemeIsPreservedWithoutNativeAccess(dryRun: Bool) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    try SetupCoreOwnershipStore(stateRoot: fixture.state).remove()
    let stage = SetupThemeTeardown(
      appearance: { _ in
        Issue.record("A preexisting theme does not authorize appearance access")
        return FakeAppearance(.dark).control
      },
      wallpaper: { root in
        Issue.record("A preexisting theme does not authorize wallpaper access")
        return WallpaperOriginalRestorer(
          root: root, control: FakeWallpaper(showing: URL(filePath: "/user/chosen.png")).control)
      })
    let result = try await stage.run(stateRoot: fixture.state, ownership: nil, dryRun: dryRun)
    #expect(result.succeeded)
    #expect(!result.mutated)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test func accentEvidenceCanBeConsumedWithoutOwningTheCanonicalTheme() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    try SetupCoreOwnershipStore(stateRoot: fixture.state).remove()
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(.init(original: .graphite, applied: .blue))
    let fake = ProcessRunnerFake(replies: [
      .init(arguments: ["check"], output: #"{"ok":true,"value":{"build":"25G83","accent":true}}"#),
      .init(arguments: ["get", "accent"], output: #"{"ok":true,"value":-1}"#),
    ])
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      accent: { root in
        MacOSAccentAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: nil, dryRun: false)
    #expect(result.succeeded)
    #expect(result.message.contains("external theme is preserved"))
    #expect(try store.load() == nil)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test(arguments: [false, true])
  func accentRestorationFailureBlocksRetirementAndKeepsEvidence(dryRun: Bool) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(.init(original: .graphite, applied: .blue))
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      accent: { root in
        MacOSAccentAdapter(
          root: root, helper: MacOSLookHelper(executableURL: root.appending(path: "missing")))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: dryRun)
    #expect(!result.succeeded)
    #expect(result.message.contains("macOS look helper is missing"))
    #expect(try store.load() != nil)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test(arguments: [MacOSAccent.blue, .graphite, .green, .red])
  func accentRestoresBeforeRetirementAndOnlyThenRemovesEvidence(current: MacOSAccent) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let switched = try ThemeActivator(root: fixture.state).activate(
      package: ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/tokyo-night")))

    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(
      .init(original: .graphite, applied: .blue, pending: current == .red ? .red : nil))
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let fake = ProcessRunnerFake(replies: [
      .init(arguments: ["check"], output: #"{"ok":true,"value":{"build":"25G83","accent":true}}"#),
      .init(arguments: ["get", "accent"], output: "{\"ok\":true,\"value\":\(current.rawValue)}"),
      .init(arguments: ["set", "accent", "-1"], output: #"{"ok":true,"value":-1}"#),
    ])
    let runner = ProcessRunner { request in
      #expect(
        try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
          == switched.generationID)
      #expect(try store.load() != nil)
      return try fake.runner.run(request)
    }
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      accent: { root in
        MacOSAccentAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: runner))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: false)
    #expect(result.succeeded, "\(result.message)")
    #expect(try store.load() == nil)
    #expect(
      fake.requests.filter { $0.arguments.first == "set" }.count
        == (current == .blue || current == .red ? 1 : 0))
    if current == .green {
      #expect(result.message.contains("Kept the green accent, which was changed after setup."))
    }
  }

  @Test func iconStyleEvidenceCanBeConsumedWithoutOwningTheCanonicalTheme() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    try SetupCoreOwnershipStore(stateRoot: fixture.state).remove()
    let store = MacOSIconStyleStore(root: fixture.state)
    try store.persist(
      .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
    let fake = ProcessRunnerFake(replies: [
      .init(
        arguments: ["check"],
        output: #"{"ok":true,"value":{"build":"25G83","accent":true,"iconStyle":true}}"#),
      .init(
        arguments: ["get", "icon-style"], output: IconStyleFixtureValues.original.fixtureReply),
    ])
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      iconStyle: { root in
        MacOSIconStyleAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: nil, dryRun: false)
    #expect(result.succeeded)
    #expect(result.message.contains("external theme is preserved"))
    #expect(try store.load() == nil)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test(arguments: [false, true], [false, true])
  func recoveryAfterRetirementPreservesAFreshLifecycle(
    interruptBeforeReceiptCleanup: Bool, activateNewLifecycle: Bool
  ) async throws {
    let fixture = try ApplyFixture()
    let bootstrap = try fixture.activateSetupOwnedTheme()
    defer { removeTemporaryRoot(fixture.root) }
    let appearance = FakeAppearance(.dark)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/original.png"))
    let interrupted = Mutex(false)
    let stage = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      retirementCheckpoint: {
        if interruptBeforeReceiptCleanup,
          interrupted.withLock({
            if $0 { return false }
            $0 = true
            return true
          })
        {
          throw UnifiedSetupInterruptionError.injected
        }
      })
    let runner = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(),
      environmentTeardown: { _, _, _ in environmentReportStub("no_change", mutated: false) },
      desktopTeardown: { _, _, _ in desktopTeardownStub("no_change", message: "desktop") },
      themeTeardown: { state, ownership, expected, dryRun in
        try await stage.run(
          stateRoot: state, ownership: ownership, expectedGenerationID: expected, dryRun: dryRun)
      },
      faultInjector: { checkpoint in
        if !interruptBeforeReceiptCleanup, case .themeTornDown = checkpoint,
          interrupted.withLock({
            if $0 { return false }
            $0 = true
            return true
          })
        {
          throw UnifiedSetupInterruptionError.injected
        }
      })
    if interruptBeforeReceiptCleanup {
      let first = try await runner.execute(
        context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
      #expect(!first.succeeded)
    } else {
      await #expect(throws: UnifiedSetupInterruptionError.self) {
        try await runner.execute(
          context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
      }
    }
    let receipt = try #require(
      try UnifiedSetupTransactionStore(stateRoot: fixture.state).read()?.themeRetirement)
    #expect(receipt.generationID == bootstrap.generationID)
    #expect(receipt.committed)
    #expect(try ThemeGenerationReader(root: fixture.state).activeManifestIfPresent() == nil)

    let fresh: GenerationManifest?
    if activateNewLifecycle {
      fresh = try ThemeActivator(root: fixture.state).activate(
        package: ThemePackageLoader().load(
          packageURL: repositoryRoot.appending(path: "Themes/tokyo-night")))
      _ = try appearance.control.apply(.dark)
      try wallpaper.control.set(URL(filePath: "/new-lifecycle/wallpaper.png"), 1)
      try MacOSAccentStore(root: fixture.state).persist(.init(original: .green, applied: .red))
      try MacOSIconStyleStore(root: fixture.state).persist(
        .init(original: IconStyleFixtureValues.external, applied: IconStyleFixtureValues.applied))
      try WallpaperOriginalStore(root: fixture.state).persist([
        WallpaperOriginal(
          displayUUID: "uuid-1", displayName: "Built-in", imagePath: "/new-lifecycle/original.png",
          presentation: WallpaperPresentation(), recordedAt: "2026-11-10T00:00:00Z")
      ])
    } else {
      fresh = nil
    }
    let accents = try MacOSAccentStore(root: fixture.state).load()
    let icons = try MacOSIconStyleStore(root: fixture.state).load()
    let wallpapers = try WallpaperOriginalStore(root: fixture.state).load()
    let appearanceWrites = appearance.applied()
    let currentWallpaper = wallpaper.current()
    let retry = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
    #expect(retry.succeeded, "\(retry.output)")
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifestIfPresent()?.generationID
        == fresh?.generationID)
    #expect(appearance.applied() == appearanceWrites)
    #expect(wallpaper.current() == currentWallpaper)
    #expect(try MacOSAccentStore(root: fixture.state).load() == accents)
    #expect(try MacOSIconStyleStore(root: fixture.state).load() == icons)
    #expect(try WallpaperOriginalStore(root: fixture.state).load() == wallpapers)
    if activateNewLifecycle {
      #expect(retry.output.contains("Preserved the new canonical lifecycle"))
    }
  }

  @Test(arguments: [false, true])
  func iconStyleRestorationFailureBlocksRetirementAndKeepsEvidence(dryRun: Bool) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let store = MacOSIconStyleStore(root: fixture.state)
    try store.persist(
      .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      iconStyle: { root in
        MacOSIconStyleAdapter(
          root: root, helper: MacOSLookHelper(executableURL: root.appending(path: "missing")))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: dryRun)
    #expect(!result.succeeded)
    #expect(result.message.contains("macOS look helper is missing"))
    #expect(try store.load() != nil)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test(arguments: [
    IconStyleFixtureValues.applied, IconStyleFixtureValues.original,
    IconStyleFixtureValues.external, IconStyleFixtureValues.pending,
  ])
  func iconStyleRestoresBeforeRetirementAndOnlyThenRemovesEvidence(current: MacOSIconStyle)
    async throws
  {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let switched = try ThemeActivator(root: fixture.state).activate(
      package: ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/tokyo-night")))

    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let store = MacOSIconStyleStore(root: fixture.state)
    try store.persist(
      .init(
        original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied,
        pending: current == IconStyleFixtureValues.pending ? IconStyleFixtureValues.pending : nil))
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let fake = ProcessRunnerFake(replies: [
      .init(
        arguments: ["check"],
        output: #"{"ok":true,"value":{"build":"25G83","accent":true,"iconStyle":true}}"#),
      .init(arguments: ["get", "icon-style"], output: current.fixtureReply),
      .init(
        arguments: ["set", "icon-style", "RegularLight", "None"],
        output: IconStyleFixtureValues.original.fixtureReply),
    ])
    let runner = ProcessRunner { request in
      #expect(
        try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
          == switched.generationID)
      #expect(try store.load() != nil)
      return try fake.runner.run(request)
    }
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      iconStyle: { root in
        MacOSIconStyleAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: runner))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: false)
    #expect(result.succeeded, "\(result.message)")
    #expect(try store.load() == nil)
    #expect(
      fake.requests.filter { $0.arguments.first == "set" }.count
        == (current == IconStyleFixtureValues.applied || current == IconStyleFixtureValues.pending
          ? 1 : 0))
    if current == IconStyleFixtureValues.external {
      #expect(
        result.message.contains(
          "Kept the ClearLight / Green / no custom tint icon style, which was changed after setup.")
      )
    }
  }

  @Test(arguments: [false, true])
  func aLaterIconFailureKeepsBothReceiptsAndReportsTheCompletedAccentRestore(owned: Bool)
    async throws
  {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try SetupCoreOwnershipStore(stateRoot: fixture.state).read()
    let accents = MacOSAccentStore(root: fixture.state)
    let icons = MacOSIconStyleStore(root: fixture.state)
    try accents.persist(.init(original: .graphite, applied: .blue))
    try icons.persist(
      .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
    let fake = ProcessRunnerFake(replies: [
      .init(arguments: ["check"], output: #"{"ok":true,"value":{"build":"25G83","accent":true}}"#),
      .init(arguments: ["get", "accent"], output: #"{"ok":true,"value":4}"#),
      .init(arguments: ["set", "accent", "-1"], output: #"{"ok":true,"value":-1}"#),
    ])
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      iconStyle: { root in
        MacOSIconStyleAdapter(
          root: root, helper: MacOSLookHelper(executableURL: root.appending(path: "missing")))
      },
      accent: { root in
        MacOSAccentAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state,
      ownership: owned ? ownership : nil, dryRun: false)
    #expect(!result.succeeded)
    #expect(result.mutated)
    #expect(result.message.contains("macOS look helper is missing"))
    #expect(try accents.load() != nil)
    #expect(try icons.load() != nil)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test(arguments: [false, true])
  func scriptsReceiveTeardownBeforeRetirementAndFailuresDoNotBlock(journaled: Bool) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let directory = try makeTrustedScriptDirectory()
    defer { removeTemporaryRoot(directory) }
    let script = directory.appending(path: "record")
    let recorded = directory.appending(path: "events")
    try
      "#!/bin/sh\ntest -f \"$MACARCHY_THEME_FILE\" || exit 9\necho $MACARCHY_EVENT >> \"$(dirname \"$0\")/events\"\n"
      .write(to: script, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let shared = directory.appending(path: "shared")
    try "#!/bin/sh\nexit 0\n".write(to: shared, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: shared.path)
    let scripts = [script.path, shared.path]
    if journaled {
      try UnifiedSetupTransactionStore(stateRoot: fixture.state).write(
        UnifiedSetupTransaction(
          operation: .teardown, stages: [.theme], desiredAppearance: .dark,
          contextDigest: "sha256:" + String(repeating: "a", count: 64), userScripts: scripts))
    } else {
      try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(
        EnvironmentOwnership(
          generationID: "e-00000000-0000-0000-0000-000000000000", records: [],
          createdDirectories: [], originalThemeBridges: [], userScripts: scripts,
          enabledThemeAdapterIDs: [UserScriptsAdapter.id]))
    }
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) })
    let preview = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership,
      dryRun: true)
    #expect(preview.message.contains("Would run 2 user scripts"))
    #expect(!FileManager.default.fileExists(atPath: recorded.path))
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership,
      dryRun: false)
    #expect(result.succeeded)
    #expect(result.message.contains("record succeeded"))
    #expect(result.message.contains("shared refused"))
    #expect(try String(contentsOf: recorded, encoding: .utf8) == "teardown\n")
  }

  @Test func restoresTheOriginalAppearanceAndWallpaperBeforeRemovingTheTheme() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let appearance = FakeAppearance(.dark)
    let wallpaper = FakeWallpaper(
      showing: fixture.state.appending(
        path: "generations/\(manifest.generationID)/generated/wallpaper.png"))
    try WallpaperOriginalStore(root: fixture.state).persist([
      WallpaperOriginal(
        displayUUID: "uuid-1", displayName: "Built-in", imagePath: "/o/original.png",
        presentation: WallpaperPresentation(), recordedAt: "2026-11-08T00:00:00Z")
    ])
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in
        WallpaperOriginalRestorer(
          root: root, control: wallpaper.control, originalExists: { _ in true })
      }
    )

    let plan = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: true)
    #expect(plan.outcome == "planned")
    #expect(
      plan.message
        == "Would restore macOS appearance and remove the setup-owned canonical theme. "
        + "Would restore the original wallpaper on 'Built-in'.")
    #expect(appearance.current() == .dark)
    #expect(wallpaper.current().path.hasSuffix("generated/wallpaper.png"))

    let stage = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: false)

    #expect(stage.succeeded)
    #expect(stage.outcome == "restored")
    #expect(
      stage.message
        == "Restored macOS appearance and removed the setup-owned canonical theme. "
        + "Restored the original wallpaper on 'Built-in'.")
    #expect(appearance.current() == .light)
    #expect(wallpaper.current() == URL(filePath: "/o/original.png"))
    #expect(try WallpaperOriginalStore(root: fixture.state).load() == [])
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(throws: (any Error).self) {
      try ThemeGenerationReader(root: fixture.state).activeManifest()
    }
  }

  @Test func keepsAndReportsValuesTheUserChangedAfterSetup() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    _ = try ThemeActivator(root: fixture.state).activate(
      package: ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/tokyo-night")))

    // Setup found Dark and kept it; the user switched to Light afterwards.
    let store = SetupCoreOwnershipStore(stateRoot: fixture.state)
    try store.remove()
    let ownership = SetupCoreOwnership(
      themeGenerationID: manifest.generationID, originalAppearance: .dark)
    try store.write(ownership)
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    try WallpaperOriginalStore(root: fixture.state).persist([
      WallpaperOriginal(
        displayUUID: "uuid-1", displayName: "Built-in", imagePath: "/o/original.png",
        presentation: WallpaperPresentation(), recordedAt: "2026-11-08T00:00:00Z")
    ])
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in
        WallpaperOriginalRestorer(
          root: root, control: wallpaper.control, originalExists: { _ in true })
      }
    )

    let stage = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: false)

    #expect(stage.succeeded)
    #expect(stage.outcome == "restored")
    #expect(
      stage.message
        == "Removed the setup-owned canonical theme. "
        + "Kept the macOS light appearance, which was changed after setup. "
        + "Kept the wallpaper on 'Built-in', which was changed after Macarchy set it.")
    #expect(appearance.current() == .light)
    #expect(appearance.applied() == [])
    #expect(wallpaper.current() == URL(filePath: "/user/chosen.png"))
    #expect(try store.read() == nil)
  }

  @Test func leavesAnAppearanceThatIsAlreadyTheOriginalSilently() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) }
    )

    let stage = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, dryRun: false)

    #expect(stage.succeeded)
    #expect(stage.message == "Removed the setup-owned canonical theme.")
    #expect(appearance.applied() == [])
  }
}

private final class FakeAppearance: Sendable {
  private let state: Mutex<ThemeAppearance>
  private let requests = Mutex<[ThemeAppearance]>([])

  init(_ appearance: ThemeAppearance) {
    state = Mutex(appearance)
  }

  var control: SetupAppearanceControl {
    SetupAppearanceControl(
      read: { self.current() },
      apply: { appearance in
        self.requests.withLock { $0.append(appearance) }
        self.state.withLock { $0 = appearance }
        return AdapterResult(
          adapterID: MacOSAppearanceAdapter.id, requirement: .required, status: .applied)
      }
    )
  }

  func current() -> ThemeAppearance { state.withLock { $0 } }
  func applied() -> [ThemeAppearance] { requests.withLock { $0 } }
}

private final class FakeWallpaper: Sendable {
  private let wallpaper: Mutex<URL>

  init(showing url: URL) {
    wallpaper = Mutex(url)
  }

  var control: WallpaperControl {
    WallpaperControl(
      inspect: {
        [WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: self.current())]
      },
      set: { url, _ in self.wallpaper.withLock { $0 = url } },
      displayUUID: { "uuid-\($0)" }
    )
  }

  func current() -> URL { wallpaper.withLock { $0 } }
}
