import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct DesktopApplyCommandTests {
  @Test(arguments: [0, 1, 2])
  func personalYabaiReviewsConnectionAndActivatesOnlyOnExit(approvals: Int) throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let physicalProfile = fixture.root.appending(path: "dotfiles.toml")
    try FileManager.default.moveItem(at: fixture.profile, to: physicalProfile)
    try FileManager.default.createSymbolicLink(
      at: fixture.profile, withDestinationURL: physicalProfile)
    let lifecycle = YabaiLifecycleFixture(running: true)
    let bar = SketchyBarPublicLifecycleFixture()
    let runner = DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      sketchyBarLifecycle: bar.controller, keybindings: nil, prerequisites: .assumed, theme: nil)
    #expect(
      try runner.execute(
        resourcesRoot: fixture.resources, profileURL: fixture.profile,
        profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
        adopt: nil, json: true, scope: .yabaiOnly
      ).succeeded)
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    let generation = YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID
    lifecycle.calls.withLock { $0 = [] }
    let answers = Mutex(Array(repeating: "y", count: approvals) + ["n"])
    let context = Self.personalContext(
      root: fixture.root, home: fixture.home, state: fixture.state,
      profile: fixture.profile, resources: fixture.resources)
    let setup = MenuDesktopConfiguration(
      provider: .yabai, context: context,
      io: GuidedSetupIO(read: { answers.withLock { $0.removeFirst() } }, write: { _ in }))
    let session = try setup.prepareForEditing()
    let source = fixture.root.appending(path: "overrides/yabai.sh")
    #expect(FileManager.default.fileExists(atPath: source.path) == (approvals > 0))
    #expect(lifecycle.calls.withLock { $0.isEmpty })
    #expect(bar.calls.withLock { $0.isEmpty })
    #expect(YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID == generation)
    if approvals < 2 {
      #expect(session == nil)
      #expect(try String(contentsOf: fixture.profile, encoding: .utf8) == original)
      return
    }
    let selected = try #require(session)
    #expect(selected.target == source)
    try "\"$YABAI\" -m config window_gap 123\n".write(to: source, atomically: true, encoding: .utf8)
    #expect(try selected.finish(runner: runner)?.changed == true)
    #expect(lifecycle.calls.withLock { $0.filter { $0 == "restart" }.count } == 1)
    #expect(bar.calls.withLock { $0.isEmpty })
    let reopened = try #require(try setup.prepareForEditing())
    lifecycle.calls.withLock { $0 = [] }
    #expect(try reopened.finish(runner: runner) == nil)
    try "if then\n".write(to: source, atomically: true, encoding: .utf8)
    let active = YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID
    #expect(throws: (any Error).self) { try reopened.finish(runner: runner) }
    #expect(lifecycle.calls.withLock { $0.isEmpty })
    #expect(YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID == active)
    #expect(try String(contentsOf: source, encoding: .utf8) == "if then\n")
    let repair = try #require(try setup.prepareForEditing())
    try "\"$YABAI\" -m config layout stack\n".write(to: source, atomically: true, encoding: .utf8)
    #expect(try repair.finish(runner: runner)?.changed == true)
    #expect(bar.calls.withLock { $0.isEmpty })
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.profile.path)
        == physicalProfile.path)
    // Drift predating the editor must not ride along with a personal-file save.
    try "schema_version = 1\n[yabai]\nwindow_gap = 99\n".write(
      to: context.machineProfileURL, atomically: true, encoding: .utf8)
    let drifted = try #require(try setup.prepareForEditing())
    try "# another personal edit\n".write(to: source, atomically: true, encoding: .utf8)
    lifecycle.calls.withLock { $0 = [] }
    #expect(throws: (any Error).self) { try drifted.finish(runner: runner) }
    #expect(lifecycle.calls.withLock { $0.isEmpty })
  }

  @Test(arguments: ["contents", "link"])
  func changedLegacyHookCannotBeRetiredByStaleConsent(change: String) throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let hook = fixture.state.appending(path: "hook.sh")
    let physical = fixture.state.appending(path: "original.sh")
    let replacement = fixture.state.appending(path: "replacement.sh")
    for file in [physical, replacement] {
      try "# original hook\n".write(to: file, atomically: true, encoding: .utf8)
    }
    try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: physical)
    let profile =
      "schema_version = 1\n[yabai]\nhook = \"hook.sh\"\n[top_bar]\nprovider = \"disabled\"\n"
    try profile.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let lifecycle = YabaiLifecycleFixture(running: true)
    let runner = DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil, prerequisites: .assumed, theme: nil)
    #expect(
      try runner.execute(
        resourcesRoot: fixture.resources, profileURL: fixture.profile,
        profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
        adopt: nil, json: true, scope: .yabaiOnly
      ).succeeded)
    let generation = YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID
    lifecycle.calls.withLock { $0 = [] }
    let confirmations = Mutex(0)
    let context = Self.personalContext(
      root: fixture.root, home: fixture.home, state: fixture.state,
      profile: fixture.profile, resources: fixture.resources)
    let setup = MenuDesktopConfiguration(
      provider: .yabai, context: context,
      io: GuidedSetupIO(
        read: {
          let count = confirmations.withLock {
            $0 += 1
            return $0
          }
          if count == 2 {
            do {
              if change == "contents" {
                try "# newly edited hook\n".write(to: physical, atomically: true, encoding: .utf8)
              } else {
                try FileManager.default.removeItem(at: hook)
                try FileManager.default.createSymbolicLink(
                  at: hook, withDestinationURL: replacement)
              }
            } catch { Issue.record("Fixture mutation failed: \(error)") }
          }
          return "y"
        }, write: { _ in }))
    #expect(throws: (any Error).self) { try setup.prepareForEditing() }
    #expect(try String(contentsOf: fixture.profile, encoding: .utf8) == profile)
    #expect(
      try String(contentsOf: fixture.state.appending(path: "overrides/yabai.sh"), encoding: .utf8)
        .contains("# original hook"))
    #expect(YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID == generation)
    #expect(lifecycle.calls.withLock { $0.isEmpty })
  }

  @Test(arguments: ["profile", "source", "generation"])
  func personalYabaiSessionRejectsStaleInputs(change: String) throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = YabaiLifecycleFixture(running: true)
    let runner = DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil, prerequisites: .assumed, theme: nil)
    #expect(
      try runner.execute(
        resourcesRoot: fixture.resources, profileURL: fixture.profile,
        profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
        adopt: nil, json: true, scope: .yabaiOnly
      ).succeeded)
    let context = Self.personalContext(
      root: fixture.root, home: fixture.home, state: fixture.state,
      profile: fixture.profile, resources: fixture.resources)
    let session = try #require(
      try MenuDesktopConfiguration(
        provider: .yabai, context: context,
        io: GuidedSetupIO(read: { "y" }, write: { _ in })
      ).prepareForEditing())
    try "# saved change\n".write(to: session.target, atomically: true, encoding: .utf8)
    switch change {
    case "profile":
      try "schema_version = 1\n[yabai]\nwindow_gap = 17\n".write(
        to: context.machineProfileURL, atomically: true, encoding: .utf8)
    case "source":
      let replacement = fixture.state.appending(path: "replacement.sh")
      try "# other\n".write(to: replacement, atomically: true, encoding: .utf8)
      try FileManager.default.removeItem(at: session.target)
      try FileManager.default.createSymbolicLink(
        at: session.target, withDestinationURL: replacement)
    default:
      _ = try runner.execute(
        resourcesRoot: fixture.resources, profileURL: fixture.profile,
        profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
        adopt: nil, json: true, scope: .yabaiOnly)
    }
    lifecycle.calls.withLock { $0 = [] }
    #expect(throws: (any Error).self) { try session.finish(runner: runner) }
    #expect(lifecycle.calls.withLock { $0.isEmpty })
  }

  @Test(arguments: [false, true])
  func personalBarUsesOnlyReloadAndRetainsSavedIntentOnRuntimeFailure(fails: Bool) throws {
    let fixture = try SketchyBarPublicCommandFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let yabai = YabaiLifecycleFixture(running: false)
    let nativeEvidence = SketchyBarCoreRuntimeInspection(
      status: .partial,
      message: "native integration verified", themeGenerationID: fixture.core.themeGenerationID,
      barColor: fixture.core.barColor, items: ["macarchy.theme.ready", "personal.clock"],
      nativeConfiguration: true)
    let inspect: @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection = {
      composition in
      if !composition.nativeConfiguration { return fixture.core }
      return fails ? .init(status: .drifted, message: "personal script failed") : nativeEvidence
    }
    let runner = DesktopApplyCommandRunner(
      lifecycle: yabai.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: .init(
        inspect: inspect, settle: inspect, settleRestored: { _ in true }),
      keybindings: nil, prerequisites: .assumed, theme: nil)
    #expect(
      try runner.execute(
        resourcesRoot: fixture.resources, profileURL: fixture.profile,
        profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
        adopt: nil, json: true
      ).succeeded)
    let generation = SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().generationID
    let context = Self.personalContext(
      root: fixture.root, home: fixture.home, state: fixture.state,
      profile: fixture.profile, resources: fixture.resources)
    let session = try #require(
      try MenuDesktopConfiguration(
        provider: .sketchybar, context: context,
        io: GuidedSetupIO(read: { "y" }, write: { _ in })
      ).prepareForEditing())
    let personal = "\"$SKETCHYBAR\" --remove macarchy.clock --add item personal.clock left\n"
    try personal.write(to: session.target, atomically: true, encoding: .utf8)
    fixture.lifecycle.calls.withLock { $0 = [] }
    yabai.calls.withLock { $0 = [] }
    if fails {
      #expect(throws: (any Error).self) { try session.finish(runner: runner) }
      #expect(
        SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().generationID == generation
      )
    } else {
      #expect(try session.finish(runner: runner)?.changed == true)
      #expect(
        SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().generationID != generation
      )
    }
    #expect(try String(contentsOf: session.target, encoding: .utf8) == personal)
    #expect(
      try MenuNativeProfileEdit.load(context).profile.sketchyBar.configurationURL == session.source)
    #expect(yabai.calls.withLock { $0.isEmpty })
    let calls = fixture.lifecycle.calls.withLock { $0 }
    #expect(calls.contains("reload"))
    #expect(!calls.contains("start") && !calls.contains("stop"))
    if !fails {
      try "schema_version = 1\n[sketchybar]\nleft = []\n".write(
        to: context.machineProfileURL, atomically: true, encoding: .utf8)
      let drifted = try #require(
        try MenuDesktopConfiguration(provider: .sketchybar, context: context)
          .prepareForEditing())
      try (personal + "# changed\n").write(to: session.target, atomically: true, encoding: .utf8)
      fixture.lifecycle.calls.withLock { $0 = [] }
      #expect(throws: (any Error).self) { try drifted.finish(runner: runner) }
      #expect(fixture.lifecycle.calls.withLock { $0.isEmpty })
    }
  }

  private static func personalContext(
    root: URL, home: URL, state: URL, profile: URL,
    resources: URL
  ) -> UnifiedSetupPlanContext {
    UnifiedSetupPlanContext(
      themesRoot: root, keybindingsResourcesRoot: root,
      desktopResourcesRoot: resources, environmentResourcesRoot: root,
      profileURL: profile, profileRequired: true,
      machineProfileURL: state.appending(path: "machine.toml"), machineProfileRequired: false,
      stateRoot: state, homeDirectory: home)
  }

  @Test(arguments: [false, true])
  func yabaiOnlyUpgradePreservesOtherProvidersAndRollsBackFailure(failsVerification: Bool) throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    // A selected but unavailable bar hook must not even be composed in this scope.
    try """
    schema_version = 1
    [sketchybar]
    hook = "not-loaded-by-yabai-only.sh"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let barRoot = fixture.state.appending(path: "desktop/sketchybar")
    try FileManager.default.createDirectory(at: barRoot, withIntermediateDirectories: true)
    let barState = barRoot.appending(path: "transaction.json")
    try "outside scope".write(to: barState, atomically: true, encoding: .utf8)
    let bar = SketchyBarPublicLifecycleFixture()
    let working = YabaiLifecycleFixture(running: true)
    let runner = DesktopApplyCommandRunner(
      lifecycle: working.controller, sketchyBarLifecycle: bar.controller,
      keybindings: nil, prerequisites: .assumed, theme: nil
    )
    let installed = try runner.execute(
      resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: true,
      stateRoot: fixture.state, homeDirectory: fixture.home, adopt: nil, json: true,
      scope: .yabaiOnly,
      macarchyExecutableURL: URL(filePath: "/opt/homebrew/Cellar/macarchy/0.9.3/bin/macarchy")
    )
    #expect(installed.succeeded)
    let previous = YabaiGenerationInspector(stateRoot: fixture.state).inspect()
    let lifecycle = YabaiLifecycleFixture(
      running: true, runtimeStatus: failsVerification ? .drifted : .converged
    )
    let upgraded = try DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller, sketchyBarLifecycle: bar.controller,
      keybindings: nil, prerequisites: .assumed, theme: nil
    ).execute(
      resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: true,
      stateRoot: fixture.state, homeDirectory: fixture.home, adopt: nil, json: true,
      scope: .yabaiOnly, macarchyExecutableURL: URL(filePath: "/opt/homebrew/bin/macarchy")
    )
    #expect(upgraded.succeeded == !failsVerification)
    let current = YabaiGenerationInspector(stateRoot: fixture.state).inspect()
    #expect(current.status == .current)
    #expect((current.generationID == previous.generationID) == failsVerification)
    #expect(
      try YabaiOwnershipStore(stateRoot: fixture.state).read()?.generationID == current.generationID
    )
    #expect(
      try YabaiLifecycleEvidenceStore(stateRoot: fixture.state).read()?.generationID
        == current.generationID)
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    let rendered = try String(
      contentsOf: fixture.home.appending(path: ".config/yabai/yabairc"), encoding: .utf8
    )
    #expect(
      rendered.contains("/opt/homebrew/bin/macarchy reconcile wallpaper") == !failsVerification)
    #expect(
      lifecycle.calls.withLock { $0 }.filter { $0 == "restart" }.count
        == (failsVerification ? 2 : 1))
    #expect(bar.calls.withLock { $0 }.isEmpty)
    #expect(try String(contentsOf: barState, encoding: .utf8) == "outside scope")
  }

  @Test
  func yabaiOnlyBlocksPendingAggregateBeforeProviderMutation() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try DesktopAggregateTransactionStore(stateRoot: fixture.state).write(
      DesktopAggregateTransaction(operation: .apply, phase: .mutating)
    )
    let lifecycle = YabaiLifecycleFixture(running: true)
    let execution = try DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller, keybindings: nil, prerequisites: .assumed, theme: nil
    ).execute(
      resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: true,
      stateRoot: fixture.state, homeDirectory: fixture.home, adopt: nil, json: true,
      scope: .yabaiOnly
    )
    #expect(!execution.succeeded)
    #expect(execution.output.contains("pending desktop/setup transaction"))
    let plan = try DesktopPlanCommandRunner(keybindings: nil, prerequisites: .assumed).execute(
      resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: true,
      stateRoot: fixture.state, homeDirectory: fixture.home, json: true, scope: .yabaiOnly
    )
    #expect(!plan.succeeded)
    #expect(plan.output.contains("pending desktop/setup transaction"))
    #expect(lifecycle.calls.withLock { $0 }.isEmpty)
    #expect(YabaiGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
  }

  @Test
  func yabaiOnlyCommandRejectsUnrelatedAdoption() throws {
    #expect(try Desktop.Apply.parse(["--yabai-only", "--dry-run"]).yabaiOnly)
    #expect(try Desktop.Plan.parse(["--yabai-only"]).yabaiOnly)
    #expect(throws: (any Error).self) {
      _ = try Desktop.Apply.parse(["--yabai-only", "--sketchybar-adopt", "digest"])
    }
  }

  @Test
  func yabaiAccessibilityEvidenceRequiresAnAXBackedWindow() throws {
    #expect(
      try YabaiLifecycleController.accessibilityEvidence(
        from: #"[{"has-ax-reference":false},{"has-ax-reference":true}]"#
      ) == .available
    )
    #expect(
      try YabaiLifecycleController.accessibilityEvidence(
        from: #"[{"has-ax-reference":false}]"#
      ) == .unavailable
    )
    #expect(
      try YabaiLifecycleController.accessibilityEvidence(from: "[]") == .unobservable
    )
  }

  @Test
  func yabaiLifecycleAgreementDoesNotTreatARestartedPIDAsDrift() {
    let recorded = YabaiRuntimeInspection(
      status: .converged,
      message: "verified",
      verifiedSettings: ["layout"],
      verifiedRuleLabels: ["rule"],
      wallpaperSignalVerified: true,
      processID: 41,
      executablePath: "/opt/homebrew/Cellar/yabai/7.1.25/bin/yabai"
    )
    let restarted = YabaiRuntimeInspection(
      status: .converged,
      message: "verified",
      verifiedSettings: ["layout"],
      verifiedRuleLabels: ["rule"],
      wallpaperSignalVerified: true,
      processID: 42,
      executablePath: "/opt/homebrew/Cellar/yabai/7.1.25/bin/yabai"
    )

    #expect(recorded.agreesWithCurrentProcess(restarted))
  }

  @Test
  func trustedSketchyBarHookReportsSuccessfulPartialStatus() throws {
    let fixture = try SketchyBarPublicCommandFixture(hasHook: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let yabaiLifecycle = YabaiLifecycleFixture(running: false)
    let applyRunner = DesktopApplyCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    )

    let apply = try applyRunner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      json: true
    )
    let status = try DesktopStatusCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController,
      keybindings: nil,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(status.output.utf8)) as? [String: Any]
    )

    #expect(apply.succeeded)
    #expect(status.succeeded)
    #expect(report["outcome"] as? String == "partial")
    #expect(
      ((report["sketchybar"] as? [String: Any])?["core_runtime"]
        as? [String: Any])?["status"] as? String == "partial"
    )
  }

  @Test
  func publicCommandsConvergeReportAndTeardownSketchyBar() throws {
    let fixture = try SketchyBarPublicCommandFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let yabaiLifecycle = YabaiLifecycleFixture(running: false)
    let originalEntry = try fixture.installRegularEntry("personal bar\n")
    var original = stat()
    #expect(lstat(originalEntry.path, &original) == 0)
    let runner = DesktopApplyCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    )

    let apply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      sketchyBarAdopt: try fixture.adoptionDigest(),
      json: true
    )
    #expect(apply.succeeded)
    #expect(fixture.lifecycle.isRunning)
    let applyReport = try #require(
      JSONSerialization.jsonObject(with: Data(apply.output.utf8)) as? [String: Any]
    )
    #expect(
      (applyReport["sketchybar"] as? [String: Any])?["generation_id"] as? String != nil
    )
    #expect(
      try fixture.linkTarget(fixture.home.appending(path: ".config/sketchybar/sketchybarrc"))
        == "../macarchy/desktop/sketchybar/current/sketchybarrc"
    )

    let repeatApply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      json: true
    )
    let repeatReport = try #require(
      JSONSerialization.jsonObject(with: Data(repeatApply.output.utf8)) as? [String: Any]
    )
    #expect(repeatApply.succeeded)
    #expect(repeatReport["outcome"] as? String == "no_change")

    let status = try DesktopStatusCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController,
      keybindings: nil,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(status.succeeded)

    let driftedCore = SketchyBarCoreRuntimeInspection(
      status: .drifted,
      message: "injected item drift",
      themeGenerationID: fixture.core.themeGenerationID,
      barColor: fixture.core.barColor,
      items: Array(fixture.core.items.dropLast()),
      spaceIndices: fixture.core.spaceIndices,
      clockLabelPresent: fixture.core.clockLabelPresent
    )
    let driftedStatus = try DesktopStatusCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: SketchyBarCoreRuntimeController(
        inspect: { _ in driftedCore },
        settle: { _ in driftedCore },
        settleRestored: { $0.agreesWithProviderRuntime(driftedCore) }
      ),
      keybindings: nil,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    let driftedReport = try #require(
      JSONSerialization.jsonObject(with: Data(driftedStatus.output.utf8)) as? [String: Any]
    )
    #expect(!driftedStatus.succeeded)
    #expect(driftedReport["outcome"] as? String == "drifted")
    #expect(
      ((driftedReport["sketchybar"] as? [String: Any])?["core_runtime"]
        as? [String: Any])?["status"] as? String == "drifted"
    )

    let transaction = fixture.state.appending(path: "desktop/sketchybar/transaction.json")
    try Data("{}".utf8).write(to: transaction, options: .atomic)
    let corruptTransactionStatus = try DesktopStatusCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController,
      keybindings: nil,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    let corruptReport = try #require(
      JSONSerialization.jsonObject(with: Data(corruptTransactionStatus.output.utf8))
        as? [String: Any]
    )
    #expect(!corruptTransactionStatus.succeeded)
    #expect(corruptReport["outcome"] as? String == "drifted")
    #expect((corruptReport["diagnostics"] as? [String])?.isEmpty == false)
    try FileManager.default.removeItem(at: transaction)

    let teardown = try DesktopTeardownCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController,
      keybindings: nil
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(teardown.succeeded)
    #expect(!fixture.lifecycle.isRunning)
    var restored = stat()
    #expect(lstat(originalEntry.path, &restored) == 0)
    #expect(restored.st_dev == original.st_dev)
    #expect(restored.st_ino == original.st_ino)
    #expect(try String(contentsOf: originalEntry, encoding: .utf8) == "personal bar\n")
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
  }

  @Test
  func cleanInstallAndRoleDisableRoundTripCreatedProviderState() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = YabaiLifecycleFixture(running: false)
    let runner = DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    )

    let apply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      json: true
    )
    let entry = fixture.home.appending(path: ".config/yabai/yabairc")
    #expect(apply.succeeded)
    #expect(try fixture.linkTarget(entry) == fixture.managedTarget)

    try """
    schema_version = 1
    [desktop]
    provider = "disabled"
    [yabai]
    hook = "unused-while-disabled.sh"
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let disablePlan = try DesktopPlanCommandRunner.live.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true,
      scope: .yabaiOnly
    )
    let disablePlanReport = try #require(
      JSONSerialization.jsonObject(with: Data(disablePlan.output.utf8)) as? [String: Any]
    )
    let disableActions = try #require(disablePlanReport["actions"] as? [[String: Any]])
    #expect(disableActions.compactMap { $0["id"] as? String } == ["teardown_yabai_provider"])
    let disable = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      json: true
    )
    #expect(disable.succeeded)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/yabai").path
      )
    )
    #expect(lifecycle.calls.withLock { $0 }.contains("stop"))
    let disabledStatus = try DesktopStatusCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(disabledStatus.succeeded)
  }

  @Test
  func adoptsRegularEntryVerifiesStatusAndRestoresExactInode() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("original yabai\n")
    var originalMetadata = stat()
    #expect(lstat(entry.path, &originalMetadata) == 0)
    let lifecycle = YabaiLifecycleFixture(running: true)
    let runner = DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    )
    let digest = try fixture.adoptionDigest()

    let apply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(apply.succeeded)
    #expect(try fixture.linkTarget(entry) == fixture.managedTarget)

    let repeatApply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      json: true
    )
    let repeatReport = try #require(
      JSONSerialization.jsonObject(with: Data(repeatApply.output.utf8)) as? [String: Any]
    )
    #expect(repeatApply.succeeded)
    #expect(repeatReport["outcome"] as? String == "no_change")
    #expect(repeatReport["mutated"] as? Bool == false)

    let sketchyBarOwnership = fixture.state.appending(
      path: "desktop/sketchybar/ownership.json"
    )
    try FileManager.default.createDirectory(
      at: sketchyBarOwnership.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: sketchyBarOwnership)
    let plan = try DesktopPlanCommandRunner.live.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true,
      scope: .yabaiOnly
    )
    let planReport = try #require(
      JSONSerialization.jsonObject(with: Data(plan.output.utf8)) as? [String: Any]
    )
    #expect((planReport["actions"] as? [Any])?.isEmpty == true)
    #expect(planReport["sketchybar"] == nil)
    try FileManager.default.removeItem(at: sketchyBarOwnership)

    let status = try DesktopStatusCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(status.succeeded)

    let teardown = try DesktopTeardownCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(teardown.succeeded)
    var restoredMetadata = stat()
    #expect(lstat(entry.path, &restoredMetadata) == 0)
    #expect(restoredMetadata.st_ino == originalMetadata.st_ino)
    #expect(try String(contentsOf: entry, encoding: .utf8) == "original yabai\n")
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func adoptsAndRestoresOneFileDirectorySymlinkWithoutTouchingSource() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "dotfiles/yabai", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceEntry = source.appending(path: "yabairc")
    try "dotfiles yabai\n".write(to: sourceEntry, atomically: true, encoding: .utf8)
    let configuration = fixture.home.appending(path: ".config", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    let directory = configuration.appending(path: "yabai", directoryHint: .isDirectory)
    let originalTarget = "../../dotfiles/yabai"
    try FileManager.default.createSymbolicLink(
      atPath: directory.path,
      withDestinationPath: originalTarget
    )
    var originalMetadata = stat()
    #expect(lstat(directory.path, &originalMetadata) == 0)
    let lifecycle = YabaiLifecycleFixture(running: false)
    let digest = try fixture.adoptionDigest()

    let apply = try DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(apply.succeeded)
    #expect(try String(contentsOf: sourceEntry, encoding: .utf8) == "dotfiles yabai\n")

    let teardown = try DesktopTeardownCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(teardown.succeeded)
    #expect(try fixture.linkTarget(directory) == originalTarget)
    var restoredMetadata = stat()
    #expect(lstat(directory.path, &restoredMetadata) == 0)
    #expect(restoredMetadata.st_ino == originalMetadata.st_ino)
  }

  @Test
  func interruptedProviderReplacementRecoversBeforeRetry() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("recover me\n")
    let lifecycle = YabaiLifecycleFixture(running: true)
    let interrupted = DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil,
      faultInjector: { checkpoint in
        if checkpoint == .providerChanged { throw YabaiInterruptionError.injected }
      }
    )
    let digest = try fixture.adoptionDigest()

    #expect(throws: YabaiInterruptionError.self) {
      _ = try interrupted.execute(
        resourcesRoot: fixture.resources,
        profileURL: fixture.profile,
        profileRequired: false,
        stateRoot: fixture.state,
        homeDirectory: fixture.home,
        adopt: digest,
        json: true
      )
    }
    #expect(YabaiTransactionStore(stateRoot: fixture.state).exists)

    let retry = try DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(retry.succeeded)
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(try fixture.linkTarget(entry) == fixture.managedTarget)
  }

  @Test
  func interruptedTeardownResumesForwardFromRestoredOriginal() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("restore after interruption\n")
    let lifecycle = YabaiLifecycleFixture(running: true)
    let digest = try fixture.adoptionDigest()
    let apply = try DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(apply.succeeded)
    let interrupted = DesktopTeardownCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      faultInjector: { checkpoint in
        if checkpoint == .providerRestored { throw YabaiInterruptionError.injected }
      }
    )

    #expect(throws: YabaiInterruptionError.self) {
      _ = try interrupted.execute(
        stateRoot: fixture.state,
        homeDirectory: fixture.home,
        dryRun: false,
        json: true
      )
    }
    #expect(YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(
      try String(contentsOf: entry, encoding: .utf8) == "restore after interruption\n"
    )

    let resumed = try DesktopTeardownCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(resumed.succeeded)
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(
      try String(contentsOf: entry, encoding: .utf8) == "restore after interruption\n"
    )
  }

  @Test
  func failedRuntimeVerificationRollsBackProviderAndServiceState() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("working original\n")
    let lifecycle = YabaiLifecycleFixture(running: true, runtimeStatus: .drifted)
    let digest = try fixture.adoptionDigest()

    let apply = try DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(!apply.succeeded)
    #expect(try String(contentsOf: entry, encoding: .utf8) == "working original\n")
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(lifecycle.calls.withLock { $0 }.filter { $0 == "restart" }.count == 2)
  }

  @Test
  func retainedOriginalDriftBlocksStatusAndTeardownWithoutRemovingManagedEntry() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("retained original\n")
    let lifecycle = YabaiLifecycleFixture(running: true)
    let digest = try fixture.adoptionDigest()
    let apply = try DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(apply.succeeded)
    let storedOwnership = try YabaiOwnershipStore(stateRoot: fixture.state).read()
    let ownership = try #require(storedOwnership)
    let retained = try #require(ownership.retainedOriginalPath)
    try Data("drifted original\n".utf8).write(to: URL(filePath: retained))

    let status = try DesktopStatusCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil,
      theme: nil
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(!status.succeeded)
    let teardown = try DesktopTeardownCommandRunner(
      lifecycle: lifecycle.controller,
      keybindings: nil
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(!teardown.succeeded)
    #expect(try fixture.linkTarget(entry) == fixture.managedTarget)
    #expect(YabaiTransactionStore(stateRoot: fixture.state).exists)
  }

  @Test
  func failedTeardownDryRunNeverReportsMutation() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transaction = fixture.state.appending(path: "desktop/yabai/transaction.json")
    try FileManager.default.createDirectory(
      at: transaction.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: transaction)

    let result = try DesktopTeardownCommandRunner(
      lifecycle: YabaiLifecycleFixture(running: false).controller,
      keybindings: nil
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: true,
      json: true
    )
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
    )

    #expect(!result.succeeded)
    #expect(report["mutated"] as? Bool == false)
  }
}

