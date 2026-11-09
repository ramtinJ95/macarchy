import Foundation
import ThemeCore

/// Reads and sets macOS Light/Dark appearance for setup teardown.
struct SetupAppearanceControl: Sendable {
  let read: @Sendable () throws -> ThemeAppearance
  let apply: @Sendable (ThemeAppearance) async throws -> AdapterResult

  init(
    read: @escaping @Sendable () throws -> ThemeAppearance,
    apply: @escaping @Sendable (ThemeAppearance) async throws -> AdapterResult
  ) {
    self.read = read
    self.apply = apply
  }

  init(_ adapter: MacOSAppearanceAdapter) {
    self.init(read: { try adapter.preflight() }, apply: { try await adapter.apply($0) })
  }
}

/// Setup teardown's theme stage: puts macOS appearance and each display's wallpaper back by the
/// three-way rule, then removes the setup-owned canonical theme. A value that is still
/// Macarchy's returns to the original, one that already is the original stays, and one the user
/// changed since stays and is reported (ADR-0300).
struct SetupThemeTeardown: Sendable {
  let appearance: @Sendable (URL) -> SetupAppearanceControl
  let wallpaper: @Sendable (URL) -> WallpaperOriginalRestorer

  static let live = Self(
    appearance: { SetupAppearanceControl(MacOSAppearanceAdapter.live(root: $0)) },
    wallpaper: { WallpaperOriginalRestorer.live(root: $0) }
  )

  /// `desiredAppearance` is the appearance of the setup-owned theme, Macarchy's value.
  func run(
    stateRoot: URL,
    ownership: SetupCoreOwnership?,
    desiredAppearance: ThemeAppearance,
    dryRun: Bool
  ) async throws -> UnifiedSetupTeardownStage {
    guard let ownership else {
      return .noChange("No setup-owned canonical theme exists.")
    }
    let activator = ThemeActivator(root: stateRoot)
    // Refuses a replaced theme before any native appearance or wallpaper access.
    _ = try activator.deactivate(
      expectedGenerationID: ownership.themeGenerationID,
      dryRun: true
    )
    let appearance = appearance(stateRoot)
    let currentAppearance = try appearance.read()
    let originalAppearance = ownership.originalAppearance
    let restoresAppearance = currentAppearance == desiredAppearance
    var notes: [String] = []
    if !restoresAppearance && currentAppearance != originalAppearance {
      notes.append(
        "Kept the macOS \(currentAppearance.rawValue) appearance, which was changed after setup.")
    }
    let wallpaper = wallpaper(stateRoot)

    if dryRun {
      let summary =
        restoresAppearance
        ? "Would restore macOS appearance and remove the setup-owned canonical theme."
        : "Would remove the setup-owned canonical theme."
      return UnifiedSetupTeardownStage(
        succeeded: true,
        mutated: false,
        outcome: "planned",
        message: Self.message(summary, notes + wallpaper.plan().lines)
      )
    }

    var mutated = false
    if restoresAppearance {
      let appearanceChanged = currentAppearance != originalAppearance
      let appearanceResult: AdapterResult
      do {
        appearanceResult = try await appearance.apply(originalAppearance)
      } catch {
        return UnifiedSetupTeardownStage(
          succeeded: false,
          mutated: appearanceChanged,
          outcome: "failed",
          message: "macOS appearance restoration failed: \(error)"
        )
      }
      guard appearanceResult.status == .applied else {
        return UnifiedSetupTeardownStage(
          succeeded: false,
          mutated: appearanceChanged,
          outcome: "failed",
          message: appearanceResult.message ?? "macOS appearance restoration failed."
        )
      }
      mutated = appearanceChanged
    }
    // Wallpaper is restored under the activation lock right before the theme is retired, so no
    // reconciliation can put Macarchy's wallpaper back in between. Its record is removed only
    // once the theme is retired; until then it is still the evidence a retry needs.
    var wallpaperReport: WallpaperRestoreReport?
    let cleanupError: String?
    do {
      cleanupError = try activator.deactivate(
        expectedGenerationID: ownership.themeGenerationID,
        dryRun: false,
        beforeRetiringLocked: { wallpaperReport = wallpaper.restoreHoldingActivationLock() }
      )
    } catch {
      return UnifiedSetupTeardownStage(
        succeeded: false,
        mutated: mutated || (wallpaperReport?.mutated ?? false),
        outcome: "failed",
        message: Self.message(
          "Canonical theme removal failed: \(error)", notes + (wallpaperReport?.lines ?? []))
      )
    }
    if let report = wallpaperReport {
      notes += wallpaper.removeRecord(after: report).lines
    }
    if let cleanupError {
      return UnifiedSetupTeardownStage(
        succeeded: false,
        mutated: true,
        outcome: "recovery_required",
        message: Self.message(
          "Canonical theme was removed, but cleanup remains: \(cleanupError).", notes)
      )
    }
    do {
      try SetupCoreOwnershipStore(stateRoot: stateRoot).remove()
    } catch {
      return UnifiedSetupTeardownStage(
        succeeded: false,
        mutated: true,
        outcome: "recovery_required",
        message: Self.message(
          "Canonical theme was removed, but setup ownership cleanup failed: \(error)", notes)
      )
    }
    let summary =
      restoresAppearance
      ? "Restored macOS appearance and removed the setup-owned canonical theme."
      : "Removed the setup-owned canonical theme."
    return UnifiedSetupTeardownStage(
      succeeded: true,
      mutated: true,
      outcome: "restored",
      message: Self.message(summary, notes)
    )
  }

  private static func message(_ summary: String, _ notes: [String]) -> String {
    ([summary] + notes).joined(separator: " ")
  }
}
