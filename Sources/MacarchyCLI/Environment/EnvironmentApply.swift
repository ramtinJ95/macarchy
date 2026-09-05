import Darwin
import Foundation
import ThemeCore

struct EnvironmentHerdrRuntimeReloader: Sendable {
  let reload: @Sendable (URL, URL) throws -> String

  static let assumed = Self { _, _ in
    "Herdr runtime activation was assumed by the caller."
  }

  static let live = Self { stateRoot, homeDirectory in
    let result = try HerdrAdapter(
      root: stateRoot,
      configurationURL: homeDirectory.appending(path: ".config/herdr/config.toml"),
      executableURL: HerdrAdapter.executableURL(homeDirectory: homeDirectory),
      controlIsAvailable: { true }
    ).reloadCurrentConfiguration()
    guard result.succeeded else {
      throw EnvironmentLifecycleError.blocked(result.message)
    }
    return result.message
  }
}

struct EnvironmentSpicetifyRuntimeRefresher: Sendable {
  let refresh: @Sendable (URL, URL, Bool) throws -> String

  static let assumed = Self { _, _, _ in
    "Spicetify runtime refresh was assumed by the caller."
  }
  static let live = Self { stateRoot, homeDirectory, clearEvidence in
    try SpicetifyAdapter.live(
      root: stateRoot,
      configurationDirectoryURL: homeDirectory.appending(path: ".config/spicetify")
    ).refreshRestoredConfiguration(clearRuntimeEvidence: clearEvidence).message()
  }
}

private func requiresSpicetifyRuntimePrerequisites(
  stateRoot: URL,
  desiredEnabled: Bool?
) throws -> Bool {
  let store = EnvironmentStateStore(stateRoot: stateRoot)
  if let transaction = try store.readTransaction(),
    transaction.spicetifyRuntimeTarget != nil,
    transaction.spicetifyRuntimeVerified != true
  {
    return true
  }
  guard try store.readOwnership()?.spicetifyEnabled == true else { return false }
  return desiredEnabled != true
}

private func recoverEnvironmentTransaction(
  coordinator: EnvironmentTransactionCoordinator,
  stateRoot: URL,
  homeDirectory: URL,
  runtime: EnvironmentHerdrRuntimeReloader,
  spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher
) throws -> Bool {
  let preparation = try ActivationLock(root: stateRoot).withLock {
    try coordinator.prepareRecoveryLocked()
  }
  guard preparation.recovered else { return false }
  if let target = preparation.runtimeTarget {
    _ = try runtime.reload(stateRoot, homeDirectory)
    try ActivationLock(root: stateRoot).withLock {
      try coordinator.markHerdrRuntimeVerifiedLocked(target)
      _ = try coordinator.prepareRecoveryLocked()
    }
  }
  if preparation.spicetifyRuntimeTarget != nil {
    _ = try verifyPendingSpicetifyRuntime(
      coordinator: coordinator,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      runtime: spicetifyRuntime,
      adapterWasReconciled: false
    )
    try ActivationLock(root: stateRoot).withLock {
      _ = try coordinator.prepareRecoveryLocked()
    }
  }
  return true
}

private func verifyPendingHerdrRuntime(
  coordinator: EnvironmentTransactionCoordinator,
  stateRoot: URL,
  homeDirectory: URL,
  runtime: EnvironmentHerdrRuntimeReloader
) throws -> DesktopThemeAdapterStatus? {
  let target = try ActivationLock(root: stateRoot).withLock {
    try coordinator.pendingHerdrRuntimeTargetLocked()
  }
  guard let target else { return nil }
  let message = try runtime.reload(stateRoot, homeDirectory)
  try ActivationLock(root: stateRoot).withLock {
    try coordinator.markHerdrRuntimeVerifiedLocked(target)
  }
  return DesktopThemeAdapterStatus(
    adapterID: HerdrAdapter.id,
    requirement: "required",
    status: "applied",
    message: message
  )
}

private func rollbackEnvironmentTransaction(
  coordinator: EnvironmentTransactionCoordinator,
  stateRoot: URL,
  homeDirectory: URL,
  runtime: EnvironmentHerdrRuntimeReloader,
  spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher
) throws {
  try ActivationLock(root: stateRoot).withLock {
    try coordinator.rollbackApplyLocked()
  }
  if try verifyPendingHerdrRuntime(
    coordinator: coordinator,
    stateRoot: stateRoot,
    homeDirectory: homeDirectory,
    runtime: runtime
  ) != nil {
    try ActivationLock(root: stateRoot).withLock {
      _ = try coordinator.prepareRecoveryLocked()
    }
  }
  if try verifyPendingSpicetifyRuntime(
    coordinator: coordinator,
    stateRoot: stateRoot,
    homeDirectory: homeDirectory,
    runtime: spicetifyRuntime,
    adapterWasReconciled: false
  ) != nil {
    try ActivationLock(root: stateRoot).withLock {
      _ = try coordinator.prepareRecoveryLocked()
    }
  }
}

