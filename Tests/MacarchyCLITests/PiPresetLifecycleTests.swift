import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PiPresetLifecycleTests {
  @Test
  func cleanEnableNoOpDisableAndLaterSettingsPreservation() async throws {
    let fixture = try PiFixture(settings: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let plan = try fixture.plan()
    #expect(plan.succeeded)
    #expect(try await fixture.apply().succeeded)
    #expect(
      try String(contentsOf: fixture.settings, encoding: .utf8)
        == "{\"theme\": \"macarchy-current\"}\n")
    #expect(try fixture.linkDestination() == fixture.themeDestination.path)
    #expect(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?
        .enabledThemeAdapterIDs == [PiAdapter.id]
    )
    #expect(try fixture.status().succeeded)
    #expect(try fixture.doctor().succeeded)
    #expect(try jsonObject((try await fixture.apply()).output)["outcome"] as? String == "no_change")

    try "{\"theme\": \"macarchy-current\", \"lastModel\": \"private-value\"}\n".write(
      to: fixture.settings,
      atomically: true,
      encoding: .utf8
    )
    #expect(try fixture.teardown().succeeded)
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

    let clean = try PiFixture(settings: nil)
    defer { try? FileManager.default.removeItem(at: clean.root) }
    #expect(try await clean.apply().succeeded)
    try clean.writeProfile(pi: false)
    #expect(try await clean.apply().succeeded)
    #expect(!FileManager.default.fileExists(atPath: clean.settings.path))
    #expect(!FileManager.default.fileExists(atPath: clean.home.appending(path: ".pi").path))
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

  @Test
  func interruptedAuthorityPublicationRollsBackAndForwardRecovers() async throws {
    let fixture = try PiFixture(settings: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let captured = Mutex<EnvironmentTransaction?>(nil)
    let result = try await fixture.apply { checkpoint in
      guard checkpoint == .authorityPublished else { return }
      captured.withLock {
        $0 = try? EnvironmentStateStore(stateRoot: fixture.state).readTransaction()
      }
      throw PiFixtureError.injected
    }
    #expect(!result.succeeded)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.settings.path))

    try EnvironmentStateStore(stateRoot: fixture.state).writeTransaction(
      try #require(captured.withLock { $0 })
    )
    #expect(
      try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home,
        stateRoot: fixture.state
      ).recoverLocked()
    )
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.piEnabled == true)
    #expect(
      try EnvironmentPiDocument.matchesManaged(
        Data(contentsOf: fixture.settings), source: fixture.settings))
    #expect(try fixture.teardown().succeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.settings.path))
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
    #expect(try fixture.teardown().succeeded)
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
  func driftBlocksMutationAndInterruptedTeardownRecoversExactMemberAndLink() async throws {
    let fixture = try PiFixture(settings: "{\"theme\":\"personal\",\"keep\":true}\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)

    try "{\"theme\":\"wrong\",\"later\":1}\n".write(
      to: fixture.settings,
      atomically: true,
      encoding: .utf8
    )
    #expect(try !fixture.status().succeeded)
    #expect(try !fixture.teardown().succeeded)
    #expect(try fixture.linkDestination() == fixture.themeDestination.path)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)

    try "{\"later\":1,\"theme\":\"macarchy-current\"}\n".write(
      to: fixture.settings,
      atomically: true,
      encoding: .utf8
    )
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let ownership = try #require(try store.readOwnership())
    try store.writeTransaction(
      EnvironmentTransaction(
        operation: .teardown,
        previousOwnership: ownership,
        proposedOwnership: nil,
        previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: fixture.state)
          .currentDestination(),
        piReplacementName: ".macarchy-environment-pi-recovery.replacement"
      )
    )

    #expect(
      try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home,
        stateRoot: fixture.state
      ).recoverLocked()
    )
    #expect(
      try String(contentsOf: fixture.settings, encoding: .utf8)
        == "{\"later\":1,\"theme\":\"personal\"}\n"
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.themeLink.path))
    #expect(try store.readOwnership() == nil)
    #expect(!store.transactionExists)
  }

  @Test
  func completeLegacyTupleStaysActiveAndSetupTeardownCannotBreakAppliedAuthority() async throws {
    let fixture = try PiFixture(settings: "{}\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    try FileManager.default.createDirectory(
      at: fixture.themeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var records = [SetupOwnershipRecord]()
    let manager = SetupOwnershipManager()
    _ = try manager.setupPiThemeLink(context: context, dryRun: false, records: &records)
    _ = try manager.setupPiSelector(context: context, dryRun: false, records: &records)
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
    let partialContext = SetupOwnershipManager.Context(homeDirectory: partial.home)
    var partialRecords = [SetupOwnershipRecord]()
    _ = try manager.setupPiSelector(
      context: partialContext,
      dryRun: false,
      records: &partialRecords
    )
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

private enum PiFixtureError: Error { case injected }

enum ExternalPiLayout: Sendable {
  case configurationSymlink
  case directorySymlink
}

enum OwnedPiLink: Sendable {
  case environment
  case legacySetup
}

private struct ExternalPiSnapshot: Equatable {
  struct Entry: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64
    let userID: UInt32
    let groupID: UInt32
    let flags: UInt32
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64
    let statusChangeTimeSeconds: Int64
    let statusChangeTimeNanoseconds: Int64
    let linkDestination: String?
    let data: Data?
  }

  let entries: [String: Entry]
}

private struct PiFixture {
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
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")
    )
    _ = try ThemeActivator(root: state).activate(package: package)
    try writeProfile(pi: true)
  }

  var externalAgent: URL {
    root.appending(path: "dotfiles/pi-agent", directoryHint: .isDirectory)
  }

  var externalSettings: URL { externalAgent.appending(path: "settings.json") }

  func writeProfile(pi: Bool) throws {
    try """
    schema_version = 1
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
    pi = \(pi)
    tuicr = false
    """.write(to: profile, atomically: true, encoding: .utf8)
  }

  func plan() throws -> (output: String, succeeded: Bool) {
    try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
  }

  func apply(
    adopt: String? = nil,
    prerequisites: EnvironmentPrerequisiteInspector = .assumed,
    theme: DesktopThemeController? = nil,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
  ) async throws -> (output: String, succeeded: Bool) {
    try await EnvironmentApplyCommandRunner(
      prerequisites: prerequisites,
      theme: theme ?? themeController,
      verifier: .assumed,
      transactionFaultInjector: faultInjector
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      adopt: adopt,
      json: true
    )
  }

  func teardown() throws -> (output: String, succeeded: Bool) {
    try EnvironmentTeardownCommandRunner().execute(
      stateRoot: state,
      homeDirectory: home,
      dryRun: false,
      json: true
    )
  }

  func status() throws -> (output: String, succeeded: Bool) {
    try EnvironmentStatusCommandRunner(
      prerequisites: .assumed,
      theme: themeController
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

  func installLegacyTuple() throws {
    try FileManager.default.createDirectory(
      at: themeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var records = [SetupOwnershipRecord]()
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: home)
    _ = try manager.setupPiThemeLink(context: context, dryRun: false, records: &records)
    _ = try manager.setupPiSelector(context: context, dryRun: false, records: &records)
  }

  func externalTupleSnapshot() throws -> ExternalPiSnapshot {
    let paths = [
      settings.deletingLastPathComponent(),
      settings,
      themeLink,
      externalAgent,
      externalSettings,
      externalAgent.appending(path: "themes", directoryHint: .isDirectory),
      externalAgent.appending(path: "themes/\(themeLink.lastPathComponent)"),
    ]
    var entries = [String: ExternalPiSnapshot.Entry]()
    for path in paths {
      var metadata = stat()
      guard lstat(path.path, &metadata) == 0 else {
        if errno == ENOENT { continue }
        throw EnvironmentLifecycleError.system("snapshot external Pi tuple", path, errno)
      }
      let kind = metadata.st_mode & S_IFMT
      entries[path.path] = ExternalPiSnapshot.Entry(
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        mode: UInt32(metadata.st_mode),
        size: Int64(metadata.st_size),
        userID: metadata.st_uid,
        groupID: metadata.st_gid,
        flags: metadata.st_flags,
        modificationTimeSeconds: Int64(metadata.st_mtimespec.tv_sec),
        modificationTimeNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
        statusChangeTimeSeconds: Int64(metadata.st_ctimespec.tv_sec),
        statusChangeTimeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
        linkDestination: kind == S_IFLNK
          ? try FileManager.default.destinationOfSymbolicLink(atPath: path.path) : nil,
        data: kind == S_IFREG ? try BoundedRegularFile.read(at: path).data : nil
      )
    }
    return ExternalPiSnapshot(entries: entries)
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
    DesktopThemeController(
      reconcile: { adapterIDs, _, _ in
        DesktopThemeReconciliation(
          generationID: "theme",
          results: adapterIDs.map {
            DesktopThemeAdapterStatus(
              adapterID: $0,
              requirement: "required",
              status: "applied",
              message: "Running Pi sessions reloaded the active palette"
            )
          },
          succeeded: true
        )
      },
      inspect: { adapterIDs, _, _ in
        adapterIDs.map {
          DesktopThemeAdapterStatus(
            adapterID: $0,
            requirement: "required",
            status: "ready",
            message: "Pi watches the active palette"
          )
        }
      }
    )
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
