import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SpicetifyPresetLifecycleTests {
  @Test(arguments: [false, true])
  func explicitRecoveryRestoresDomainsButNeverClaimsSpotifyVerified(interruptDesktop: Bool)
    async throws
  {
    let original = "[Setting]\ncurrent_theme = text\ncolor_scheme = Personal\n"
    let fixture = try SpicetifyPresetFixture(configuration: original)
    defer { removeSpicetifyTestRoot(fixture.root) }
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let inspection = try fixture.inspection(enabled: true)
    _ = try coordinator.applyLocked(
      composition: fixture.composition(enabled: true), inspection: inspection,
      adoptionDigest: inspection.adoptionEvidenceDigest,
      themeBridges: EnvironmentThemeBridgeState(entries: []))
    #expect(throws: EnvironmentLifecycleError.self) {
      try coordinator.deferOriginalSpicetifyRuntimeLocked()
    }
    try coordinator.rollbackApplyLocked()
    let context = UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes"),
      keybindingsResourcesRoot: repositoryRoot.appending(path: "Keybindings"),
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: try fixture.profile(enabled: true), profileRequired: true,
      machineProfileURL: fixture.root.appending(path: "absent-machine.toml"),
      machineProfileRequired: false,
      stateRoot: fixture.state, homeDirectory: fixture.home)
    let paths = testConsumerPaths()
    let transaction = UnifiedSetupTransaction(
      operation: .apply, stages: [.theme, .desktop, .environment], desiredAppearance: .dark,
      contextDigest: unifiedSetupContextDigest(context: context, consumerPaths: paths))
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let unified = UnifiedSetupTransactionStore(stateRoot: fixture.state)
    try unified.write(transaction)
    let calls = Mutex([String]())
    let refreshes = Mutex(0)
    let shouldInterrupt = Mutex(interruptDesktop)
    let runner = UnifiedSetupRecoveryCommandRunner(
      teardown: UnifiedSetupTeardownCommandRunner(
        planner: .live,
        environmentTeardown: { _, _, _ in
          Issue.record("Apply rollback must not use ordinary teardown")
          return try teardownComponent(dryRun: false, mutated: false)
        },
        desktopTeardown: { _, _, _ in
          Issue.record("Apply rollback must not use ordinary teardown")
          return try teardownComponent(dryRun: false, mutated: false)
        },
        themeTeardown: { state, _, _, dryRun in
          #expect(!dryRun)
          #expect(calls.withLock { $0.last } == "desktop")
          calls.withLock { $0.append("theme") }
          let generation = try ReconciliationStatusStore(root: state).activeManifest().generationID
          _ = try ThemeActivator(root: state).deactivate(
            expectedGenerationID: generation, dryRun: false)
          return .noChange("Prior theme absence restored")
        },
        environmentApplyFinalization: { context, commit in
          #expect(!commit)
          calls.withLock { $0.append("environment") }
          _ = try EnvironmentApplyCommandRunner(
            prerequisites: .assumed, theme: nil, verifier: .assumed,
            spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher { _, _, _ in
              refreshes.withLock { $0 += 1 }
              throw EnvironmentLifecycleError.blocked("stock Spotify cannot refresh")
            }
          ).finishDeferredApply(
            stateRoot: context.stateRoot, homeDirectory: context.homeDirectory, commit: false)
          #expect(try store.readTransaction() == nil)
          return .noChange("Environment configuration restored; Spotify runtime unverified")
        },
        desktopApplyFinalization: { _, commit in
          #expect(!commit)
          #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == original)
          #expect(!FileManager.default.fileExists(atPath: fixture.colorLink.path))
          if shouldInterrupt.withLock({ value in
            let previous = value
            value = false
            return previous
          }) {
            throw EnvironmentLifecycleError.blocked("interrupted desktop recovery")
          }
          calls.withLock { $0.append("desktop") }
          return .noChange("Prior desktop restored")
        }))
    let refused = try await runner.execute(
      context: context, consumerPaths: paths, acknowledgeUnverifiedSpicetify: false, json: true)
    #expect(!refused.succeeded)
    #expect(refreshes.withLock { $0 } == 1)
    #expect(try !store.hasUnverifiedSpicetifyRecovery())
    #expect(try store.readTransaction()?.spicetifyRuntimeVerified == nil)
    #expect(calls.withLock { $0 } == ["environment"])
    calls.withLock { $0 = [] }

    // Consent cannot authorize a different consumer-path context.
    try unified.write(
      UnifiedSetupTransaction(
        operation: .apply, stages: transaction.stages, desiredAppearance: .dark,
        contextDigest: "sha256:" + String(repeating: "0", count: 64)))
    let wrongContext = try await runner.execute(
      context: context, consumerPaths: paths, acknowledgeUnverifiedSpicetify: true, json: true)
    #expect(!wrongContext.succeeded)
    #expect(try !store.hasUnverifiedSpicetifyRecovery())
    try unified.write(transaction.replacing(phase: .committing))
    let committed = try await runner.execute(
      context: context, consumerPaths: paths, acknowledgeUnverifiedSpicetify: true, json: true)
    #expect(!committed.succeeded)
    #expect(try !store.hasUnverifiedSpicetifyRecovery())
    try unified.write(transaction.replacing(stages: [.theme, .desktop]))
    let unrelated = try await runner.execute(
      context: context, consumerPaths: paths, acknowledgeUnverifiedSpicetify: true, json: true)
    #expect(!unrelated.succeeded)
    #expect(try !store.hasUnverifiedSpicetifyRecovery())
    try unified.write(transaction)

    var recovered = try await runner.execute(
      context: context, consumerPaths: paths, acknowledgeUnverifiedSpicetify: true, json: true)
    if interruptDesktop {
      #expect(!recovered.succeeded)
      #expect(recovered.output.contains("UNVERIFIED"))
      #expect(try store.readTransaction() == nil)
      #expect(try store.hasUnverifiedSpicetifyRecovery())
      recovered = try await runner.execute(
        context: context, consumerPaths: paths, acknowledgeUnverifiedSpicetify: true, json: true)
    }
    #expect(recovered.succeeded)
    #expect(recovered.output.contains("recovered_with_unverified_runtime"))
    #expect(recovered.output.contains("UNVERIFIED"))
    #expect(calls.withLock { $0 } == ["environment", "desktop", "theme"])
    #expect(refreshes.withLock { $0 } == 1)
    #expect(try store.readOwnership() == nil)
    #expect(try store.readTransaction() == nil)
    #expect(try unified.read() == nil)
    #expect(try store.hasUnverifiedSpicetifyRecovery())
    #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "current").path))
    let disabledPlan = try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: context.environmentResourcesRoot, profileURL: fixture.profile(enabled: false),
      profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home, json: true)
    #expect(disabledPlan.succeeded)
    #expect(disabledPlan.output.contains("UNVERIFIED"))
  }

  @Test
  func reenablingAfterDeferralRequiresActualRefreshEvenWhenAdapterReportsMatchingEvidence()
    async throws
  {
    let fixture = try SpicetifyPresetFixture(
      configuration: "[Setting]\ncurrent_theme = Personal\ncolor_scheme = Blue\n")
    defer { removeSpicetifyTestRoot(fixture.root) }
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.recordUnverifiedSpicetifyRecovery()
    let refreshes = Mutex(0)
    let theme = DesktopThemeController(
      reconcile: { ids, state, _ in
        DesktopThemeReconciliation(
          generationID: try ReconciliationStatusStore(root: state).activeManifest().generationID,
          results: ids.map {
            DesktopThemeAdapterStatus(
              adapterID: $0, requirement: "required", status: "applied", message: "matching receipt"
            )
          },
          succeeded: true)
      }, inspect: { _, _, _ in [] })
    let inspection = try fixture.inspection(enabled: true)
    let result = try await EnvironmentApplyCommandRunner(
      prerequisites: .assumed, theme: theme, verifier: .assumed,
      spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher { _, _, clear in
        #expect(!clear)
        let pending = try store.hasUnverifiedSpicetifyRecovery()
        #expect(pending)
        refreshes.withLock { $0 += 1 }
        return "Actual refresh completed"
      }
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: fixture.profile(enabled: true), profileRequired: true,
      stateRoot: fixture.state, homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(), adopt: inspection.adoptionEvidenceDigest, json: true)
    #expect(result.succeeded)
    #expect(refreshes.withLock { $0 } == 1)
    #expect(try !store.hasUnverifiedSpicetifyRecovery())
  }

  @Test
  func managedRestorationCannotBeDeferredAndMalformedDeferralFailsClosed() throws {
    let fixture = try SpicetifyPresetFixture(
      configuration: "[Setting]\ncurrent_theme = Personal\ncolor_scheme = Blue\n")
    defer { removeSpicetifyTestRoot(fixture.root) }
    let inspection = try fixture.inspection(enabled: true)
    _ = try fixture.apply(
      enabled: true, inspection: inspection, adoptionDigest: inspection.adoptionEvidenceDigest)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    _ = try coordinator.applyLocked(
      composition: fixture.composition(enabled: false),
      inspection: fixture.inspection(enabled: false),
      adoptionDigest: nil, themeBridges: EnvironmentThemeBridgeState(entries: []))
    try coordinator.rollbackApplyLocked()
    #expect(try coordinator.pendingSpicetifyRuntimeTargetLocked() == .managed)
    #expect(throws: EnvironmentLifecycleError.self) {
      try coordinator.deferOriginalSpicetifyRuntimeLocked()
    }
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    var invalid = try #require(try store.readTransaction())
    invalid.spicetifyRuntimeDeferred = true
    try store.writeTransaction(invalid)
    #expect(throws: EnvironmentLifecycleError.self) { try store.readTransaction() }
    #expect(try !store.hasUnverifiedSpicetifyRecovery())
  }

  @Test
  func ordinarySelectorsRequireReviewAndRoundTripWithoutOwningOtherConfiguration() throws {
    let original =
      "[Setting]\ncurrent_theme = Personal # keep\ncolor_scheme = Blue\nspotify_path = /external\n"
    let fixture = try SpicetifyPresetFixture(configuration: original)
    defer { removeSpicetifyTestRoot(fixture.root) }

    let inspection = try fixture.inspection(enabled: true)
    let digest = try #require(inspection.adoptionEvidenceDigest)
    #expect(
      inspection.entries.contains {
        $0.id == "spicetify_configuration" && $0.status == .adoptionRequired
      })
    _ = try fixture.apply(enabled: true, inspection: inspection, adoptionDigest: digest)
    let managed = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(managed.contains("current_theme = text"))
    #expect(managed.contains("color_scheme = MacarchyCurrent"))
    #expect(managed.contains("spotify_path = /external"))
    #expect(try fixture.colorLinkDestination() == fixture.colorDestination.path)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(ownership.spicetifyEnabled)
    #expect(ownership.spicetify?.originalTheme == "Personal # keep")
    #expect(ownership.spicetify?.originalColorScheme == "Blue")
    let encodedOwnership = String(
      decoding: try JSONEncoder().encode(ownership),
      as: UTF8.self
    )
    #expect(!encodedOwnership.contains("original_configuration"))
    #expect(!encodedOwnership.contains("spotify_path"))
    #expect(!encodedOwnership.contains("/external"))
    #expect(ownership.records.map(\.id) == [.spicetifyColor])

    let providerRewrite = managed.replacingOccurrences(
      of: "spotify_path = /external", with: "spotify_path = /provider-rewrite")
    try providerRewrite.write(to: fixture.configuration, atomically: true, encoding: .utf8)
    _ = try fixture.apply(enabled: false)
    let restored = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(restored.contains("current_theme = Personal # keep"))
    #expect(restored.contains("color_scheme = Blue"))
    #expect(restored.contains("spotify_path = /provider-rewrite"))
    #expect(!FileManager.default.fileExists(atPath: fixture.colorLink.path))
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state, homeDirectory: fixture.home
      ).contains(SpicetifyAdapter.id))
  }

  @Test
  func completeExactSymlinkTupleIsAuthorityOnlyAndNeverAdopted() throws {
    let fixture = try SpicetifyPresetFixture(configuration: nil)
    defer { removeSpicetifyTestRoot(fixture.root) }
    try fixture.installExternalTuple()
    let before = try fixture.snapshotExternalTuple()

    let inspection = try fixture.inspection(enabled: true)
    #expect(inspection.adoptionEvidenceDigest == nil)
    #expect(
      inspection.entries.contains {
        $0.id == "spicetify_configuration" && $0.ownership == "external_exact"
      })
    _ = try fixture.apply(enabled: true, inspection: inspection)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(ownership.spicetify == nil)
    #expect(!ownership.records.contains { $0.id == .spicetifyColor })
    #expect(try fixture.snapshotExternalTuple() == before)

    _ = try fixture.apply(enabled: false)
    #expect(try fixture.snapshotExternalTuple() == before)
  }

  @Test
  func malformedPartialAndDivergentStateFailClosed() throws {
    for text in [
      "[Setting\ncurrent_theme = Personal\ncolor_scheme = Blue\n",
      "[Setting]\ncurrent_theme = One\ncurrent_theme = Two\ncolor_scheme = Blue\n",
      "[Setting]\ncurrent_theme = \(String(repeating: "x", count: EnvironmentSpicetifyOwnership.maximumSelectorSize + 1))\ncolor_scheme = Blue\n",
    ] {
      let fixture = try SpicetifyPresetFixture(configuration: text)
      defer { removeSpicetifyTestRoot(fixture.root) }
      #expect(try fixture.inspection(enabled: true).isBlocked)
      #expect(try Data(contentsOf: fixture.configuration) == Data(text.utf8))
    }

    let partial = try SpicetifyPresetFixture(
      configuration: "[Setting]\ncurrent_theme = text\ncolor_scheme = macarchy\n")
    defer { removeSpicetifyTestRoot(partial.root) }
    let partialInspection = try partial.inspection(enabled: true)
    #expect(!partialInspection.isBlocked)
    #expect(partialInspection.adoptionEvidenceDigest != nil)

    try FileManager.default.removeItem(
      at: partial.colorLink.deletingLastPathComponent().deletingLastPathComponent()
    )
    #expect(try partial.inspection(enabled: true).isBlocked)
  }

  @Test
  func disableRollbackRetainsRuntimeRecoveryUntilPriorTargetRefreshes() throws {
    let fixture = try SpicetifyPresetFixture(
      configuration: "[Setting]\ncurrent_theme = Personal\ncolor_scheme = Blue\n")
    defer { removeSpicetifyTestRoot(fixture.root) }
    let enabled = try fixture.inspection(enabled: true)
    _ = try fixture.apply(
      enabled: true,
      inspection: enabled,
      adoptionDigest: enabled.adoptionEvidenceDigest
    )

    let disabledComposition = try fixture.composition(enabled: false)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    _ = try coordinator.applyLocked(
      composition: disabledComposition,
      inspection: try fixture.inspection(enabled: false),
      adoptionDigest: nil,
      themeBridges: EnvironmentThemeBridgeState(entries: [])
    )
    #expect(try coordinator.pendingSpicetifyRuntimeTargetLocked() == .original)
    #expect(EnvironmentStateStore(stateRoot: fixture.state).transactionExists)

    try coordinator.rollbackApplyLocked()
    #expect(try coordinator.pendingSpicetifyRuntimeTargetLocked() == .managed)
    #expect(EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    try coordinator.markSpicetifyRuntimeVerifiedLocked(.managed)
    _ = try coordinator.prepareRecoveryLocked()
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8).contains(
        "current_theme = text"))
  }

  @Test
  func aggregateDisableRefreshesRestoredTargetBeforeRemovingAuthority() async throws {
    let original = "[Setting]\ncurrent_theme = Personal\ncolor_scheme = Blue\n"
    let fixture = try SpicetifyPresetFixture(configuration: original)
    defer { removeSpicetifyTestRoot(fixture.root) }
    let enabled = try fixture.inspection(enabled: true)
    _ = try fixture.apply(
      enabled: true,
      inspection: enabled,
      adoptionDigest: enabled.adoptionEvidenceDigest
    )
    let refreshes = Mutex(0)

    let result = try await EnvironmentApplyCommandRunner(
      prerequisites: .assumed,
      theme: nil,
      verifier: .assumed,
      spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher { _, _, clearEvidence in
        #expect(clearEvidence)
        refreshes.withLock { $0 += 1 }
        return "restored Spicetify configuration refreshed"
      }
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: try fixture.profile(enabled: false),
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      json: true
    )

    #expect(result.succeeded)
    #expect(refreshes.withLock { $0 } == 1)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.colorLink.path))
  }

  @Test
  func aggregateDisablePreflightsRestorationDependenciesBeforeMutation() async throws {
    let fixture = try SpicetifyPresetFixture(
      configuration: "[Setting]\ncurrent_theme = Personal\ncolor_scheme = Blue\n")
    defer { removeSpicetifyTestRoot(fixture.root) }
    let enabled = try fixture.inspection(enabled: true)
    _ = try fixture.apply(
      enabled: true,
      inspection: enabled,
      adoptionDigest: enabled.adoptionEvidenceDigest
    )
    let priorOwnership = try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    let priorConfiguration = try Data(contentsOf: fixture.configuration)
    let inspections = Mutex(0)
    let refreshes = Mutex(0)

    let result = try await EnvironmentApplyCommandRunner(
      prerequisites: missingSpicetifyRuntimePrerequisites {
        inspections.withLock { $0 += 1 }
      },
      theme: nil,
      verifier: .assumed,
      spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher { _, _, _ in
        refreshes.withLock { $0 += 1 }
        return "unexpected refresh"
      }
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: try fixture.profile(enabled: false, slack: true),
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      json: true
    )

    #expect(!result.succeeded)
    #expect(inspections.withLock { $0 } == 1)
    #expect(refreshes.withLock { $0 } == 0)
    #expect(try Data(contentsOf: fixture.configuration) == priorConfiguration)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == priorOwnership)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(result.output.contains("spicetify"))
    #expect(result.output.contains("spotify"))
    #expect(!result.output.contains("manual_required"))
  }

  @Test
  func teardownPreflightsRestorationDependenciesBeforeMutation() async throws {
    let fixture = try SpicetifyPresetFixture(
      configuration: "[Setting]\ncurrent_theme = Personal\ncolor_scheme = Blue\n")
    defer { removeSpicetifyTestRoot(fixture.root) }
    let enabled = try fixture.inspection(enabled: true)
    _ = try fixture.apply(
      enabled: true,
      inspection: enabled,
      adoptionDigest: enabled.adoptionEvidenceDigest
    )
    let priorOwnership = try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    let priorConfiguration = try Data(contentsOf: fixture.configuration)
    let inspections = Mutex(0)
    let refreshes = Mutex(0)

    let result = try await EnvironmentTeardownCommandRunner(
      prerequisites: missingSpicetifyRuntimePrerequisites {
        inspections.withLock { $0 += 1 }
      },
      spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher { _, _, _ in
        refreshes.withLock { $0 += 1 }
        return "unexpected refresh"
      }
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: true
    )

    #expect(!result.succeeded)
    #expect(inspections.withLock { $0 } == 1)
    #expect(refreshes.withLock { $0 } == 0)
    #expect(try Data(contentsOf: fixture.configuration) == priorConfiguration)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == priorOwnership)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(result.output.contains("spicetify"))
    #expect(result.output.contains("spotify"))
  }

  @Test
  func disabledSteadyStateDoesNotInspectSpicetifyRuntime() async throws {
    let fixture = try SpicetifyPresetFixture(configuration: nil)
    defer { removeSpicetifyTestRoot(fixture.root) }
    let inspections = Mutex(0)

    let result = try await EnvironmentApplyCommandRunner(
      prerequisites: missingSpicetifyRuntimePrerequisites {
        inspections.withLock { $0 += 1 }
      },
      theme: nil,
      verifier: .assumed
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: try fixture.profile(enabled: false),
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      json: true
    )

    #expect(result.succeeded)
    #expect(inspections.withLock { $0 } == 0)
  }
}