private func verifyPendingSpicetifyRuntime(
  coordinator: EnvironmentTransactionCoordinator,
  stateRoot: URL,
  homeDirectory: URL,
  runtime: EnvironmentSpicetifyRuntimeRefresher,
  adapterWasReconciled: Bool
) throws -> DesktopThemeAdapterStatus? {
  let target = try ActivationLock(root: stateRoot).withLock {
    try coordinator.pendingSpicetifyRuntimeTargetLocked()
  }
  guard let target else { return nil }
  let message: String
  if target == .managed, adapterWasReconciled {
    message = "Spicetify refreshed the managed configuration."
  } else {
    message = try runtime.refresh(stateRoot, homeDirectory, target == .original)
  }
  try ActivationLock(root: stateRoot).withLock {
    try coordinator.markSpicetifyRuntimeVerifiedLocked(target)
  }
  return DesktopThemeAdapterStatus(
    adapterID: SpicetifyAdapter.id,
    requirement: "required",
    status: "applied",
    message: message
  )
}

/// Restored runtime evidence merged with the reconciliation evidence recorded for the consumer
/// set that becomes default once the managed environment stops narrowing it.
private struct EnvironmentRestoredThemeState {
  let theme: [DesktopThemeAdapterStatus]
  let message: String
  let succeeded: Bool
}

/// Reconciles the default consumer set after teardown restored it, so the recorded evidence
/// covers every enabled consumer instead of the narrower set the environment owned. Throws when
/// the reconciliation attempt itself could not run.
private func reconcileRestoredDefaultConsumers(
  theme: DesktopThemeController?,
  stateRoot: URL,
  homeDirectory: URL,
  consumerPaths: ThemeConsumerPaths,
  restored: [DesktopThemeAdapterStatus],
  restorationMessage: String
) async throws -> EnvironmentRestoredThemeState {
  guard let theme,
    try EnvironmentStateStore(stateRoot: stateRoot).readOwnership() == nil
  else {
    return EnvironmentRestoredThemeState(
      theme: restored,
      message: restorationMessage,
      succeeded: true
    )
  }
  var hasActiveTheme = true
  do {
    _ = try ReconciliationStatusStore(root: stateRoot).activeManifest()
  } catch ReconciliationStatusError.noActiveGeneration {
    hasActiveTheme = false
  }
  let adapterIDs =
    hasActiveTheme
    ? try ThemeRuntimeSelection.enabledAdapterIDs(
      stateRoot: stateRoot,
      homeDirectory: homeDirectory
    ).sorted() : []
  guard !adapterIDs.isEmpty else {
    return EnvironmentRestoredThemeState(
      theme: restored,
      message:
        "\(restorationMessage) No canonical theme is active, so no reconciliation evidence was recorded.",
      succeeded: true
    )
  }
  let reconciliation = try await theme.reconcile(adapterIDs, stateRoot, consumerPaths)
  let reconciledIDs = Set(reconciliation.results.map(\.adapterID))
  return EnvironmentRestoredThemeState(
    theme: (restored.filter { !reconciledIDs.contains($0.adapterID) } + reconciliation.results)
      .sorted { $0.adapterID < $1.adapterID },
    message: reconciliation.succeeded
      ? "\(restorationMessage) The default consumer set was reconciled with the active canonical theme."
      : "\(restorationMessage) Required theme reconciliation of the default consumer set failed; run 'macarchy reconcile'.",
    succeeded: reconciliation.succeeded
  )
}

private func defaultConsumerReconciliationFailureMessage(
  _ restorationMessage: String,
  _ error: any Error
) -> String {
  "\(restorationMessage) The default consumer set could not be reconciled; run 'macarchy reconcile': \(error)"
}

struct EnvironmentNeovimPreparer: Sendable {
  let prepare: @Sendable (EnvironmentProfile, URL) -> EnvironmentVerification?

  private static let verifyPluginPins =
    #"lua local ok,message=pcall(require("config.macarchy-theme").verify_plugins); if not ok then vim.api.nvim_err_writeln(message); vim.cmd("cquit 1") end"#

  static let assumed = Self { _, _ in nil }