private struct DesktopApplyFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-desktop-apply-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = state.appending(path: "profile.toml")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try """
    schema_version = 1
    [top_bar]
    provider = "disabled"
    """.write(to: profile, atomically: true, encoding: .utf8)
  }

  var resources: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Desktop", directoryHint: .isDirectory)
  }

  var managedTarget: String { "../macarchy/desktop/yabai/current/yabairc" }

  func installRegularConfiguration(_ text: String) throws -> URL {
    let directory = home.appending(path: ".config/yabai", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let entry = directory.appending(path: "yabairc")
    try text.write(to: entry, atomically: true, encoding: .utf8)
    return entry
  }

  func adoptionDigest() throws -> String {
    let execution = try DesktopPlanCommandRunner.live.execute(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: false,
      stateRoot: state,
      homeDirectory: home,
      json: true,
      scope: .yabaiOnly
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(execution.output.utf8)) as? [String: Any]
    )
    let provider = try #require(object["provider"] as? [String: Any])
    return try #require(provider["adoption_evidence_digest"] as? String)
  }

  func linkTarget(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
  }

}

private struct SketchyBarPublicCommandFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL
  let lifecycle: SketchyBarPublicLifecycleFixture
  let core: SketchyBarCoreRuntimeInspection

  init(hasHook: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-public-tests-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = state.appending(path: "profile.toml")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    var profileText = "schema_version = 1\n[desktop]\nprovider = \"disabled\"\n"
    if hasHook {
      profileText += "[sketchybar]\nhook = \"hook.sh\"\n"
      try "# trusted\n".write(
        to: state.appending(path: "hook.sh"),
        atomically: true,
        encoding: .utf8
      )
    }
    try profileText.write(to: profile, atomically: true, encoding: .utf8)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
    let generation = try ThemeActivator(root: state).activate(package: package)
    lifecycle = SketchyBarPublicLifecycleFixture()
    core = SketchyBarCoreRuntimeInspection(
      status: hasHook ? .partial : .converged,
      message: hasHook ? "partial" : "converged",
      themeGenerationID: generation.generationID,
      barColor: "0xf01e1e2e",
      items: (["macarchy.clock", "macarchy.spaces.unavailable", "macarchy.theme.ready"]
        + (hasHook ? ["personal.demo"] : [])).sorted(),
      spaceIndices: [],
      clockLabelPresent: true
    )
  }

  var resources: URL { repositoryRoot.appending(path: "Desktop", directoryHint: .isDirectory) }

  var coreController: SketchyBarCoreRuntimeController {
    SketchyBarCoreRuntimeController(
      inspect: { _ in core },
      settle: { _ in core },
      settleRestored: { $0.agreesWithProviderRuntime(core) }
    )
  }

  func linkTarget(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
  }

  func installRegularEntry(_ contents: String) throws -> URL {
    let directory = home.appending(path: ".config/sketchybar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let entry = directory.appending(path: "sketchybarrc")
    try contents.write(to: entry, atomically: true, encoding: .utf8)
    return entry
  }

  func adoptionDigest() throws -> String {
    let generation = SketchyBarGenerationInspector(stateRoot: state).inspect()
    let provider = SketchyBarProviderPlanInspector().inspect(
      homeDirectory: home,
      stateRoot: state,
      enabled: true,
      generation: generation
    )
    return try #require(provider.adoptionEvidenceDigest)
  }

}

