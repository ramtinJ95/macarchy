import Foundation
import ThemeCore

enum ThemeRuntimeSelection {
  static func enabledAdapterIDs(stateRoot: URL, homeDirectory: URL) throws -> Set<String> {
    try enabledAdapterIDs(
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      ownership: EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    )
  }

  private static func enabledAdapterIDs(
    stateRoot: URL,
    homeDirectory: URL,
    ownership: EnvironmentOwnership?
  ) throws -> Set<String> {
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let setupIDs = Set(try SetupOwnershipManager().readRecords(context: context).map(\.id))
    let legacyAdapterIDs = try EnvironmentLinkedPreset.allCases.compactMap { linked in
      try linked.hasCompleteLegacyIntegration(setupIDs: setupIDs) ? linked.preset.adapterID : nil
    }

    var enabled: Set<String>
    if let ownership {
      enabled = appliedAdapterIDs(for: ownership)
    } else {
      enabled = ConsumerCatalog.shared.defaultEnabledAdapterIDs
      enabled.subtract(EnvironmentPreset.allCases.compactMap(\.adapterID))
      let herdr = HerdrAdapter(
        root: stateRoot,
        configurationURL: homeDirectory.appending(path: ConsumerHomePath.herdrConfiguration),
        executableURL: HerdrAdapter.executableURL(homeDirectory: homeDirectory),
        controlIsAvailable: { true }
      )
      if try herdr.legacyOwnershipEvidence() != nil {
        enabled.insert(HerdrAdapter.id)
      }
    }
    enabled.formUnion(legacyAdapterIDs)
    return enabled
  }

  static func appliedAdapterIDs(for ownership: EnvironmentOwnership) -> Set<String> {
    if let explicit = ownership.enabledThemeAdapterIDs {
      return Set(explicit)
    }
    var enabled = ConsumerCatalog.shared.defaultEnabledAdapterIDs
    if let borders = ownership.borders { enabled.insert(borders.adapterID) }
    enabled.remove(SpicetifyAdapter.id)
    enabled.remove(TuicrAdapter.id)
    if ownership.spicetifyEnabled {
      enabled.insert(SpicetifyAdapter.id)
    }
    if ownership.tuicrEnabled {
      enabled.insert(TuicrAdapter.id)
    }
    return enabled
  }

  static func activationCoordinator(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    herdrRuntime: EnvironmentHerdrRuntimeReloader = .live,
    bordersRuntime: EnvironmentBordersRuntime = .live,
    enabledAdapterIDs: Set<String>? = nil
  ) throws -> ThemeActivationCoordinator {
    let homeDirectory = consumerPaths.piDerivedHomeDirectoryURL
    let ownership = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    let herdrManagedMode =
      ownership?.herdrEnabled == true
      ? managedHerdrMode(
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        runtime: herdrRuntime
      ) : nil
    let enabledAdapterIDs =
      try enabledAdapterIDs
      ?? Self.enabledAdapterIDs(
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        ownership: ownership
      )
    return try ThemeActivationCoordinator(
      root: stateRoot,
      consumerPaths: Self.consumerPaths(
        stateRoot: stateRoot,
        consumerPaths: consumerPaths,
        ownership: ownership
      ),
      enabledAdapterIDs: enabledAdapterIDs,
      herdrManagedMode: herdrManagedMode,
      bordersManagedMode: managedBordersMode(
        stateRoot: stateRoot, homeDirectory: homeDirectory, runtime: bordersRuntime),
      leanFocusManagedMode: managedLeanMode(
        stateRoot: stateRoot, homeDirectory: homeDirectory, runtime: bordersRuntime.lean),
      piSelectionIsApplied: {
        try piIsEnabled(stateRoot: stateRoot, consumerPaths: consumerPaths)
      },
      piThemeLinkRefreshIsAllowed: {
        try piThemeLinkRefreshIsAllowed(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths
        )
      }
    )
  }

