import Foundation
import ThemeCore

enum ThemeRuntimeSelection {
  private static let legacyCodexIDs = Set([
    SetupOwnershipManager.codexSelectorID,
    SetupOwnershipManager.codexThemeLinkID,
  ])
  private static let legacyPiIDs = Set([
    SetupOwnershipManager.piSelectorID,
    SetupOwnershipManager.piThemeLinkID,
  ])
  private static let legacyTuicrIDs = Set([
    SetupOwnershipManager.tuicrSelectorID,
    SetupOwnershipManager.tuicrThemeLinkID,
    SetupOwnershipManager.tuicrSyntaxLinkID,
  ])

  static func enabledAdapterIDs(stateRoot: URL, homeDirectory: URL) throws -> Set<String> {
    let ownership = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let setupIDs = Set(try SetupOwnershipManager().readRecords(context: context).map(\.id))
    let legacyCodex = try hasCompleteLegacyIntegration(
      named: "Codex", requiredIDs: legacyCodexIDs, setupIDs: setupIDs)
    let legacyPi = try hasCompleteLegacyIntegration(
      named: "Pi", requiredIDs: legacyPiIDs, setupIDs: setupIDs)
    let legacyTuicr = try hasCompleteLegacyIntegration(
      named: "tuicr", requiredIDs: legacyTuicrIDs, setupIDs: setupIDs)

    var enabled: Set<String>
    if let ownership {
      enabled = appliedAdapterIDs(for: ownership)
    } else {
      enabled = Set(ThemeActivationCoordinator.adapterRequirements.keys)
      enabled.remove(CodexAdapter.id)
      enabled.remove(PiAdapter.id)
      enabled.remove(TuicrAdapter.id)
    }
    if legacyCodex { enabled.insert(CodexAdapter.id) }
    if legacyPi { enabled.insert(PiAdapter.id) }
    if legacyTuicr { enabled.insert(TuicrAdapter.id) }
    return enabled
  }

  static func appliedAdapterIDs(for ownership: EnvironmentOwnership) -> Set<String> {
    if let explicit = ownership.enabledThemeAdapterIDs {
      return Set(explicit)
    }
    var enabled = Set(ThemeActivationCoordinator.adapterRequirements.keys)
    enabled.remove(TuicrAdapter.id)
    if ownership.tuicrEnabled {
      enabled.insert(TuicrAdapter.id)
    }
    return enabled
  }

  static func activationCoordinator(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> ThemeActivationCoordinator {
    try ThemeActivationCoordinator(
      root: stateRoot,
      consumerPaths: Self.consumerPaths(
        stateRoot: stateRoot,
        consumerPaths: consumerPaths
      ),
      enabledAdapterIDs: enabledAdapterIDs(
        stateRoot: stateRoot,
        consumerPaths: consumerPaths
      ),
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

  static func consumerPaths(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> ThemeConsumerPaths {
    guard try EnvironmentStateStore(stateRoot: stateRoot).readOwnership() != nil else {
      return consumerPaths
    }
    return ThemeConsumerPaths(
      kittyConfigurationURL: consumerPaths.kittyConfigurationURL,
      sketchyBarConfigurationURL: consumerPaths.sketchyBarConfigurationURL,
      shellConfigurationURL: consumerPaths.shellConfigurationURL,
      ezaConfigurationDirectoryURL: consumerPaths.ezaConfigurationDirectoryURL,
      batConfigurationDirectoryURL: consumerPaths.batConfigurationDirectoryURL,
      batCacheDirectoryURL: consumerPaths.batCacheDirectoryURL,
      btopConfigurationDirectoryURL: consumerPaths.btopConfigurationDirectoryURL,
      yaziConfigurationDirectoryURL: consumerPaths.yaziConfigurationDirectoryURL,
      atuinConfigurationDirectoryURL: consumerPaths.atuinConfigurationDirectoryURL,
      neovimConfigurationDirectoryURL: consumerPaths.neovimConfigurationDirectoryURL,
      starshipConfigurationURL: consumerPaths.starshipConfigurationURL,
      starshipBehaviorURL: stateRoot.appending(
        path: "environment/current/starship/behavior.toml"
      ),
      piConfigurationDirectoryURL: consumerPaths.piConfigurationDirectoryURL,
      herdrConfigurationURL: consumerPaths.herdrConfigurationURL,
      tuicrConfigurationDirectoryURL: consumerPaths.tuicrConfigurationDirectoryURL,
      codexConfigurationDirectoryURL: consumerPaths.codexConfigurationDirectoryURL,
      spicetifyConfigurationDirectoryURL: consumerPaths.spicetifyConfigurationDirectoryURL
    )
  }

  static func enabledAdapterIDs(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> Set<String> {
    let home = consumerPaths.piConfigurationDirectoryURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try enabledAdapterIDs(stateRoot: stateRoot, homeDirectory: home)
  }

  static func piIsEnabled(stateRoot: URL, consumerPaths: ThemeConsumerPaths) throws -> Bool {
    try enabledAdapterIDs(stateRoot: stateRoot, consumerPaths: consumerPaths)
      .contains(PiAdapter.id)
  }

  static func piThemeLinkRefreshIsAllowed(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> Bool {
    let ownership = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    let home = consumerPaths.piConfigurationDirectoryURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let setupIDs = Set(
      try SetupOwnershipManager()
        .readRecords(context: SetupOwnershipManager.Context(homeDirectory: home))
        .map(\.id)
    )
    let legacyPi = try hasCompleteLegacyIntegration(
      named: "Pi", requiredIDs: legacyPiIDs, setupIDs: setupIDs)
    return ownership?.records.contains(where: { $0.id == .piTheme }) == true
      || legacyPi
  }

  private static func hasCompleteLegacyIntegration(
    named name: String,
    requiredIDs: Set<String>,
    setupIDs: Set<String>
  ) throws -> Bool {
    let present = setupIDs.intersection(requiredIDs)
    guard present.isEmpty || present == requiredIDs else {
      throw EnvironmentLifecycleError.blocked(
        "legacy setup-owned \(name) integration is incomplete: \(present.sorted().joined(separator: ", "))"
      )
    }
    return present == requiredIDs
  }
}
