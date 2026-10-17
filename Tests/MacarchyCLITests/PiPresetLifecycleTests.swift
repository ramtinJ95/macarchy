import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PiPresetLifecycleTests {
  @Test
  func statusDoctorAndTeardownKeepLaterSettingsAroundTheOwnedMember() async throws {
    let fixture = try PiFixture(settings: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(try fixture.plan().succeeded)
    #expect(try await fixture.apply().succeeded)
    #expect(try fixture.status().succeeded)
    #expect(try fixture.doctor().succeeded)
    let repeated = try await fixture.apply()
    #expect(try jsonObject(repeated.output)["outcome"] as? String == "no_change")

    try "{\"theme\": \"macarchy-current\", \"lastModel\": \"private-value\"}\n".write(
      to: fixture.settings,
      atomically: true,
      encoding: .utf8
    )
    #expect(try await fixture.teardown().succeeded)
    #expect(
      try String(contentsOf: fixture.settings, encoding: .utf8)
        == "{\"lastModel\": \"private-value\"}\n"
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.themeLink.path))
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains(PiAdapter.id)
    )
  }

  @Test
  func selectedMissingMalformedAndOldVersionsBlockBeforeMutation() async throws {
    for reason in ["missing executable", "unparseable version", "Pi 0.84.2 is unsupported"] {
      let fixture = try PiFixture(settings: "{\"theme\":\"personal\"}\n")
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let inspector = EnvironmentPrerequisiteInspector { profile, _ in
        guard profile.presets.pi else { return [] }
        return [
          EnvironmentPrerequisiteStatus(
            id: PiAdapter.id,
            status: "missing",
            requirement: reason,
            remediation: "Run: npm install --global @earendil-works/pi-coding-agent"
          )
        ]
      }
      let result = try await fixture.apply(prerequisites: inspector)
      #expect(!result.succeeded)
      #expect(result.output.contains("Missing prerequisites: pi"))
      #expect(
        try String(contentsOf: fixture.settings, encoding: .utf8) == "{\"theme\":\"personal\"}\n")
      #expect(!FileManager.default.fileExists(atPath: fixture.themeLink.path))
      #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    }
  }

  @Test
  func versionContractHasMinimumAndNoUpperCap() throws {
    #expect(PiAdapter.parseVersion("0.84.3") == [0, 84, 3])
    #expect(PiAdapter.parseVersion("pi 12.0.0") == [12, 0, 0])
    #expect(PiAdapter.parseVersion("development") == nil)

    for (output, succeeds) in [("0.84.2", false), ("0.84.3", true), ("99.1.0", true)] {
      let adapter = PiAdapter(
        root: URL(filePath: "/state"),
        configurationDirectoryURL: URL(filePath: "/home/.pi/agent"),
        executableURL: URL(filePath: "/opt/homebrew/bin/pi"),
        controlIsAvailable: { true },
        processRunner: ProcessRunner { request in
          #expect(request.arguments == ["--version"])
          return ProcessResult(terminationStatus: 0, output: output)
        }
      )
      if succeeds {
        #expect(try adapter.supportedVersion() == output)
      } else {
        #expect(throws: PiAdapterError.self) { try adapter.supportedVersion() }
      }
    }
  }

  @Test
  func divergentMemberAdoptionRestoresExactBytesAroundUnrelatedPiRewrites() async throws {
    let original =
      "{\n  \"model\": \"one\",\n  \"theme\"  :  {\"personal\":true},\n  \"thinking\": \"high\"\n}\n"
    let fixture = try PiFixture(settings: original)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    #expect(
      try String(contentsOf: fixture.settings, encoding: .utf8).contains(
        "\"theme\": \"macarchy-current\""
      )
    )

    try
      "{\n  \"lastModel\": \"provider-rewrite\",\n  \"theme\" : \"macarchy-current\",\n  \"thinking\": \"max\"\n}\n"
      .write(
        to: fixture.settings,
        atomically: true,
        encoding: .utf8
      )
    try fixture.writeProfile(pi: false)
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains(PiAdapter.id)
    )
    #expect(try await fixture.apply().succeeded)
    #expect(
      try String(contentsOf: fixture.settings, encoding: .utf8)
        == "{\n  \"lastModel\": \"provider-rewrite\",\n  \"theme\"  :  {\"personal\":true},\n  \"thinking\": \"max\"\n}\n"
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.themeLink.path))
  }

  @Test(arguments: [ExternalPiLayout.configurationSymlink, .directorySymlink])
  func completeExternalStowTupleIsAuthorityOnlyForEverySupportedLayout(
    layout: ExternalPiLayout
  ) async throws {
    let fixture = try PiFixture(settings: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.installExternalTuple(layout: layout)
    let original = try fixture.externalTupleSnapshot()

    let plan = try fixture.plan()
    #expect(plan.succeeded)
    let plannedEntries = try #require(try jsonObject(plan.output)["entries"] as? [[String: Any]])
    #expect(
      Dictionary(
        uniqueKeysWithValues: plannedEntries.compactMap { entry -> (String, String)? in
          guard let id = entry["id"] as? String, id.hasPrefix("pi_") else { return nil }
          return (id, entry["ownership"] as? String ?? "")
        }
      ) == [
        EnvironmentEntryID.piConfiguration.rawValue: "external_exact",
        EnvironmentEntryID.piTheme.rawValue: "external_exact",
      ]
    )
    let apply = try await fixture.apply(theme: fixture.restartRequiredThemeController)
    #expect(apply.succeeded)
    let appliedTheme = try #require(
      (try jsonObject(apply.output)["theme"] as? [[String: Any]])?.first
    )
    #expect(appliedTheme["status"] as? String == "restart_required")
    #expect((appliedTheme["message"] as? String)?.contains("/reload or a new launch") == true)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    #expect(ownership.piEnabled)
    #expect(ownership.pi == nil)
    #expect(!ownership.records.contains { $0.id == .piTheme })
    #expect(try fixture.externalTupleSnapshot() == original)
    let themeReconciliation = try await fixture.reconcilePi()
    let piResult = try #require(themeReconciliation.results.first)
    #expect(piResult.status == "restart_required")
    #expect(piResult.message?.contains("/reload or a new launch") == true)
    #expect(try fixture.externalTupleSnapshot() == original)
    #expect(try fixture.status().succeeded)
    #expect(try fixture.externalTupleSnapshot() == original)
    let noOp = try await fixture.apply()
    #expect(noOp.succeeded)
    #expect(try jsonObject(noOp.output)["outcome"] as? String == "no_change")
    #expect(try fixture.externalTupleSnapshot() == original)

    try fixture.writeProfile(pi: false)
    #expect(try await fixture.apply().succeeded)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try fixture.externalTupleSnapshot() == original)

    try fixture.writeProfile(pi: true)
    #expect(try await fixture.apply().succeeded)
    #expect(try await fixture.teardown().succeeded)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try fixture.externalTupleSnapshot() == original)
  }

  @Test(arguments: [OwnedPiLink.environment, .legacySetup])
  func ownedWatchedLinkRefreshChangesTheEntryAndReportsApplied(
    owner: OwnedPiLink
  ) async throws {
    let fixture = try PiFixture(settings: owner == .legacySetup ? "{}\n" : nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    if owner == .legacySetup { try fixture.installLegacyTuple() }
    #expect(try await fixture.apply().succeeded)
    #expect(
      try ThemeRuntimeSelection.piThemeLinkRefreshIsAllowed(
        stateRoot: fixture.state,
        consumerPaths: fixture.managedConsumerPaths
      )
    )
    let originalInode = try fixture.themeLinkInode()

    let reconciliation = try await fixture.reconcilePi()

    let piResult = try #require(reconciliation.results.first)
    #expect(piResult.status == "applied")
    #expect(piResult.message == "Running Pi sessions reloaded the active palette")
    #expect(try fixture.themeLinkInode() != originalInode)
  }

  @Test
  func partialExternalStowTupleBlocksBeforeMutation() async throws {
    let partial = try PiFixture(settings: nil)
    defer { try? FileManager.default.removeItem(at: partial.root) }
    try partial.installExternalTuple(layout: .configurationSymlink)
    try FileManager.default.removeItem(at: partial.themeLink)
    let blocked = try partial.plan()
    #expect(!blocked.succeeded)
    #expect(blocked.output.contains("requires the exact watched theme link"))
    #expect(!(try await partial.apply()).succeeded)
    #expect(
      !FileManager.default.fileExists(
        atPath: partial.state.appending(path: "environment/ownership.json").path))
  }

  @Test
  func completeLegacyTupleStaysActiveAndSetupTeardownCannotBreakAppliedAuthority() async throws {
    let fixture = try PiFixture(settings: "{}\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    let manager = SetupOwnershipManager()
    try fixture.installLegacyTuple()
    #expect(try fixture.plan().output.contains("legacy_setup"))
    #expect(try await fixture.apply().succeeded)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    #expect(ownership.piEnabled)
    #expect(ownership.enabledThemeAdapterIDs == [PiAdapter.id])
    #expect(ownership.pi == nil)
    #expect(!ownership.records.contains { $0.id == .piTheme })
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains(PiAdapter.id)
    )

    let teardown = try TeardownCommandRunner(ownershipManager: manager).execute(
      homeDirectory: fixture.home,
      dryRun: false,
      json: false
    )
    #expect(!teardown.succeeded)
    #expect(teardown.output.contains("[presets].pi = false"))
    #expect(
      Set(try manager.readRecords(context: context).map(\.id)).isSuperset(of: [
        SetupOwnershipManager.piSelectorID, SetupOwnershipManager.piThemeLinkID,
      ]))

    let partial = try PiFixture(settings: "{}\n")
    defer { try? FileManager.default.removeItem(at: partial.root) }
    try partial.writeLegacyOwnership([
      try partial.legacyPiSelector(contents: PiFixture.legacySelectedSettings)
    ])
    #expect(throws: EnvironmentLifecycleError.self) {
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: partial.state,
        homeDirectory: partial.home
      )
    }
  }

  @Test
  func watchedLinkRefreshRevalidatesSelectionAndSeamUnderActivationLock() async throws {
    let fixture = try PiFixture(settings: "{\"theme\": \"macarchy-current\"}\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.themeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.themeLink,
      withDestinationURL: fixture.themeDestination
    )
    let selected = Mutex(false)
    let before = try fixture.linkDestination()
    let adapter = PiAdapter(
      root: fixture.state,
      configurationDirectoryURL: fixture.settings.deletingLastPathComponent(),
      executableURL: PiAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        return ProcessResult(terminationStatus: 0, output: PiAdapter.minimumVersion)
      },
      selectionIsApplied: { selected.withLock { $0 } }
    )

    await #expect(throws: PiAdapterError.self) { try await adapter.reconciliation().run() }
    #expect(try fixture.linkDestination() == before)

    let wrongDestination = fixture.state.appending(path: "wrong-pi-theme.json")
    let seamChanged = Mutex(false)
    let seamRacingAdapter = PiAdapter(
      root: fixture.state,
      configurationDirectoryURL: fixture.settings.deletingLastPathComponent(),
      executableURL: PiAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        #expect(request.arguments == ["--version"])
        if seamChanged.withLock({ changed in
          guard !changed else { return false }
          changed = true
          return true
        }) {
          try FileManager.default.removeItem(at: fixture.themeLink)
          try FileManager.default.createSymbolicLink(
            at: fixture.themeLink,
            withDestinationURL: wrongDestination
          )
        }
        return ProcessResult(terminationStatus: 0, output: PiAdapter.minimumVersion)
      },
      selectionIsApplied: { true }
    )

    let outcome = try await seamRacingAdapter.reconciliation().run()
    #expect(outcome.status == .drifted)
    #expect(try fixture.linkDestination() == wrongDestination.path)
  }
}

