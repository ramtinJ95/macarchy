import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentLifecycleTests {
  @Test
  func managedConsumerPathsResolveTheOwnedShellLink() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-environment-consumer-paths-(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    let generated = state.appending(path: "environment/current/zsh/.zshrc")
    try FileManager.default.createDirectory(
      at: generated.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "export MACARCHY_MANAGED_SESSION=1\n".write(
      to: generated,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: ".zshrc"),
      withDestinationURL: generated
    )

    let paths = testConsumerPaths().managedEnvironmentPaths(
      stateRoot: state,
      homeDirectory: home
    )

    #expect(paths.shellConfigurationURL == generated)
  }

  @Test
  func aggregateAdoptionApplyRepeatAndTeardownRestoreExactEntries() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let adapterDirectory = fixture.state.appending(path: "state/adapters")
    let kittyBridge = adapterDirectory.appending(path: "kitty.conf")
    let starshipBridge = adapterDirectory.appending(path: "starship.toml")
    try FileManager.default.createDirectory(at: adapterDirectory, withIntermediateDirectories: true)
    try "original kitty\n".write(to: kittyBridge, atomically: true, encoding: .utf8)
    try "original starship\n".write(to: starshipBridge, atomically: true, encoding: .utf8)
    let originalEntries = try fixture.entryEvidence()

    let plan = try fixture.plan()
    let planReport = try jsonObject(plan.output)
    let digest = try #require(planReport["adoption_evidence_digest"] as? String)
    #expect(plan.succeeded)
    #expect(
      (planReport["entries"] as? [[String: Any]])?.filter {
        $0["status"] as? String == "adoption_required"
      }.count == 4
    )
    #expect(
      (planReport["entries"] as? [[String: Any]])?.filter {
        $0["status"] as? String == "adoption_required" && $0["evidence"] != nil
      }.count == 4
    )

    let apply = try await fixture.apply(adopt: digest)
    let applyReport = try jsonObject(apply.output)
    #expect(apply.succeeded)
    #expect(applyReport["outcome"] as? String == "applied")
    #expect(try fixture.isManaged())
    #expect(try String(contentsOf: fixture.atuinHistory, encoding: .utf8) == "history\n")

    let repeatApply = try await fixture.apply(adopt: nil)
    let repeatReport = try jsonObject(repeatApply.output)
    #expect(repeatApply.succeeded)
    #expect(repeatReport["outcome"] as? String == "no_change")
    try "managed kitty\n".write(to: kittyBridge, atomically: true, encoding: .utf8)
    try "managed starship\n".write(to: starshipBridge, atomically: true, encoding: .utf8)

    let status = try fixture.status()
    #expect(status.succeeded)
    #expect(try jsonObject(status.output)["outcome"] as? String == "converged")

    let teardown = try fixture.teardown()
    #expect(teardown.succeeded)
    #expect(try fixture.entryEvidence() == originalEntries)
    #expect(try String(contentsOf: fixture.atuinHistory, encoding: .utf8) == "history\n")
    #expect(try String(contentsOf: kittyBridge, encoding: .utf8) == "original kitty\n")
    #expect(try String(contentsOf: starshipBridge, encoding: .utf8) == "original starship\n")
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appending(path: "environment/current").path))
  }

  @Test
  func btopAdoptionRestoresOwnedKeysAndPreservesLaterProviderChanges() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configuration = fixture.home.appending(path: ".config/btop/btop.conf")
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    # Personal btop settings
    color_theme = "personal" # keep this comment
    update_ms = 2500
    custom_graph_symbol = "braille"
    """.write(to: configuration, atomically: true, encoding: .utf8)

    let plan = try fixture.plan()
    let report = try jsonObject(plan.output)
    let digest = try #require(report["adoption_evidence_digest"] as? String)
    let entries = try #require(report["entries"] as? [[String: Any]])
    #expect(plan.succeeded)
    #expect(
      entries.contains {
        $0["id"] as? String == "btop_configuration"
          && $0["status"] as? String == "adoption_required"
      }
    )

    #expect(try await fixture.apply(adopt: digest).succeeded)
    var managed = try String(contentsOf: configuration, encoding: .utf8)
    managed = managed.replacingOccurrences(
      of: "custom_graph_symbol = \"braille\"",
      with: "custom_graph_symbol = \"block\""
    )
    try managed.write(to: configuration, atomically: true, encoding: .utf8)
    #expect(try await fixture.apply(adopt: nil).succeeded)
    #expect(try fixture.status().succeeded)
    #expect(try fixture.teardown().succeeded)

    let restored = try String(contentsOf: configuration, encoding: .utf8)
    #expect(
      restored
        == """
        # Personal btop settings
        color_theme = "personal" # keep this comment
        update_ms = 2500
        custom_graph_symbol = "block"
        """
    )
  }

  @Test
  func btopTeardownReleasesProviderStateAddedAfterCleanInstall() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configuration = fixture.home.appending(path: ".config/btop/btop.conf")

    #expect(try await fixture.apply(adopt: nil).succeeded)
    var providerState = try String(contentsOf: configuration, encoding: .utf8)
    providerState += "custom_graph_symbol = \"block\"\n"
    try providerState.write(to: configuration, atomically: true, encoding: .utf8)

    #expect(try fixture.teardown().succeeded)
    let released = try String(contentsOf: configuration, encoding: .utf8)
    #expect(released == "custom_graph_symbol = \"block\"\n")
  }

  @Test
  func staleAggregateEvidenceBlocksBeforeAnyProviderEntryChanges() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    try FileManager.default.removeItem(at: fixture.zshEntry)
    try symlink("changed-zshrc", fixture.zshEntry.path).requireZero()

    let apply = try await fixture.apply(adopt: digest)

    #expect(!apply.succeeded)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.zshEntry.path)
        == "changed-zshrc")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.kittyEntry.path)
        == fixture.kittyTarget)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
  }

  @Test
  func newlyCreatedEntryBlocksBeforeAnyProviderMutation() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try fixture.plan().succeeded)
    try "external\n".write(to: fixture.zshEntry, atomically: true, encoding: .utf8)

    let apply = try await fixture.apply(adopt: nil)

    #expect(!apply.succeeded)
    #expect(try String(contentsOf: fixture.zshEntry, encoding: .utf8) == "external\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.kittyEntry.path))
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
  }

  @Test
  func providerEvidenceExcludesPathVolatileProvenanceMetadata() throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let inspector = EnvironmentProviderInspector()
    let before = try inspector.capture(fixture.kittyEntry, kittyDirectory: true)
    let provenance = Data("volatile provenance".utf8)
    let written = provenance.withUnsafeBytes { bytes in
      fixture.kittyEntry.path.withCString { path in
        "com.apple.provenance".withCString { name in
          Darwin.setxattr(
            path,
            name,
            bytes.baseAddress,
            provenance.count,
            0,
            XATTR_NOFOLLOW
          )
        }
      }
    }
    try written.requireZero()

    let after = try inspector.capture(fixture.kittyEntry, kittyDirectory: true)

    #expect(after == before)
  }

  @Test
  func driftInOneOwnedEntryBlocksAllTeardownMutation() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    try FileManager.default.removeItem(at: fixture.zshEntry)
    try "drift\n".write(to: fixture.zshEntry, atomically: true, encoding: .utf8)

    let teardown = try fixture.teardown()

    #expect(!teardown.succeeded)
    #expect(FileManager.default.fileExists(atPath: fixture.kittyEntry.path))
    #expect(try String(contentsOf: fixture.zshEntry, encoding: .utf8) == "drift\n")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.atuinConfigEntry.path)
        != fixture.atuinTarget)
  }

  @Test
  func entirelyDisabledProfileDoesNotRequirePackagesOrCreateGeneration() async throws {
    let fixture = try EnvironmentLifecycleFixture(disabled: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let plan = try fixture.plan()
    let apply = try await fixture.apply(adopt: nil)
    let report = try jsonObject(apply.output)

    #expect(plan.succeeded)
    #expect(apply.succeeded)
    #expect(report["outcome"] as? String == "no_change")
    #expect((report["prerequisites"] as? [Any])?.isEmpty == true)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.state.appending(path: "environment").path))
  }

  @Test
  func cleanApplyAndTeardownLeaveNoProviderConfigurationResidue() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let apply = try await fixture.apply(adopt: nil)
    #expect(apply.succeeded)
    #expect(
      FileManager.default.fileExists(atPath: fixture.home.appending(path: ".config/atuin").path))
    let teardown = try fixture.teardown()
    #expect(teardown.succeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.kittyEntry.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.zshEntry.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.starshipEntry.path))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.home.appending(path: ".config/atuin").path))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.home.appending(path: ".config/bat").path))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.home.appending(path: ".config/btop").path))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.home.appending(path: ".config/eza").path))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.home.appending(path: ".config/yazi").path))
  }

  @Test
  func interruptedApplyIsForwardRecoveredBeforeRetry() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    let profile = try PortableProfileLoader().load(at: fixture.profile, required: true)
    let composition = try EnvironmentConfigurationComposer().compose(
      resourcesRoot: repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory),
      profile: profile,
      stateRoot: fixture.state
    )
    let inspection = EnvironmentProviderInspector().inspect(
      composition: composition,
      homeDirectory: fixture.home,
      stateRoot: fixture.state
    )
    _ = try ActivationLock(root: fixture.state).withLock {
      try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home,
        stateRoot: fixture.state
      ).applyLocked(
        composition: composition,
        inspection: inspection,
        adoptionDigest: digest,
        themeBridges: try EnvironmentThemeBridgeState.capture(
          profile: profile.environment,
          stateRoot: fixture.state
        )
      )
    }
    #expect(EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(nil)

    let recovery = try await fixture.apply(adopt: nil)

    #expect(!recovery.succeeded)
    #expect(recovery.output.contains("recovered"))
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(try fixture.isManaged())
    #expect(try await fixture.apply(adopt: nil).succeeded)
  }

  @Test
  func interruptedTeardownIsForwardRecoveredExactly() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalEntries = try fixture.entryEvidence()
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let ownership = try #require(try store.readOwnership())
    try store.writeTransaction(
      EnvironmentTransaction(
        operation: .teardown,
        previousOwnership: ownership,
        proposedOwnership: nil,
        previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: fixture.state)
          .currentDestination(),
        btopReplacementName: ".macarchy-environment-btop-test.replacement"
      )
    )

    let preview = try fixture.teardown(dryRun: true)

    #expect(!preview.succeeded)
    #expect(store.transactionExists)
    #expect(try fixture.isManaged())

    let teardown = try fixture.teardown()

    #expect(teardown.succeeded)
    #expect(try fixture.entryEvidence() == originalEntries)
    #expect(!store.transactionExists)
  }

  @Test
  func interruptedKittyRemovalIsForwardRecoveredExactly() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalEntries = try fixture.entryEvidence()
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let ownership = try #require(try store.readOwnership())
    try store.writeTransaction(
      EnvironmentTransaction(
        operation: .teardown,
        previousOwnership: ownership,
        proposedOwnership: nil,
        previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: fixture.state)
          .currentDestination(),
        btopReplacementName: ".macarchy-environment-btop-test.replacement"
      )
    )
    try FileManager.default.removeItem(at: fixture.kittyEntry.appending(path: "kitty.conf"))

    let teardown = try fixture.teardown()

    #expect(teardown.succeeded)
    #expect(try fixture.entryEvidence() == originalEntries)
    #expect(!store.transactionExists)
  }

  @Test
  func failedFreshSessionVerificationRollsBackEveryPublishedEntry() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalEntries = try fixture.entryEvidence()
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    let verifier = EnvironmentSessionVerifier(
      { _, _ in
        [EnvironmentVerification(id: "zsh_fresh_session", status: "failed", message: "injected")]
      },
      verifyRestored: { _, _ in
        [
          EnvironmentVerification(
            id: "zsh_fresh_session",
            status: "verified",
            message: "restored"
          )
        ]
      }
    )

    let apply = try await fixture.apply(adopt: digest, verifier: verifier)

    #expect(!apply.succeeded)
    #expect(try fixture.entryEvidence() == originalEntries)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(apply.output.contains("Environment apply rolled back"))
    #expect(
      try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == nil
    )
  }

  @Test
  func applySupersedesAValidlyAddressedGenerationWithDriftedBytes() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let generationStore = EnvironmentGenerationStore(stateRoot: fixture.state)
    let originalDestination = try #require(try generationStore.currentDestination())
    let zsh = fixture.state.appending(path: "environment/\(originalDestination)/zsh/.zshrc")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: zsh.path
    )
    try "drift\n".write(to: zsh, atomically: false, encoding: .utf8)

    let apply = try await fixture.apply(adopt: nil)

    #expect(apply.succeeded)
    #expect(try generationStore.currentDestination() != originalDestination)
  }

  @Test
  func applySupersedesAValidlyAddressedWritableGeneration() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let generationStore = EnvironmentGenerationStore(stateRoot: fixture.state)
    let originalDestination = try #require(try generationStore.currentDestination())
    let zsh = fixture.state.appending(path: "environment/\(originalDestination)/zsh/.zshrc")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: zsh.path
    )

    let apply = try await fixture.apply(adopt: nil)

    #expect(apply.succeeded)
    #expect(try generationStore.currentDestination() != originalDestination)
  }

  @Test
  func hiddenKittyOverrideDirectoriesAreSealedAndRemainConverged() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let override = fixture.root.appending(path: "kitty-override", directoryHint: .isDirectory)
    let hidden = override.appending(path: ".shared", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try "include .shared/colors.conf\n".write(
      to: override.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    try "foreground #cdd6f4\n".write(
      to: hidden.appending(path: "colors.conf"),
      atomically: true,
      encoding: .utf8
    )
    try "schema_version = 1\n[kitty]\noverride = \"kitty-override\"\n".write(
      to: fixture.profile,
      atomically: true,
      encoding: .utf8
    )
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )

    #expect(try await fixture.apply(adopt: digest).succeeded)
    #expect(try fixture.status().succeeded)
  }

  @Test
  func successfulApplyUsesItsThemeAndSessionObservationsOnce() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let calls = Mutex<[String]>([])
    let theme = DesktopThemeController(
      reconcile: { adapterIDs, _, _ in
        calls.withLock { $0.append("reconcile") }
        return DesktopThemeReconciliation(
          generationID: "g-00000000-0000-0000-0000-000000000000",
          results: adapterIDs.map {
            DesktopThemeAdapterStatus(
              adapterID: $0,
              requirement: "required",
              status: "applied",
              message: nil
            )
          },
          succeeded: true
        )
      },
      inspect: { _, _, _ in
        calls.withLock { $0.append("inspect") }
        return []
      }
    )
    let verifier = EnvironmentSessionVerifier { _, _ in
      calls.withLock { $0.append("verify") }
      return [
        EnvironmentVerification(id: "zsh_fresh_session", status: "verified", message: "verified")
      ]
    }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )

    let apply = try await fixture.apply(adopt: digest, theme: theme, verifier: verifier)

    #expect(apply.succeeded)
    #expect(calls.withLock { $0 } == ["reconcile", "verify"])
    let report = try jsonObject(apply.output)
    #expect((report["theme"] as? [Any])?.count == 7)
    #expect((report["verification"] as? [Any])?.count == 1)
  }

  @Test
  func failedThemeReconciliationRestoresEntriesAndBridgeBytes() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let adapterDirectory = fixture.state.appending(path: "state/adapters")
    let kittyBridge = adapterDirectory.appending(path: "kitty.conf")
    let starshipBridge = adapterDirectory.appending(path: "starship.toml")
    try FileManager.default.createDirectory(at: adapterDirectory, withIntermediateDirectories: true)
    try "original kitty\n".write(to: kittyBridge, atomically: true, encoding: .utf8)
    try "original starship\n".write(to: starshipBridge, atomically: true, encoding: .utf8)
    let originalEntries = try fixture.entryEvidence()
    let theme = DesktopThemeController(
      reconcile: { adapterIDs, _, _ in
        try "changed kitty\n".write(to: kittyBridge, atomically: true, encoding: .utf8)
        try "changed starship\n".write(to: starshipBridge, atomically: true, encoding: .utf8)
        return DesktopThemeReconciliation(
          generationID: "g-00000000-0000-0000-0000-000000000000",
          results: adapterIDs.map {
            DesktopThemeAdapterStatus(
              adapterID: $0,
              requirement: "required",
              status: "failed",
              message: "injected"
            )
          },
          succeeded: false
        )
      },
      inspect: { _, _, _ in [] }
    )
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )

    let apply = try await fixture.apply(adopt: digest, theme: theme)

    #expect(!apply.succeeded)
    #expect(try fixture.entryEvidence() == originalEntries)
    #expect(try String(contentsOf: kittyBridge, encoding: .utf8) == "original kitty\n")
    #expect(try String(contentsOf: starshipBridge, encoding: .utf8) == "original starship\n")
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
  }

  @Test
  func rollbackPreservesBridgesFromANewerCanonicalTheme() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let adapterDirectory = fixture.state.appending(path: "state/adapters")
    let kittyBridge = adapterDirectory.appending(path: "kitty.conf")
    let starshipBridge = adapterDirectory.appending(path: "starship.toml")
    try FileManager.default.createDirectory(at: adapterDirectory, withIntermediateDirectories: true)
    try "original kitty\n".write(to: kittyBridge, atomically: true, encoding: .utf8)
    try "original starship\n".write(to: starshipBridge, atomically: true, encoding: .utf8)
    let originalEntries = try fixture.entryEvidence()
    let theme = DesktopThemeController(
      reconcile: { adapterIDs, stateRoot, _ in
        let package = try ThemePackageLoader().load(
          packageURL: repositoryRoot.appending(
            path: "Themes/tokyo-night",
            directoryHint: .isDirectory
          )
        )
        let generation = try ThemeActivator(root: stateRoot).activate(package: package)
        try "newer kitty\n".write(to: kittyBridge, atomically: true, encoding: .utf8)
        try "newer starship\n".write(to: starshipBridge, atomically: true, encoding: .utf8)
        return DesktopThemeReconciliation(
          generationID: generation.generationID,
          results: adapterIDs.map {
            DesktopThemeAdapterStatus(
              adapterID: $0,
              requirement: "required",
              status: "failed",
              message: "injected after newer activation"
            )
          },
          succeeded: false
        )
      },
      inspect: { _, _, _ in [] }
    )
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )

    let apply = try await fixture.apply(adopt: digest, theme: theme)

    #expect(!apply.succeeded)
    #expect(try fixture.entryEvidence() == originalEntries)
    #expect(try String(contentsOf: kittyBridge, encoding: .utf8) == "newer kitty\n")
    #expect(try String(contentsOf: starshipBridge, encoding: .utf8) == "newer starship\n")
  }

  @Test
  func transactionCannotRestoreAThemeBridgeOutsideManagedState() throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let victim = fixture.root.appending(path: "victim")
    try "preserve\n".write(to: victim, atomically: true, encoding: .utf8)
    let proposed = EnvironmentOwnership(
      generationID: "e-00000000-0000-0000-0000-000000000000",
      records: [],
      createdDirectories: [],
      originalThemeBridges: []
    )
    try EnvironmentStateStore(stateRoot: fixture.state).writeTransaction(
      EnvironmentTransaction(
        operation: .apply,
        direction: .rollback,
        previousOwnership: nil,
        proposedOwnership: proposed,
        previousCurrentDestination: nil,
        rollbackThemeBridges: [
          EnvironmentThemeBridgeState.Entry(
            path: victim.path,
            data: Data("overwrite\n".utf8),
            mode: 0o600
          )
        ]
      )
    )

    #expect(throws: (any Error).self) {
      try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home,
        stateRoot: fixture.state
      ).recoverLocked()
    }
    #expect(try String(contentsOf: victim, encoding: .utf8) == "preserve\n")
    #expect(EnvironmentStateStore(stateRoot: fixture.state).transactionExists)

    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.removeTransaction()
    try store.writeTransaction(
      EnvironmentTransaction(
        operation: .apply,
        direction: .rollback,
        previousOwnership: nil,
        proposedOwnership: proposed,
        previousCurrentDestination: nil,
        rollbackThemeBridges: [
          EnvironmentThemeBridgeState.Entry(
            path: fixture.state.appending(path: "state/adapters/kitty.conf").path,
            data: nil,
            mode: 0o600
          )
        ]
      )
    )
    #expect(throws: (any Error).self) {
      try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home,
        stateRoot: fixture.state
      ).recoverLocked()
    }
    #expect(store.transactionExists)
  }

  @Test
  func regularFileAdoptionRestoresItsExactInodeAndMetadata() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.removeItem(at: fixture.zshEntry)
    try "export PERSONAL=regular\n".write(
      to: fixture.zshEntry,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fixture.zshEntry.path
    )
    let originalEntries = try fixture.entryEvidence()
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )

    #expect(try await fixture.apply(adopt: digest).succeeded)
    #expect(try fixture.teardown().succeeded)
    #expect(try fixture.entryEvidence() == originalEntries)
    #expect(
      try String(contentsOf: fixture.zshEntry, encoding: .utf8)
        == "export PERSONAL=regular\n"
    )
  }

  @Test
  func teardownRejectsASelectedGenerationWithoutOwnership() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    try FileManager.default.removeItem(
      at: fixture.state.appending(path: "environment/ownership.json")
    )

    let status = try fixture.status()
    let apply = try await fixture.apply(adopt: nil)
    let teardown = try fixture.teardown()

    #expect(!status.succeeded)
    #expect(!apply.succeeded)
    #expect(!teardown.succeeded)
    #expect(try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() != nil)
    #expect(try fixture.isManaged())
  }

  @Test
  func disablingManagedHistoryRestoresOnlyAtuinEntries() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    try """
    schema_version = 1
    [history]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let apply = try await fixture.apply(adopt: nil)

    #expect(apply.succeeded)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.atuinConfigEntry.path)
        == fixture.atuinTarget)
    #expect(!FileManager.default.fileExists(atPath: fixture.atuinThemeEntry.path))
    #expect(
      try EnvironmentProviderInspector().managedEntryIsExact(
        EnvironmentProviderInspector().allManagedEntries(
          homeDirectory: fixture.home,
          stateRoot: fixture.state
        ).first { $0.id == .kitty }!
      ))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.zshEntry.path)
        != fixture.zshTarget)
  }

  @Test
  func disablingPromptRestoresItsOriginalThemeBridgeOnly() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let adapters = fixture.state.appending(path: "state/adapters")
    let kittyBridge = adapters.appending(path: "kitty.conf")
    let starshipBridge = adapters.appending(path: "starship.toml")
    try FileManager.default.createDirectory(at: adapters, withIntermediateDirectories: true)
    try "original kitty\n".write(to: kittyBridge, atomically: true, encoding: .utf8)
    try "original starship\n".write(to: starshipBridge, atomically: true, encoding: .utf8)
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    try "managed kitty\n".write(to: kittyBridge, atomically: true, encoding: .utf8)
    try "managed starship\n".write(to: starshipBridge, atomically: true, encoding: .utf8)
    try """
    schema_version = 1
    [prompt]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let apply = try await fixture.apply(adopt: nil)

    #expect(apply.succeeded)
    #expect(try String(contentsOf: kittyBridge, encoding: .utf8) == "managed kitty\n")
    #expect(try String(contentsOf: starshipBridge, encoding: .utf8) == "original starship\n")
  }
}

private struct EnvironmentLifecycleFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL
  let kittyEntry: URL
  let zshEntry: URL
  let starshipEntry: URL
  let atuinConfigEntry: URL
  let atuinThemeEntry: URL
  let atuinHistory: URL
  let kittyTarget: String
  let zshTarget: String
  let starshipTarget: String
  let atuinTarget: String

  private let prerequisites = EnvironmentPrerequisiteInspector.assumed

  init(disabled: Bool = false, externalEntries: Bool = true) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-environment-lifecycle-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = root.appending(path: "profile.toml")
    kittyEntry = home.appending(path: ".config/kitty", directoryHint: .isDirectory)
    zshEntry = home.appending(path: ".zshrc")
    starshipEntry = home.appending(path: ".config/starship.toml")
    atuinConfigEntry = home.appending(path: ".config/atuin/config.toml")
    atuinThemeEntry = home.appending(path: ".config/atuin/themes/macarchy-current.toml")
    atuinHistory = home.appending(path: ".config/atuin/history.db")
    kittyTarget = "../../dotfiles/kitty"
    zshTarget = "../dotfiles/zshrc"
    starshipTarget = "../../dotfiles/starship.toml"
    atuinTarget = "../../../dotfiles/atuin.toml"

    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    if disabled {
      try """
      schema_version = 1
      [terminal]
      provider = "disabled"
      [shell]
      provider = "disabled"
      [tools]
      bat = false
      eza = false
      btop = false
      yazi = false
      """.write(to: profile, atomically: true, encoding: .utf8)
      return
    }

    if !externalEntries {
      try "schema_version = 1\n".write(to: profile, atomically: true, encoding: .utf8)
      return
    }

    let dotfiles = root.appending(path: "dotfiles", directoryHint: .isDirectory)
    let kitty = dotfiles.appending(path: "kitty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: kitty, withIntermediateDirectories: true)
    try "font_size 12\n".write(
      to: kitty.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    try "export PERSONAL=1\n".write(
      to: dotfiles.appending(path: "zshrc"),
      atomically: true,
      encoding: .utf8
    )
    try "format = \"$directory\"\n".write(
      to: dotfiles.appending(path: "starship.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "search_mode = \"fuzzy\"\n".write(
      to: dotfiles.appending(path: "atuin.toml"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createDirectory(
      at: home.appending(path: ".config/atuin/themes"),
      withIntermediateDirectories: true
    )
    try "history\n".write(to: atuinHistory, atomically: true, encoding: .utf8)
    try symlink(kittyTarget, kittyEntry.path).requireZero()
    try symlink(zshTarget, zshEntry.path).requireZero()
    try symlink(starshipTarget, starshipEntry.path).requireZero()
    try symlink(atuinTarget, atuinConfigEntry.path).requireZero()
    try "schema_version = 1\n".write(to: profile, atomically: true, encoding: .utf8)
  }

  func plan() throws -> (output: String, succeeded: Bool) {
    try EnvironmentPlanCommandRunner(prerequisites: prerequisites).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
  }

  func apply(
    adopt: String?,
    theme: DesktopThemeController? = nil,
    verifier: EnvironmentSessionVerifier = .assumed
  ) async throws -> (output: String, succeeded: Bool) {
    try await EnvironmentApplyCommandRunner(
      prerequisites: prerequisites,
      theme: theme,
      verifier: verifier
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: testConsumerPaths(),
      adopt: adopt,
      json: true
    )
  }

  func status() throws -> (output: String, succeeded: Bool) {
    try EnvironmentStatusCommandRunner(
      prerequisites: prerequisites,
      theme: nil
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: testConsumerPaths(),
      json: true
    )
  }

  func teardown(dryRun: Bool = false) throws -> (output: String, succeeded: Bool) {
    try EnvironmentTeardownCommandRunner().execute(
      stateRoot: state,
      homeDirectory: home,
      dryRun: dryRun,
      json: true
    )
  }

  func isManaged() throws -> Bool {
    let inspector = EnvironmentProviderInspector()
    let profile = try PortableProfileLoader().load(at: profile, required: true)
    let staticEntries = try inspector.desiredEntries(
      profile: profile.environment,
      homeDirectory: home,
      stateRoot: state
    ).allSatisfy { try inspector.managedEntryIsExact($0) }
    let btop = home.appending(path: ".config/btop/btop.conf")
    let generation = try #require(
      try EnvironmentGenerationStore(stateRoot: state).currentManifest()
    )
    let expected = try EnvironmentBtopFileTransaction(
      homeDirectory: home,
      stateRoot: state
    ).generationState(generation.generationID)
    let actual = try String(contentsOf: btop, encoding: .utf8)
    let btopManaged = try EnvironmentBtopDocument.matchesManaged(
      actual,
      values: expected.values,
      source: btop
    )
    return staticEntries && btopManaged
  }

  func entryEvidence() throws -> [EnvironmentEntryID: EnvironmentEntryEvidence] {
    let inspector = EnvironmentProviderInspector()
    return [
      .kitty: try inspector.capture(kittyEntry, kittyDirectory: true),
      .zsh: try inspector.capture(zshEntry, kittyDirectory: false),
      .starship: try inspector.capture(starshipEntry, kittyDirectory: false),
      .atuinConfiguration: try inspector.capture(atuinConfigEntry, kittyDirectory: false),
      .atuinTheme: try inspector.capture(atuinThemeEntry, kittyDirectory: false),
      .batConfiguration: try inspector.capture(
        home.appending(path: ".config/bat/config"), kittyDirectory: false),
      .batTheme: try inspector.capture(
        home.appending(path: ".config/bat/themes/Macarchy Current.tmTheme"),
        kittyDirectory: false
      ),
      .btopConfiguration: try inspector.capture(
        home.appending(path: ".config/btop/btop.conf"), kittyDirectory: false),
      .btopTheme: try inspector.capture(
        home.appending(path: ".config/btop/themes/macarchy-current.theme"),
        kittyDirectory: false
      ),
      .ezaTheme: try inspector.capture(
        home.appending(path: ".config/eza/theme.yml"), kittyDirectory: false),
      .yaziConfiguration: try inspector.capture(
        home.appending(path: ".config/yazi/yazi.toml"), kittyDirectory: false),
      .yaziThemeSelection: try inspector.capture(
        home.appending(path: ".config/yazi/theme.toml"), kittyDirectory: false),
      .yaziFlavor: try inspector.capture(
        home.appending(path: ".config/yazi/flavors/macarchy-current.yazi/flavor.toml"),
        kittyDirectory: false
      ),
      .yaziSyntax: try inspector.capture(
        home.appending(path: ".config/yazi/flavors/macarchy-current.yazi/tmtheme.xml"),
        kittyDirectory: false
      ),
    ]
  }

  func activateTheme() throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
    _ = try ThemeActivator(root: state).activate(package: package)
  }
}

extension Int32 {
  fileprivate func requireZero() throws {
    guard self == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
