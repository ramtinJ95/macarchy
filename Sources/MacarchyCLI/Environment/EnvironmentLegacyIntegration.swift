import ThemeCore

// Validation is pure; callers retain their own inspection and filesystem-read order.
// Each preset declares its legacy setup records in `EnvironmentPreset.legacyIntegration`.
enum EnvironmentLegacyIntegration {
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