private func missingSpicetifyRuntimePrerequisites(
  inspected: @escaping @Sendable () -> Void
) -> EnvironmentPrerequisiteInspector {
  EnvironmentPrerequisiteInspector(
    { _, _ in [] },
    spicetifyRuntime: { _ in
      inspected()
      return [
        EnvironmentPrerequisiteStatus(
          id: SpicetifyAdapter.id,
          status: "missing",
          requirement: "compatible Spicetify CLI required",
          remediation: "Install compatible Spicetify."
        ),
        EnvironmentPrerequisiteStatus(
          id: "spotify",
          status: "missing",
          requirement: "compatible Spotify bundle required",
          remediation: "Install compatible Spotify."
        ),
      ]
    }
  )
}

func removeSpicetifyTestRoot(_ root: URL) {
  guard
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
  else { return }
  var directories = [root]
  for case let item as URL in enumerator {
    if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      directories.append(item)
    }
  }
  for directory in directories.reversed() {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
  }
  try? FileManager.default.removeItem(at: root)
}

private struct SpicetifyPresetFixture {
  let root: URL
  let home: URL
  let state: URL
  let configuration: URL
  let colorLink: URL
  let colorDestination: URL

  init(configuration contents: String?) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-spicetify-preset-\(UUID().uuidString)", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    configuration = home.appending(path: ".config/spicetify/config-xpui.ini")
    colorLink = home.appending(path: ".config/spicetify/Themes/text/color.ini")
    colorDestination = state.appending(path: "current/\(SpicetifyAdapter.outputPath)")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    if let contents {
      try FileManager.default.createDirectory(
        at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: configuration, atomically: true, encoding: .utf8)
      try FileManager.default.createDirectory(
        at: colorLink.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))
    _ = try ThemeActivator(root: state).activate(package: package)
  }

  func composition(enabled: Bool) throws -> EnvironmentComposition {
    let profile = try profile(enabled: enabled)
    return try EnvironmentConfigurationComposer().compose(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profile: PortableProfileLoader().load(at: profile, required: true),
      stateRoot: state
    )
  }

  func profile(enabled: Bool, slack: Bool = false) throws -> URL {
    let profile = root.appending(path: "profile-\(enabled)-\(slack).toml")
    try """
    schema_version = 1
    [focus_ring]
    provider = "disabled"
    [terminal]
    provider = "disabled"
    [shell]
    provider = "disabled"
    [editor]
    provider = "disabled"
    [tools]
    bat = false
    eza = false
    btop = false
    yazi = false
    [presets]
    slack = \(slack)
    spicetify = \(enabled)
    """.write(to: profile, atomically: true, encoding: .utf8)
    return profile
  }

  func inspection(enabled: Bool) throws -> EnvironmentProviderInspection {
    EnvironmentProviderInspector().inspect(
      composition: try composition(enabled: enabled), homeDirectory: home, stateRoot: state)
  }

  func apply(
    enabled: Bool,
    inspection supplied: EnvironmentProviderInspection? = nil,
    adoptionDigest: String? = nil
  ) throws -> (changed: Bool, generationID: String) {
    let composition = try composition(enabled: enabled)
    let coordinator = EnvironmentTransactionCoordinator(homeDirectory: home, stateRoot: state)
    let result = try coordinator.applyLocked(
      composition: composition,
      inspection: supplied ?? inspection(enabled: enabled),
      adoptionDigest: adoptionDigest,
      themeBridges: EnvironmentThemeBridgeState(entries: [])
    )
    if let target = try coordinator.pendingSpicetifyRuntimeTargetLocked() {
      try coordinator.markSpicetifyRuntimeVerifiedLocked(target)
    }
    try coordinator.finishApplyLocked(composition: composition)
    return result
  }

  func colorLinkDestination() throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: colorLink.path)
  }

  func installExternalTuple() throws {
    let dotfiles = root.appending(path: "dotfiles/spicetify", directoryHint: .isDirectory)
    let themes = root.appending(path: "dotfiles/themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: themes.appending(path: "text"), withIntermediateDirectories: true)
    try "[Setting]\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n".write(
      to: dotfiles.appending(path: "config-xpui.ini"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: themes.appending(path: "text/color.ini"), withDestinationURL: colorDestination)
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: configuration.path, withDestinationPath: "../../../dotfiles/spicetify/config-xpui.ini"
    )
    try FileManager.default.createSymbolicLink(
      atPath: colorLink.deletingLastPathComponent().deletingLastPathComponent().path,
      withDestinationPath: themes.path
    )
  }

  func snapshotExternalTuple() throws -> [String] {
    try [
      configuration, configuration.resolvingSymlinksInPath(),
      colorLink.deletingLastPathComponent().deletingLastPathComponent(), colorLink,
    ]
    .map { url in
      var value = stat()
      guard lstat(url.path, &value) == 0 else {
        throw EnvironmentLifecycleError.system("snapshot Spicetify test tuple", url, errno)
      }
      let link =
        value.st_mode & S_IFMT == S_IFLNK
        ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : ""
      return "\(url.path):\(value.st_dev):\(value.st_ino):\(value.st_mode):\(link)"
    }
  }
}
