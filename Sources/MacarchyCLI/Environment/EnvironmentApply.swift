import Darwin
import Foundation
import ThemeCore

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

  static let live = Self(
    prerequisites: .live,
    theme: .live,
    verifier: .live,
    neovim: .live
  )

  init(
    prerequisites: EnvironmentPrerequisiteInspector,
    theme: DesktopThemeController?,
    verifier: EnvironmentSessionVerifier,
    neovim: EnvironmentNeovimPreparer = .assumed
  ) {
    self.prerequisites = prerequisites
    self.theme = theme
    self.verifier = verifier
    self.neovim = neovim
  }

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    adopt: String?,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let profile: PortableProfile
    let composition: EnvironmentComposition
    do {
      profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
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

    let prerequisiteState = prerequisites.inspect(profile.environment, homeDirectory)
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
      stateRoot: stateRoot
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
            json: json
          )
        }
        let lifecycleLock = EnvironmentLifecycleLock(stateRoot: stateRoot)
        let lifecycleLockDescriptor = try lifecycleLock.acquire()
        defer { lifecycleLock.release(lifecycleLockDescriptor) }
        let result = try ActivationLock(root: stateRoot).withLock {
          try coordinator.teardownLocked(dryRun: false)
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
          successfulOutcome: result.changed ? "applied" : "no_change",
          mutated: result.changed,
          successMessage: result.message,
          json: json
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
      let recovered = try ActivationLock(root: stateRoot).withLock {
        try coordinator.recoverLocked()
      }
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
    do {
      let neovimVerification = neovim.prepare(profile.environment, homeDirectory)
      neovimPluginPreparationRan = neovimVerification != nil
      if let neovimVerification, neovimVerification.status != "verified" {
        throw EnvironmentLifecycleError.blocked(neovimVerification.message)
      }
      if let theme, !profile.environment.selectedThemeAdapterIDs.isEmpty {
        let reconciliation = try await theme.reconcile(
          profile.environment.selectedThemeAdapterIDs,
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
        appliedTheme = reconciliation.results
      } else {
        appliedTheme = []
      }
      verification =
        (neovimVerification.map { [$0] } ?? [])
        + verifier.verify(profile.environment, homeDirectory)
      guard verification.allSatisfy({ $0.status == "verified" }) else {
        let failures = verification.filter { $0.status != "verified" }.map(\.message)
        throw EnvironmentLifecycleError.blocked(failures.joined(separator: "; "))
      }
      try ActivationLock(root: stateRoot).withLock {
        try coordinator.finishApplyLocked(composition: composition)
      }
    } catch {
      do {
        try ActivationLock(root: stateRoot).withLock {
          try coordinator.rollbackApplyLocked()
        }
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
      json: json
    )
  }

  private func failure(
    profileURL: URL,
    profile: EnvironmentProfile? = nil,
    prerequisites: [EnvironmentPrerequisiteStatus] = [],
    entries: [EnvironmentEntryInspection] = [],
    adoptionEvidenceDigest: String? = nil,
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
      theme: [],
      verification: [],
      message: message
    )
    return (try report.render(json: json), false)
  }
}

struct EnvironmentTeardownCommandRunner: Sendable {
  static let live = Self()

  func execute(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
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
      let lifecycleLock = EnvironmentLifecycleLock(stateRoot: stateRoot)
      let lifecycleLockDescriptor = try lifecycleLock.acquire()
      defer { lifecycleLock.release(lifecycleLockDescriptor) }
      let result = try ActivationLock(root: stateRoot).withLock {
        try EnvironmentTransactionCoordinator(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot
        ).teardownLocked(dryRun: dryRun)
      }
      let report = EnvironmentLifecycleReport(
        operation: "environment_teardown",
        outcome: dryRun ? "ready" : result.changed ? "restored" : "absent",
        mutated: !dryRun && result.changed,
        profile: nil,
        providers: [:],
        generation: EnvironmentGenerationReport(
          status: dryRun ? "unchanged" : "absent",
          message: result.message
        ),
        transactionStatus: "clear",
        adoptionEvidenceDigest: nil,
        prerequisites: [],
        entries: [],
        theme: [],
        verification: [],
        message: result.message
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
        prerequisites: [],
        entries: [],
        theme: [],
        verification: [],
        message: String(describing: error)
      )
      return (try report.render(json: json), false)
    }
  }
}