  static let live = Self { profile, homeDirectory in
    guard profile.editor == .neovim else { return nil }
    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-neovim-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    do {
      let configurationRoot = temporaryRoot.appending(
        path: "nvim",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: temporaryRoot) }
      try FileManager.default.copyItem(
        at: homeDirectory.appending(path: ".config/nvim").resolvingSymlinksInPath(),
        to: configurationRoot
      )
      try makeWritable(configurationRoot)
      let result = try ProcessRunner.live.run(
        ProcessRequest(
          executableURL: NeovimAdapter.liveExecutableURL,
          arguments: ["--headless", "+Lazy! restore", "+\(Self.verifyPluginPins)", "+qa"],
          timeout: 180,
          environmentOverrides: [
            "HOME": homeDirectory.path,
            "XDG_CONFIG_HOME": temporaryRoot.path,
          ]
        )
      )
      return EnvironmentVerification(
        id: "neovim_plugins",
        status: result.terminationStatus == 0 ? "verified" : "failed",
        message: result.terminationStatus == 0
          ? "Neovim restored and verified the selected plugin graph from its lock."
          : (result.output.isEmpty
            ? "Neovim could not restore the selected plugin graph." : result.output)
      )
    } catch {
      return EnvironmentVerification(
        id: "neovim_plugins",
        status: "failed",
        message: String(describing: error)
      )
    }
  }

  private static func makeWritable(_ root: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: root.path
    )
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return }
    for case let item as URL in enumerator {
      var metadata = stat()
      guard lstat(item.path, &metadata) == 0 else {
        throw EnvironmentLifecycleError.system(
          "inspect temporary Neovim configuration",
          item,
          errno
        )
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: metadata.st_mode & S_IFMT == S_IFDIR ? 0o700 : 0o600],
        ofItemAtPath: item.path
      )
    }
  }
}

struct EnvironmentApplyCommandRunner: Sendable {
  let prerequisites: EnvironmentPrerequisiteInspector
  let theme: DesktopThemeController?
  let verifier: EnvironmentSessionVerifier
  let neovim: EnvironmentNeovimPreparer
  let herdrRuntime: EnvironmentHerdrRuntimeReloader
  let spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher
  let transactionFaultInjector: @Sendable (EnvironmentTransactionCheckpoint) throws -> Void

  static let live = Self(
    prerequisites: .live,
    theme: .live,
    verifier: .live,
    neovim: .live,
    herdrRuntime: .live,
    spicetifyRuntime: .live
  )