enum ExternalPiLayout: Sendable {
  case configurationSymlink
  case directorySymlink
}

enum OwnedPiLink: Sendable {
  case environment
  case legacySetup
}

private struct PiFixture: LegacySetupOwnershipFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL
  let settings: URL
  let themeLink: URL
  let themeDestination: URL

  init(settings contents: String?) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-pi-preset-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = root.appending(path: "profile.toml")
    settings = home.appending(path: ".pi/agent/settings.json")
    themeLink = home.appending(path: ".pi/agent/themes/\(PiAdapter.themeName).json")
    themeDestination = state.appending(path: "current/\(PiAdapter.outputPath)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    if let contents {
      try FileManager.default.createDirectory(
        at: settings.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: settings, atomically: true, encoding: .utf8)
    }
    try activateCatppuccinMocha(stateRoot: state)
    try writeProfile(pi: true)
  }

  var externalAgent: URL {
    root.appending(path: "dotfiles/pi-agent", directoryHint: .isDirectory)
  }

  var externalSettings: URL { externalAgent.appending(path: "settings.json") }

  func writeProfile(pi: Bool) throws {
    try presetTestProfile(presets: ["pi": pi, "tuicr": false])
      .write(to: profile, atomically: true, encoding: .utf8)
  }

  private var lifecycle: PresetLifecycleTestHarness {
    PresetLifecycleTestHarness(profile: profile, state: state, home: home)
  }

  func plan() throws -> (output: String, succeeded: Bool) {
    try lifecycle.plan()
  }

  func apply(
    adopt: String? = nil,
    prerequisites: EnvironmentPrerequisiteInspector = .assumed,
    theme: DesktopThemeController? = nil,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
  ) async throws -> (output: String, succeeded: Bool) {
    try await lifecycle.apply(
      runner: EnvironmentApplyCommandRunner(
        prerequisites: prerequisites,
        theme: theme ?? themeController,
        verifier: .assumed,
        transactionFaultInjector: faultInjector
      ),
      consumerPaths: consumerPaths,
      adopt: adopt
    )
  }

  func teardown() async throws -> (output: String, succeeded: Bool) {
    try await lifecycle.teardown(consumerPaths: testConsumerPaths())
  }

  func status() throws -> (output: String, succeeded: Bool) {
    try lifecycle.status(
      runner: EnvironmentStatusCommandRunner(
        prerequisites: .assumed,
        theme: themeController
      ),
      consumerPaths: consumerPaths
    )
  }

  func doctor() throws -> (output: String, succeeded: Bool) {
    try EnvironmentDoctorCommandRunner(
      status: EnvironmentStatusCommandRunner(
        prerequisites: .assumed,
        theme: themeController,
        verifier: .assumed
      )
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      json: true
    )
  }

  func installExternalTuple(layout: ExternalPiLayout) throws {
    try FileManager.default.createDirectory(
      at: externalAgent.appending(path: "themes", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try "{\"theme\": \"macarchy-current\", \"private\": true}\n".write(
      to: externalSettings,
      atomically: true,
      encoding: .utf8
    )
    let externalTheme = externalAgent.appending(path: "themes/\(themeLink.lastPathComponent)")
    switch layout {
    case .configurationSymlink:
      try FileManager.default.createDirectory(
        at: themeLink.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(
        atPath: settings.path,
        withDestinationPath: "../../../dotfiles/pi-agent/settings.json"
      )
    case .directorySymlink:
      try FileManager.default.createDirectory(
        at: settings.deletingLastPathComponent().deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(
        atPath: settings.deletingLastPathComponent().path,
        withDestinationPath: "../../dotfiles/pi-agent"
      )
    }
    try FileManager.default.createSymbolicLink(
      at: layout == .configurationSymlink ? themeLink : externalTheme,
      withDestinationURL: themeDestination
    )
  }

  /// The `{}` settings after an older release's setup added the exact selector.
  static let legacySelectedSettings = "{\"theme\": \"macarchy-current\"}\n"

  func installLegacyTuple() throws {
    try writeLegacyOwnership([
      try legacyThemeLink(SetupOwnershipManager.piThemeLinkID),
      try legacyPiSelector(contents: Self.legacySelectedSettings),
    ])
  }

  func externalTupleSnapshot() throws -> ExternalTupleSnapshot {
    try ExternalTupleSnapshot([
      settings.deletingLastPathComponent(),
      settings,
      themeLink,
      externalAgent,
      externalSettings,
      externalAgent.appending(path: "themes", directoryHint: .isDirectory),
      externalAgent.appending(path: "themes/\(themeLink.lastPathComponent)"),
    ])
  }

  func linkDestination(_ url: URL? = nil) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: (url ?? themeLink).path)
  }

  func themeLinkInode() throws -> UInt64 {
    var metadata = stat()
    guard lstat(themeLink.path, &metadata) == 0 else {
      throw EnvironmentLifecycleError.system("inspect Pi theme link", themeLink, errno)
    }
    return UInt64(metadata.st_ino)
  }

  var managedConsumerPaths: ThemeConsumerPaths {
    consumerPaths.managedEnvironmentPaths(stateRoot: state, homeDirectory: home)
  }

  func reconcilePi() async throws -> DesktopThemeReconciliation {
    try await realThemeController.reconcile([PiAdapter.id], state, managedConsumerPaths)
  }

  var realThemeController: DesktopThemeController {
    DesktopThemeController(
      reconcile: { adapterIDs, stateRoot, consumerPaths in
        let coordinator = try Self.realCoordinator(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths
        )
        let result = try await coordinator.reconcile(adapterIDs: adapterIDs)
        let selected = Set(adapterIDs)
        let results = result.record.results.filter { selected.contains($0.adapterID) }
        return DesktopThemeReconciliation(
          generationID: result.manifest.generationID,
          results: results.map {
            DesktopThemeAdapterStatus(
              adapterID: $0.adapterID,
              requirement: $0.requirement.rawValue,
              status: $0.status.rawValue,
              message: $0.message
            )
          },
          succeeded: !hasRequiredReconciliationFailure(results)
        )
      },
      inspect: { adapterIDs, stateRoot, consumerPaths in
        try Self.realCoordinator(stateRoot: stateRoot, consumerPaths: consumerPaths)
          .inspectAdapters(adapterIDs, includeRuntimeChecks: true).map {
            DesktopThemeAdapterStatus(
              adapterID: $0.adapterID,
              requirement: $0.requirement.rawValue,
              status: $0.status.rawValue,
              message: $0.message
            )
          }
      }
    )
  }

  private var consumerPaths: ThemeConsumerPaths {
    let paths = testConsumerPaths()
    return ThemeConsumerPaths(
      kittyConfigurationURL: paths.kittyConfigurationURL,
      sketchyBarConfigurationURL: paths.sketchyBarConfigurationURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      ezaConfigurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      batConfigurationDirectoryURL: paths.batConfigurationDirectoryURL,
      batCacheDirectoryURL: paths.batCacheDirectoryURL,
      btopConfigurationDirectoryURL: paths.btopConfigurationDirectoryURL,
      yaziConfigurationDirectoryURL: paths.yaziConfigurationDirectoryURL,
      atuinConfigurationDirectoryURL: paths.atuinConfigurationDirectoryURL,
      neovimConfigurationDirectoryURL: paths.neovimConfigurationDirectoryURL,
      starshipConfigurationURL: paths.starshipConfigurationURL,
      starshipBehaviorURL: paths.starshipBehaviorURL,
      piConfigurationDirectoryURL: settings.deletingLastPathComponent(),
      herdrConfigurationURL: paths.herdrConfigurationURL,
      tuicrConfigurationDirectoryURL: paths.tuicrConfigurationDirectoryURL,
      codexConfigurationDirectoryURL: paths.codexConfigurationDirectoryURL,
      spicetifyConfigurationDirectoryURL: paths.spicetifyConfigurationDirectoryURL
    )
  }

  private static func realCoordinator(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> ThemeActivationCoordinator {
    let enabled = try ThemeRuntimeSelection.enabledAdapterIDs(
      stateRoot: stateRoot,
      consumerPaths: consumerPaths
    )
    return ThemeActivationCoordinator(
      root: stateRoot,
      consumerPaths: consumerPaths,
      processRunner: ProcessRunner { request in
        #expect(request.executableURL == PiAdapter.liveExecutableURL)
        #expect(request.arguments == ["--version"])
        return ProcessResult(terminationStatus: 0, output: "0.84.4")
      },
      wallpaperControl: WallpaperControl(inspect: { [] }, set: { _, _ in }),
      wallpaperSignal: YabaiWallpaperSignal(
        configurationURL: stateRoot.appending(path: "unused-yabairc"),
        macarchyExecutableURL: stateRoot.appending(path: "unused-macarchy"),
        yabaiExecutableURL: stateRoot.appending(path: "unused-yabai")
      ),
      controlIsAvailable: { $0 == PiAdapter.liveExecutableURL },
      enabledAdapterIDs: enabled,
      piSelectionIsApplied: {
        try ThemeRuntimeSelection.piIsEnabled(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths
        )
      },
      piThemeLinkRefreshIsAllowed: {
        try ThemeRuntimeSelection.piThemeLinkRefreshIsAllowed(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths
        )
      }
    )
  }

  private var themeController: DesktopThemeController {
    stubThemeController(
      reconciled: ("applied", "Running Pi sessions reloaded the active palette"),
      inspected: ("ready", "Pi watches the active palette"))
  }

  var restartRequiredThemeController: DesktopThemeController {
    DesktopThemeController(
      reconcile: { adapterIDs, _, _ in
        DesktopThemeReconciliation(
          generationID: "theme",
          results: adapterIDs.map {
            DesktopThemeAdapterStatus(
              adapterID: $0,
              requirement: "required",
              status: "restart_required",
              message:
                "Pi's externally owned watched theme link was preserved; existing sessions need /reload or a new launch to use the active palette"
            )
          },
          succeeded: true
        )
      },
      inspect: { _, _, _ in [] }
    )
  }
}

extension PiFixture: PresetFileFixture {
  var presetFile: URL { settings }

  var themeLinks: [(link: URL, destination: URL)] { [(themeLink, themeDestination)] }

  func setPresetEnabled(_ enabled: Bool) throws {
    try writeProfile(pi: enabled)
  }

  func applyPreset(
    adopt: String?,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void
  ) async throws -> (output: String, succeeded: Bool) {
    try await apply(adopt: adopt, faultInjector: faultInjector)
  }
}

/// The Pi fixture activates its theme on creation.
func makePiPresetFileFixture(settings: String?) throws -> any PresetFileFixture {
  try PiFixture(settings: settings)
}