  static func managedBordersMode(
    stateRoot: URL,
    homeDirectory: URL,
    runtime: EnvironmentBordersRuntime
  ) -> BordersManagedMode {
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: homeDirectory, stateRoot: stateRoot)
    return BordersManagedMode(
      preflight: { try coordinator.verifySelectedBordersConfiguration() },
      inspect: {
        try coordinator.verifySelectedBordersConfiguration()
        guard try runtime.preflight(homeDirectory).isRunning else {
          throw EnvironmentLifecycleError.drift("the applied Borders service is stopped")
        }
        return
          "Managed Borders configuration and Homebrew service are present; native appearance settings and pixels have no readback."
      },
      reconcile: {
        return try EnvironmentLifecycleLock(stateRoot: stateRoot).withLock {
          guard try EnvironmentStateStore(stateRoot: stateRoot).readTransaction() == nil else {
            throw EnvironmentLifecycleError.blocked(
              "Borders environment recovery must finish before theme reconciliation")
          }
          try coordinator.verifySelectedBordersConfiguration()
          guard try runtime.preflight(homeDirectory).isRunning else {
            throw EnvironmentLifecycleError.drift("the applied Borders service is stopped")
          }
          return try runtime.request(stateRoot, homeDirectory)
        }
      }
    )
  }

  static func managedHerdrMode(
    stateRoot: URL,
    homeDirectory: URL,
    runtime: EnvironmentHerdrRuntimeReloader
  ) -> HerdrManagedMode {
    HerdrManagedMode(
      preflight: { desired in
        try EnvironmentTransactionCoordinator(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot
        ).preflightManagedHerdr(desired, requireActiveMatch: false)
      },
      inspect: { desired in
        try EnvironmentTransactionCoordinator(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot
        ).preflightManagedHerdr(desired, requireActiveMatch: true)
        return "Herdr's generated theme surface is owned by the applied environment"
      },
      reconcile: { desired in
        try reconcileManagedHerdr(
          desired,
          stateRoot: stateRoot,
          homeDirectory: homeDirectory,
          runtime: runtime
        )
      }
    )
  }

  private static func reconcileManagedHerdr(
    _ desired: GeneratedHerdrTheme,
    stateRoot: URL,
    homeDirectory: URL,
    runtime: EnvironmentHerdrRuntimeReloader
  ) throws -> String {
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    return try EnvironmentLifecycleLock(stateRoot: stateRoot).withLock {
      let changed = try ActivationLock(root: stateRoot).withLock {
        try coordinator.beginHerdrThemeTransitionLocked(desired)
      }
      guard changed else {
        return "Herdr's aggregate-managed theme surface was already current"
      }
      do {
        let message = try runtime.reload(stateRoot, homeDirectory)
        try ActivationLock(root: stateRoot).withLock {
          try coordinator.markHerdrRuntimeVerifiedLocked(.managed)
          _ = try coordinator.prepareRecoveryLocked()
        }
        return message
      } catch {
        let activationError = error
        do {
          try ActivationLock(root: stateRoot).withLock {
            try coordinator.rollbackApplyLocked()
          }
          let target = try ActivationLock(root: stateRoot).withLock {
            try coordinator.pendingHerdrRuntimeTargetLocked()
          }
          if let target {
            _ = try runtime.reload(stateRoot, homeDirectory)
            try ActivationLock(root: stateRoot).withLock {
              try coordinator.markHerdrRuntimeVerifiedLocked(target)
              _ = try coordinator.prepareRecoveryLocked()
            }
          }
        } catch {
          throw EnvironmentLifecycleError.blocked(
            "Herdr theme reload failed: \(activationError); rollback requires recovery: \(error)"
          )
        }
        throw EnvironmentLifecycleError.blocked(
          "Herdr theme reload failed and was rolled back: \(activationError)"
        )
      }
    }
  }

  static func consumerPaths(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> ThemeConsumerPaths {
    try Self.consumerPaths(
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      ownership: EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    )
  }

  private static func consumerPaths(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    ownership: EnvironmentOwnership?
  ) throws -> ThemeConsumerPaths {
    guard let ownership else { return consumerPaths }
    // Derives home from the Starship configuration path (`<home>/.config/starship.toml`).
    let homeDirectory = consumerPaths.starshipConfigurationURL.deletingLastPathComponent()
      .deletingLastPathComponent()
    for provider in EnvironmentNativeSeed.Provider.allCases
    where provider != .zsh && ownership.standardNativeEntries?.contains(provider.entryID) == true {
      try EnvironmentStandardNativeConfiguration.validate(
        provider, homeDirectory: homeDirectory, stateRoot: stateRoot)
    }
    var paths = consumerPaths
    paths.starshipBehaviorURL = EnvironmentNativeFileMigration.starshipBehaviorURL(
      homeDirectory: homeDirectory, stateRoot: stateRoot, ownership: ownership)
    return paths
  }

  static func enabledAdapterIDs(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> Set<String> {
    let home = consumerPaths.piDerivedHomeDirectoryURL
    return try enabledAdapterIDs(stateRoot: stateRoot, homeDirectory: home)
  }

  static func piIsEnabled(stateRoot: URL, consumerPaths: ThemeConsumerPaths) throws -> Bool {
    try enabledAdapterIDs(stateRoot: stateRoot, consumerPaths: consumerPaths)
      .contains(PiAdapter.id)
  }

  static func slackIsEnabled(stateRoot: URL) throws -> Bool {
    try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()?.slackEnabled == true
  }

  static func piThemeLinkRefreshIsAllowed(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> Bool {
    let ownership = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    let home = consumerPaths.piDerivedHomeDirectoryURL
    let setupIDs = Set(
      try SetupOwnershipManager()
        .readRecords(context: SetupOwnershipManager.Context(homeDirectory: home))
        .map(\.id)
    )
    let legacyPi = try EnvironmentLinkedPreset.pi.hasCompleteLegacyIntegration(setupIDs: setupIDs)
    return ownership?.records.contains(where: { $0.id == .piTheme }) == true
      || legacyPi
  }
}
