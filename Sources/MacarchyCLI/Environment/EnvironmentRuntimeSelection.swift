import Foundation
import ThemeCore

enum ThemeRuntimeSelection {
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
    let legacyPi = setupIDs.intersection(legacyPiIDs)
    guard legacyPi.isEmpty || legacyPi == legacyPiIDs else {
      throw EnvironmentLifecycleError.blocked(
        "legacy setup-owned Pi integration is incomplete: \(legacyPi.sorted().joined(separator: ", "))"
      )
    }
    let legacy =
      setupIDs
      .intersection(legacyTuicrIDs)
    guard legacy.isEmpty || legacy == legacyTuicrIDs else {
      throw EnvironmentLifecycleError.blocked(
        "legacy setup-owned tuicr integration is incomplete: \(legacy.sorted().joined(separator: ", "))"
      )
    }

    var enabled: Set<String>
    if let explicit = ownership?.enabledThemeAdapterIDs {
      enabled = Set(explicit)
    } else if ownership != nil {
      enabled = Set(ThemeActivationCoordinator.adapterRequirements.keys)
      enabled.remove(TuicrAdapter.id)
      if ownership?.tuicrEnabled == true {
        enabled.insert(TuicrAdapter.id)
      }
    } else {
      enabled = Set(ThemeActivationCoordinator.adapterRequirements.keys)
      enabled.remove(PiAdapter.id)
      enabled.remove(TuicrAdapter.id)
    }
    if legacy == legacyTuicrIDs {
      enabled.insert(TuicrAdapter.id)
    }
    if legacyPi == legacyPiIDs { enabled.insert(PiAdapter.id) }
    return enabled
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
    let legacyPi = setupIDs.intersection(legacyPiIDs)
    guard legacyPi.isEmpty || legacyPi == legacyPiIDs else {
      throw EnvironmentLifecycleError.blocked(
        "legacy setup-owned Pi integration is incomplete: \(legacyPi.sorted().joined(separator: ", "))"
      )
    }
    return ownership?.records.contains(where: { $0.id == .piTheme }) == true
      || legacyPi == legacyPiIDs
  }
}