private final class SketchyBarPublicLifecycleFixture: Sendable {
  let calls = Mutex<[String]>([])
  private let running = Mutex(false)

  var isRunning: Bool { running.withLock { $0 } }

  var controller: SketchyBarLifecycleController {
    SketchyBarLifecycleController(
      inspect: {
        self.calls.withLock { $0.append("inspect") }
        return self.running.withLock { $0 } ? Self.runtime : .stopped
      },
      preflight: {
        self.calls.withLock { $0.append("preflight") }
        return self.running.withLock { $0 }
      },
      reload: { _ in
        self.calls.withLock { $0.append("reload") }
        return Self.runtime
      },
      start: {
        self.calls.withLock { $0.append("start") }
        self.running.withLock { $0 = true }
        return Self.runtime
      },
      stop: {
        self.calls.withLock { $0.append("stop") }
        self.running.withLock { $0 = false }
      }
    )
  }

  private static let runtime = SketchyBarRuntimeInspection(
    status: .running,
    message: "running",
    processID: 42,
    executablePath: "/opt/homebrew/Cellar/sketchybar/2.23.0/bin/sketchybar",
    serviceLabel: SketchyBarHomebrewService.serviceLabel
  )
}

private final class YabaiLifecycleFixture: Sendable {
  let calls = Mutex<[String]>([])
  private let running: Mutex<Bool>
  private let runtimeStatus: YabaiRuntimeStatus

  init(running: Bool, runtimeStatus: YabaiRuntimeStatus = .converged) {
    self.running = Mutex(running)
    self.runtimeStatus = runtimeStatus
  }

  var controller: YabaiLifecycleController {
    YabaiLifecycleController(
      preflight: {
        self.calls.withLock { $0.append("preflight") }
        return self.running.withLock { $0 }
      },
      restart: {
        self.calls.withLock { $0.append("restart") }
        self.running.withLock { $0 = true }
      },
      stop: {
        self.calls.withLock { $0.append("stop") }
        self.running.withLock { $0 = false }
      },
      inspect: { composition in
        self.calls.withLock { $0.append("inspect") }
        return YabaiRuntimeInspection(
          status: self.runtimeStatus,
          message: self.runtimeStatus == .drifted ? "injected runtime drift" : "verified",
          verifiedSettings: [composition.settings.layout],
          verifiedRuleLabels: composition.settings.rules.compactMap(\.label),
          wallpaperSignalVerified: self.runtimeStatus != .drifted,
          processID: 42,
          executablePath: "/opt/homebrew/bin/yabai"
        )
      },
      waitBetweenInspections: {}
    )
  }
}