  init(
    prerequisites: EnvironmentPrerequisiteInspector,
    theme: DesktopThemeController?,
    verifier: EnvironmentSessionVerifier,
    neovim: EnvironmentNeovimPreparer = .assumed,
    herdrRuntime: EnvironmentHerdrRuntimeReloader = .assumed,
    spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher = .assumed,
    transactionFaultInjector:
      @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = {
        _ in
      }
  ) {
    self.prerequisites = prerequisites
    self.theme = theme
    self.verifier = verifier
    self.neovim = neovim
    self.herdrRuntime = herdrRuntime
    self.spicetifyRuntime = spicetifyRuntime
    self.transactionFaultInjector = transactionFaultInjector
  }

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    adopt: String?,
    json: Bool,
    deferFinalization: Bool = false,
    profile suppliedProfile: PortableProfile? = nil
  ) async throws -> (output: String, succeeded: Bool) {
    let profile: PortableProfile
    let composition: EnvironmentComposition
    do {
      profile =
        try suppliedProfile
        ?? PortableProfileLoader().load(at: profileURL, required: profileRequired)
      composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot,
        profile: profile,
        stateRoot: stateRoot
      )
    } catch {
      return try failure(
        profileURL: profileURL,
        message: String(describing: error),
        mutated: false,
        json: json
      )
    }

    let requiresCurrentSpicetifyRuntime: Bool
    do {
      requiresCurrentSpicetifyRuntime = try requiresSpicetifyRuntimePrerequisites(
        stateRoot: stateRoot,
        desiredEnabled: profile.environment.presets.spicetify
      )
    } catch {
      return try failure(
        profileURL: profileURL,
        profile: profile.environment,
        message: String(describing: error),
        mutated: false,
        json: json
      )
    }
    var prerequisiteState = prerequisites.inspect(profile.environment, homeDirectory)
    if requiresCurrentSpicetifyRuntime, !profile.environment.presets.spicetify {
      prerequisiteState += prerequisites.inspectSpicetifyRuntime(homeDirectory)
    }
    let missing = prerequisiteState.filter { $0.status == "missing" }
    guard missing.isEmpty else {
      return try failure(
        profileURL: profileURL,
        profile: profile.environment,
        prerequisites: prerequisiteState,
        message: "Missing prerequisites: \(missing.map(\.id).joined(separator: ", ")).",
        mutated: false,
        json: json
      )
    }

    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      faultInjector: transactionFaultInjector
    )

    if profile.environment.isEntirelyDisabled {
      do {
        let stateStore = EnvironmentStateStore(stateRoot: stateRoot)
        let hasManagedState =
          try stateStore.readOwnership() != nil
          || stateStore.transactionExists
          || EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination() != nil
        if !hasManagedState {
          return try EnvironmentStatusCommandRunner(
            prerequisites: prerequisites,
            theme: theme,
            verifier: verifier
          ).execute(
            operation: "environment_apply",
            resourcesRoot: resourcesRoot,
            profileURL: profileURL,
            profileRequired: profileRequired,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            consumerPaths: consumerPaths,
            includeVerification: true,
            successfulOutcome: "no_change",
            mutated: false,
            successMessage:
              "Every daily tool role is disabled; no managed state was changed.",
            json: json,
            profile: profile
          )
        }
        let lifecycleLock = EnvironmentLifecycleLock(stateRoot: stateRoot)
        let lifecycleLockDescriptor = try lifecycleLock.acquire()
        defer { lifecycleLock.release(lifecycleLockDescriptor) }
        _ = try recoverEnvironmentTransaction(
          coordinator: coordinator,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          runtime: herdrRuntime, spicetifyRuntime: spicetifyRuntime
        )
        let result = try ActivationLock(root: stateRoot).withLock {
          try coordinator.teardownLocked(dryRun: false)
        }
        let restoredHerdr: DesktopThemeAdapterStatus?
        let restoredSpicetify: DesktopThemeAdapterStatus?
        do {
          restoredHerdr = try verifyPendingHerdrRuntime(
            coordinator: coordinator,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            runtime: herdrRuntime
          )
          restoredSpicetify = try verifyPendingSpicetifyRuntime(
            coordinator: coordinator,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            runtime: spicetifyRuntime,
            adapterWasReconciled: false
          )
          if restoredHerdr != nil || restoredSpicetify != nil {
            try ActivationLock(root: stateRoot).withLock {
              _ = try coordinator.prepareRecoveryLocked()
            }
          }
        } catch {
          let activationError = error
          do {
            try rollbackEnvironmentTransaction(
              coordinator: coordinator,
              stateRoot: stateRoot,
              homeDirectory: homeDirectory,
              runtime: herdrRuntime, spicetifyRuntime: spicetifyRuntime
            )
          } catch {
            throw EnvironmentLifecycleError.blocked(
              "teardown runtime activation failed and rollback requires recovery: \(error)"
            )
          }
          throw EnvironmentLifecycleError.blocked(
            "teardown runtime activation failed and was rolled back: \(activationError)"
          )
        }
        let restored: EnvironmentRestoredThemeState
        do {
          restored = try await reconcileRestoredDefaultConsumers(
            theme: theme,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            consumerPaths: consumerPaths,
            restored: [restoredHerdr, restoredSpicetify].compactMap { $0 },
            restorationMessage: result.message
          )
        } catch {
          return try failure(
            profileURL: profileURL,
            profile: profile.environment,
            prerequisites: prerequisiteState,
            theme: [restoredHerdr, restoredSpicetify].compactMap { $0 },
            message: defaultConsumerReconciliationFailureMessage(result.message, error),
            mutated: result.changed,
            json: json
          )
        }
        guard restored.succeeded else {
          return try failure(
            profileURL: profileURL,
            profile: profile.environment,
            prerequisites: prerequisiteState,
            theme: restored.theme,
            message: restored.message,
            mutated: result.changed,
            json: json
          )
        }
        return try EnvironmentStatusCommandRunner(
          prerequisites: prerequisites,
          theme: theme,
          verifier: verifier
        ).execute(
          operation: "environment_apply",
          resourcesRoot: resourcesRoot,
          profileURL: profileURL,
          profileRequired: profileRequired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          consumerPaths: consumerPaths,
          includeVerification: true,
          observedTheme: restored.theme,
          successfulOutcome: result.changed ? "applied" : "no_change",
          mutated: result.changed,
          successMessage: restored.message,
          json: json,
          profile: profile
        )
      } catch {
        return try failure(
          profileURL: profileURL,
          profile: profile.environment,
          prerequisites: prerequisiteState,
          message: String(describing: error),
          mutated: EnvironmentStateStore(stateRoot: stateRoot).transactionExists,
          transactionStatus: EnvironmentStateStore(stateRoot: stateRoot).transactionExists
            ? "recovery_required" : "clear",
          json: json
        )
      }
    }

    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    let lifecycleLock = EnvironmentLifecycleLock(stateRoot: stateRoot)
    let lifecycleLockDescriptor = try lifecycleLock.acquire()
    defer { lifecycleLock.release(lifecycleLockDescriptor) }

    do {
      let recovered = try recoverEnvironmentTransaction(
        coordinator: coordinator,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        runtime: herdrRuntime, spicetifyRuntime: spicetifyRuntime
      )
      if recovered {
        return try failure(
          profileURL: profileURL,
          profile: profile.environment,
          prerequisites: prerequisiteState,
          message: "Interrupted environment state was recovered; review plan and apply again.",
          mutated: true,
          json: json
        )
      }
    } catch {
      return try failure(
        profileURL: profileURL,
        profile: profile.environment,
        prerequisites: prerequisiteState,
        message: String(describing: error),
        mutated: EnvironmentStateStore(stateRoot: stateRoot).transactionExists,
        transactionStatus: EnvironmentStateStore(stateRoot: stateRoot).transactionExists
          ? "recovery_required" : "clear",
        json: json
      )
    }

    if theme != nil, !profile.environment.selectedThemeAdapterIDs.isEmpty {
      do {
        _ = try ReconciliationStatusStore(root: stateRoot).activeManifest()
      } catch {
        return try failure(
          profileURL: profileURL,
          profile: profile.environment,
          prerequisites: prerequisiteState,
          message: "An active canonical theme is required before environment apply: \(error)",
          mutated: false,
          json: json
        )
      }
    }

    let inspection = EnvironmentProviderInspector().inspect(
      composition: composition,
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    guard !inspection.isBlocked else {
      return try failure(
        profileURL: profileURL,
        profile: profile.environment,
        prerequisites: prerequisiteState,
        entries: inspection.entries,
        adoptionEvidenceDigest: inspection.adoptionEvidenceDigest,
        message: inspection.blockedMessage ?? "Provider ownership drifted.",
        mutated: false,
        json: json
      )
    }
    let applyResult: (changed: Bool, generationID: String)
    do {
      applyResult = try ActivationLock(root: stateRoot).withLock {
        let lockedInspection = EnvironmentProviderInspector().inspect(
          composition: composition,
          homeDirectory: homeDirectory,
          stateRoot: stateRoot
        )
        let previousThemeGenerationID: String?
        if theme != nil, !profile.environment.selectedThemeAdapterIDs.isEmpty {
          previousThemeGenerationID = try ReconciliationStatusStore(root: stateRoot)
            .activeManifest().generationID
        } else {
          previousThemeGenerationID = nil
        }
        let themeBridgeSnapshot = try EnvironmentThemeBridgeState.capture(
          ids: Set(
            lockedInspection.desiredEntries.map(\.id)
              + (lockedInspection.ownership?.records.map(\.id) ?? [])
          ),
          stateRoot: stateRoot
        )
        return try coordinator.applyLocked(
          composition: composition,
          inspection: lockedInspection,
          adoptionDigest: adopt,
          previousThemeGenerationID: previousThemeGenerationID,
          themeBridges: themeBridgeSnapshot
        )
      }
    } catch {
      return try failure(
        profileURL: profileURL,
        profile: profile.environment,
        prerequisites: prerequisiteState,
        entries: inspection.entries,
        adoptionEvidenceDigest: inspection.adoptionEvidenceDigest,
        message: String(describing: error),
        mutated: EnvironmentStateStore(stateRoot: stateRoot).transactionExists,
        transactionStatus: EnvironmentStateStore(stateRoot: stateRoot).transactionExists
          ? "recovery_required" : "clear",
        json: json
      )
    }

    let appliedTheme: [DesktopThemeAdapterStatus]
    let verification: [EnvironmentVerification]
    var neovimPluginPreparationRan = false
    var herdrActivation: DesktopThemeAdapterStatus?
    do {
      herdrActivation = try verifyPendingHerdrRuntime(
        coordinator: coordinator,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        runtime: herdrRuntime
      )
      let neovimVerification = neovim.prepare(profile.environment, homeDirectory)
      neovimPluginPreparationRan = neovimVerification != nil
      if let neovimVerification, neovimVerification.status != "verified" {
        throw EnvironmentLifecycleError.blocked(neovimVerification.message)
      }
      let nonHerdrAdapterIDs = profile.environment.selectedThemeAdapterIDs.filter {
        $0 != HerdrAdapter.id
      }
      if let theme, !nonHerdrAdapterIDs.isEmpty {
        let reconciliation = try await theme.reconcile(
          nonHerdrAdapterIDs,
          stateRoot,
          consumerPaths.managedEnvironmentPaths(
            stateRoot: stateRoot,
            homeDirectory: homeDirectory
          )
        )
        guard reconciliation.succeeded else {
          throw EnvironmentLifecycleError.blocked(
            "required theme reconciliation failed for environment generation \(applyResult.generationID)"
          )
        }
        appliedTheme = (reconciliation.results + (herdrActivation.map { [$0] } ?? []))
          .sorted { $0.adapterID < $1.adapterID }
      } else {
        appliedTheme = herdrActivation.map { [$0] } ?? []
      }
      _ = try verifyPendingSpicetifyRuntime(
        coordinator: coordinator,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        runtime: spicetifyRuntime,
        adapterWasReconciled: appliedTheme.contains {
          $0.adapterID == SpicetifyAdapter.id && $0.status != "failed"
        }
      )
      verification =
        (neovimVerification.map { [$0] } ?? [])
        + verifier.verify(profile.environment, homeDirectory)
        + (profile.environment.presets.slack
          ? [
            EnvironmentVerification(
              id: SlackAdapter.id,
              status: "manual_required",
              message:
                "Manual import is required for each Slack workspace. \(SlackAdapter.importInstructions)"
            )
          ] : [])
      guard
        verification.allSatisfy({
          $0.status == "verified" || $0.status == "manual_required"
        })
      else {
        let failures = verification.filter {
          $0.status != "verified" && $0.status != "manual_required"
        }.map(\.message)
        throw EnvironmentLifecycleError.blocked(failures.joined(separator: "; "))
      }
      if !deferFinalization {
        try ActivationLock(root: stateRoot).withLock {
          try coordinator.finishApplyLocked(composition: composition)
        }
      }
    } catch {
      do {
        try rollbackEnvironmentTransaction(
          coordinator: coordinator,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          runtime: herdrRuntime, spicetifyRuntime: spicetifyRuntime
        )
      } catch {
        return try failure(
          profileURL: profileURL,
          profile: profile.environment,
          prerequisites: prerequisiteState,
          message: neovimPluginPreparationRan
            ? "Environment configuration ownership rollback requires recovery; provider-private Neovim plugin/cache changes may remain. Rollback failed: \(error)"
            : "Provider verification failed and rollback requires recovery: \(error)",
          mutated: true,
          transactionStatus: "recovery_required",
          json: json
        )
      }
      let restorationVerification = verifier.verifyRestored(profile.environment, homeDirectory)
      if let failed = restorationVerification.first(where: { $0.status != "verified" }) {
        return try failure(
          profileURL: profileURL,
          profile: profile.environment,
          prerequisites: prerequisiteState,
          message:
            neovimPluginPreparationRan
            ? "Environment configuration ownership was rolled back; provider-private Neovim plugin/cache changes may remain. The restored fresh session also failed: \(failed.message)"
            : "Environment apply rolled back, but the restored fresh session failed: \(failed.message)",
          mutated: applyResult.changed,
          json: json
        )
      }
      return try failure(
        profileURL: profileURL,
        profile: profile.environment,
        prerequisites: prerequisiteState,
        message: neovimPluginPreparationRan
          ? "Environment configuration ownership was rolled back; provider-private Neovim plugin/cache changes may remain. Apply failed: \(error)"
          : "Environment apply rolled back: \(error)",
        mutated: applyResult.changed,
        json: json
      )
    }

    return try EnvironmentStatusCommandRunner(
      prerequisites: prerequisites,
      theme: theme,
      verifier: verifier
    ).execute(
      operation: "environment_apply",
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      consumerPaths: consumerPaths,
      observedTheme: appliedTheme,
      observedVerification: verification,
      successfulOutcome: applyResult.changed ? "applied" : "no_change",
      mutated: applyResult.changed,
      successMessage: applyResult.changed
        ? "The daily tool environment was published and verified."
        : "The daily tool environment was already converged.",
      json: json,
      deferredApplyTransaction: deferFinalization,
      profile: profile
    )
  }

  func finishDeferredApply(
    resourcesRoot: URL? = nil,
    profile: PortableProfile? = nil,
    stateRoot: URL,
    homeDirectory: URL,
    commit: Bool
  ) throws -> Bool {
    let lifecycleLock = EnvironmentLifecycleLock(stateRoot: stateRoot)
    let descriptor = try lifecycleLock.acquire()
    defer { lifecycleLock.release(descriptor) }
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction() else { return false }
    guard transaction.operation == .apply else {
      throw EnvironmentLifecycleError.blocked(
        "the pending environment operation is not apply"
      )
    }
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    if commit {
      guard transaction.direction == .forward else {
        throw EnvironmentLifecycleError.blocked(
          "environment apply already entered rollback"
        )
      }
      guard let resourcesRoot, let profile else {
        throw EnvironmentLifecycleError.blocked(
          "deferred environment commit requires the reviewed profile"
        )
      }
      let composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot,
        profile: profile,
        stateRoot: stateRoot
      )
      try ActivationLock(root: stateRoot).withLock {
        try coordinator.finishApplyLocked(composition: composition)
      }
    } else {
      try rollbackEnvironmentTransaction(
        coordinator: coordinator,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        runtime: herdrRuntime,
        spicetifyRuntime: spicetifyRuntime
      )
    }
    return true
  }

  private func failure(
    profileURL: URL,
    profile: EnvironmentProfile? = nil,
    prerequisites: [EnvironmentPrerequisiteStatus] = [],
    entries: [EnvironmentEntryInspection] = [],
    adoptionEvidenceDigest: String? = nil,
    theme: [DesktopThemeAdapterStatus] = [],
    message: String,
    mutated: Bool,
    transactionStatus: String = "clear",
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report = EnvironmentLifecycleReport(
      operation: "environment_apply",
      outcome: "blocked",
      mutated: mutated,
      profile: profileURL.path,
      providers: profile.map(EnvironmentStatusCommandRunner.providers) ?? [:],
      generation: EnvironmentGenerationReport(status: "unavailable", message: message),
      transactionStatus: transactionStatus,
      adoptionEvidenceDigest: adoptionEvidenceDigest,
      prerequisites: prerequisites,
      entries: entries,
      theme: theme,
      verification: [],
      message: message
    )
    return (try report.render(json: json), false)
  }
}

