import ThemeCore

// Validation is pure; callers retain their own inspection and filesystem-read order.
enum EnvironmentLegacyIntegration {
  static let codexIDs = Set([
    SetupOwnershipManager.codexSelectorID,
    SetupOwnershipManager.codexThemeLinkID,
  ])
  static let piIDs = Set([
    SetupOwnershipManager.piSelectorID,
    SetupOwnershipManager.piThemeLinkID,
  ])
  static let spicetifyIDs = Set([
    SetupOwnershipManager.spicetifySelectorsID,
    SetupOwnershipManager.spicetifyColorLinkID,
  ])
  static let tuicrIDs = Set([
    SetupOwnershipManager.tuicrSelectorID,
    SetupOwnershipManager.tuicrThemeLinkID,
    SetupOwnershipManager.tuicrSyntaxLinkID,
  ])

  static func hasCompleteLegacyIntegration(
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
