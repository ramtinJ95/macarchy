import Foundation
import ThemeCore

enum ThemeRuntimeSelection {
  private static let legacyTuicrIDs = Set([
    SetupOwnershipManager.tuicrSelectorID,
    SetupOwnershipManager.tuicrThemeLinkID,
    SetupOwnershipManager.tuicrSyntaxLinkID,
  ])

  static func enabledAdapterIDs(stateRoot: URL, homeDirectory: URL) throws -> Set<String> {
    let ownership = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let legacy = Set(try SetupOwnershipManager().readRecords(context: context).map(\.id))
      .intersection(legacyTuicrIDs)
    guard legacy.isEmpty || legacy == legacyTuicrIDs else {
      throw EnvironmentLifecycleError.blocked(
        "legacy setup-owned tuicr integration is incomplete: \(legacy.sorted().joined(separator: ", "))"
      )
    }

    var enabled: Set<String>
    if let explicit = ownership?.enabledThemeAdapterIDs {
      enabled = Set(explicit)
    } else {
      enabled = Set(ThemeActivationCoordinator.adapterRequirements.keys)
      enabled.remove(TuicrAdapter.id)
      if ownership?.tuicrEnabled == true {
        enabled.insert(TuicrAdapter.id)
      }
    }
    if legacy == legacyTuicrIDs {
      enabled.insert(TuicrAdapter.id)
    }
    return enabled
  }

  static func enabledAdapterIDs(
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths
  ) throws -> Set<String> {
    let home = consumerPaths.tuicrConfigurationDirectoryURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try enabledAdapterIDs(stateRoot: stateRoot, homeDirectory: home)
  }
}