struct EnvironmentTeardownCommandRunner: Sendable {
  let prerequisites: EnvironmentPrerequisiteInspector
  let theme: DesktopThemeController?
  let herdrRuntime: EnvironmentHerdrRuntimeReloader
  let spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher

  static let live = Self(
    prerequisites: .live,
    theme: .live,
    herdrRuntime: .live,
    spicetifyRuntime: .live
  )

  init(
    prerequisites: EnvironmentPrerequisiteInspector = .assumed,
    theme: DesktopThemeController? = nil,
    herdrRuntime: EnvironmentHerdrRuntimeReloader = .assumed,
    spicetifyRuntime: EnvironmentSpicetifyRuntimeRefresher = .assumed
  ) {
    self.prerequisites = prerequisites
    self.theme = theme
    self.herdrRuntime = herdrRuntime
    self.spicetifyRuntime = spicetifyRuntime
  }

  func execute(
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    var prerequisiteState = [EnvironmentPrerequisiteStatus]()
    do {
      let store = EnvironmentStateStore(stateRoot: stateRoot)
      let hasManagedState =
        try store.readOwnership() != nil
        || store.transactionExists
        || EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination() != nil
      if !hasManagedState {
        let report = EnvironmentLifecycleReport(
          operation: "environment_teardown",
          outcome: "absent",
          mutated: false,
          profile: nil,
          providers: [:],
          generation: EnvironmentGenerationReport(
            status: "absent",
            message: "No managed environment ownership exists."
          ),
          transactionStatus: "clear",
          adoptionEvidenceDigest: nil,
          prerequisites: [],
          entries: [],
          theme: [],
          verification: [],
          message: "No managed environment ownership exists."
        )
        return (try report.render(json: json), true)
      }
      if try requiresSpicetifyRuntimePrerequisites(
        stateRoot: stateRoot,
        desiredEnabled: nil
      ) {
        prerequisiteState = prerequisites.inspectSpicetifyRuntime(homeDirectory)
        let missing = prerequisiteState.filter { $0.status == "missing" }
        guard missing.isEmpty else {
          let message = "Missing prerequisites: \(missing.map(\.id).joined(separator: ", "))."
          let report = EnvironmentLifecycleReport(
            operation: "environment_teardown",
            outcome: "blocked",
            mutated: false,
            profile: nil,
            providers: [:],
            generation: EnvironmentGenerationReport(status: "unknown", message: message),
            transactionStatus: store.transactionExists ? "recovery_required" : "clear",
            adoptionEvidenceDigest: nil,
            prerequisites: prerequisiteState,
            entries: [],
            theme: [],
            verification: [],
            message: message
          )
          return (try report.render(json: json), false)
        }
      }
      let lifecycleLock = EnvironmentLifecycleLock(stateRoot: stateRoot)
      let lifecycleLockDescriptor = try lifecycleLock.acquire()
      defer { lifecycleLock.release(lifecycleLockDescriptor) }
      let coordinator = EnvironmentTransactionCoordinator(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      )
      if !dryRun {
        _ = try recoverEnvironmentTransaction(
          coordinator: coordinator,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          runtime: herdrRuntime, spicetifyRuntime: spicetifyRuntime
        )
      }
      let result = try ActivationLock(root: stateRoot).withLock {
        try coordinator.teardownLocked(dryRun: dryRun)
      }
      let restoredHerdr: DesktopThemeAdapterStatus?
      let restoredSpicetify: DesktopThemeAdapterStatus?
      do {
        restoredHerdr = try verifyPendingHerdrRuntime(
          coordinator: coordinator,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          runtime: herdrRuntime
        )
        restoredSpicetify = try verifyPendingSpicetifyRuntime(
          coordinator: coordinator,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          runtime: spicetifyRuntime,
          adapterWasReconciled: false
        )
        if restoredHerdr != nil || restoredSpicetify != nil {
          try ActivationLock(root: stateRoot).withLock {
            _ = try coordinator.prepareRecoveryLocked()
          }
        }
      } catch {
        let activationError = error
        do {
          try rollbackEnvironmentTransaction(
            coordinator: coordinator,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            runtime: herdrRuntime, spicetifyRuntime: spicetifyRuntime
          )
        } catch {
          throw EnvironmentLifecycleError.blocked(
            "teardown runtime activation failed and rollback requires recovery: \(error)"
          )
        }
        throw EnvironmentLifecycleError.blocked(
          "teardown runtime activation failed and was rolled back: \(activationError)"
        )
      }
      var themeState = [restoredHerdr, restoredSpicetify].compactMap { $0 }
      var message = result.message
      if !dryRun {
        let restored: EnvironmentRestoredThemeState
        do {
          restored = try await reconcileRestoredDefaultConsumers(
            theme: theme,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            consumerPaths: consumerPaths,
            restored: themeState,
            restorationMessage: result.message
          )
        } catch {
          return (
            try Self.report(
              outcome: "blocked",
              mutated: true,
              generationStatus: "absent",
              prerequisites: prerequisiteState,
              theme: themeState,
              message: defaultConsumerReconciliationFailureMessage(result.message, error)
            ).render(json: json), false
          )
        }
        themeState = restored.theme
        message = restored.message
        guard restored.succeeded else {
          return (
            try Self.report(
              outcome: "blocked",
              mutated: true,
              generationStatus: "absent",
              prerequisites: prerequisiteState,
              theme: themeState,
              message: message
            ).render(json: json), false
          )
        }
      }
      let report = Self.report(
        outcome: dryRun ? "ready" : result.changed ? "restored" : "absent",
        mutated: !dryRun && result.changed,
        generationStatus: dryRun ? "unchanged" : "absent",
        prerequisites: prerequisiteState,
        theme: themeState,
        message: message
      )
      return (try report.render(json: json), true)
    } catch {
      let report = EnvironmentLifecycleReport(
        operation: "environment_teardown",
        outcome: "blocked",
        mutated: EnvironmentStateStore(stateRoot: stateRoot).transactionExists,
        profile: nil,
        providers: [:],
        generation: EnvironmentGenerationReport(
          status: "unknown",
          message: String(describing: error)
        ),
        transactionStatus: EnvironmentStateStore(stateRoot: stateRoot).transactionExists
          ? "recovery_required" : "clear",
        adoptionEvidenceDigest: nil,
        prerequisites: prerequisiteState,
        entries: [],
        theme: [],
        verification: [],
        message: String(describing: error)
      )
      return (try report.render(json: json), false)
    }
  }

  private static func report(
    outcome: String,
    mutated: Bool,
    generationStatus: String,
    prerequisites: [EnvironmentPrerequisiteStatus],
    theme: [DesktopThemeAdapterStatus],
    message: String
  ) -> EnvironmentLifecycleReport {
    EnvironmentLifecycleReport(
      operation: "environment_teardown",
      outcome: outcome,
      mutated: mutated,
      profile: nil,
      providers: [:],
      generation: EnvironmentGenerationReport(status: generationStatus, message: message),
      transactionStatus: "clear",
      adoptionEvidenceDigest: nil,
      prerequisites: prerequisites,
      entries: [],
      theme: theme,
      verification: [],
      message: message
    )
  }
}
