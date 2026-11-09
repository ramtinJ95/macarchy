import Foundation
import ThemeCore

/// Reads and sets macOS Light/Dark appearance for setup teardown.
struct SetupAppearanceControl: Sendable {
  let read: @Sendable () throws -> ThemeAppearance
  let apply: @Sendable (ThemeAppearance) throws -> AdapterResult

  init(
    read: @escaping @Sendable () throws -> ThemeAppearance,
    apply: @escaping @Sendable (ThemeAppearance) throws -> AdapterResult
  ) {
    self.read = read
    self.apply = apply
  }

  init(_ adapter: MacOSAppearanceAdapter) {
    self.init(
      read: { try adapter.preflight() },
      apply: { try adapter.applyHoldingActivationLock($0) })
  }
}

/// Setup teardown's theme stage: puts macOS appearance and each display's wallpaper back by the
/// three-way rule, then removes the setup-owned canonical theme. A value that is still
/// Macarchy's returns to the original, one that already is the original stays, and one the user
/// changed since stays and is reported (ADR-0300).
struct SetupThemeTeardown: Sendable {
  let appearance: @Sendable (URL) -> SetupAppearanceControl
  let wallpaper: @Sendable (URL) -> WallpaperOriginalRestorer
  var iconStyle: @Sendable (URL) -> MacOSIconStyleAdapter = { MacOSIconStyleAdapter(root: $0) }
  var accent: @Sendable (URL) -> MacOSAccentAdapter = { MacOSAccentAdapter(root: $0) }

  static let live = Self(
    appearance: { SetupAppearanceControl(MacOSAppearanceAdapter.live(root: $0)) },
    wallpaper: { WallpaperOriginalRestorer.live(root: $0) }
  )

  /// The bootstrap receipt authorizes retirement, not the generation to remove.
  /// The active generation supplies Macarchy's appearance; the caller's observation guards
  /// the interval between aggregate preflight and retirement. Rollback callers retain the
  /// bootstrap generation guard instead of adopting a concurrent replacement.
  func run(
    stateRoot: URL,
    ownership: SetupCoreOwnership?,
    expectedGenerationID: String? = nil,
    dryRun: Bool
  ) async throws -> UnifiedSetupTeardownStage {
    guard let ownership else {
      // Look receipts also have ownership when setup preserved an external canonical theme.
      var reports: [MacOSLookRestore] = []
      do {
        guard
          try MacOSAccentStore(root: stateRoot).load() != nil
            || MacOSIconStyleStore(root: stateRoot).load() != nil
        else { return .noChange("No setup-owned canonical theme exists.") }
        try ActivationLock(root: stateRoot).withLock {
          let accent = try self.accent(stateRoot).restoreHoldingActivationLock(dryRun: dryRun)
          reports.append(accent)
          let icons = try self.iconStyle(stateRoot).restoreHoldingActivationLock(dryRun: dryRun)
          reports.append(icons)
          if !dryRun {
            if accent.consumesRecord { try MacOSAccentStore(root: stateRoot).remove() }
            if icons.consumesRecord { try MacOSIconStyleStore(root: stateRoot).remove() }
          }
        }
        guard reports.contains(where: { $0.consumesRecord }) else {
          return .noChange("No setup-owned canonical theme exists.")
        }
        return UnifiedSetupTeardownStage(
          succeeded: true, mutated: reports.contains(where: { $0.mutated }),
          outcome: dryRun ? "planned" : "restored",
          message: Self.message(
            "No setup-owned canonical theme exists; the external theme is preserved.",
            reports.compactMap(\.message)))

      } catch {
        return UnifiedSetupTeardownStage(
          succeeded: false, mutated: reports.contains(where: { $0.mutated }), outcome: "blocked",
          message: Self.message(
            "macOS look restoration failed: \(error)", reports.compactMap(\.message)))
      }
    }
    let activator = ThemeActivator(root: stateRoot)
    let active = try ThemeGenerationReader(root: stateRoot).activeManifest()
    let expected = expectedGenerationID ?? active.generationID
    // Refuse invalid or concurrently replaced canonical state before any native access.
    _ = try activator.deactivate(expectedGenerationID: expected, dryRun: true)
    let appliedAppearance = try active.normalizedTheme(root: stateRoot).appearance
    let appearance = appearance(stateRoot)
    let currentAppearance = try appearance.read()
    let originalAppearance = ownership.originalAppearance
    var restoresAppearance = currentAppearance == appliedAppearance
    var notes: [String] = []
    if !restoresAppearance && currentAppearance != originalAppearance {
      notes.append(
        "Kept the macOS \(currentAppearance.rawValue) appearance, which was changed after setup.")
    }
    let wallpaper = wallpaper(stateRoot)
    let accent = accent(stateRoot)
    let iconStyle = iconStyle(stateRoot)
    let scripts: [String]
    do {
      scripts =
        try UnifiedSetupTransactionStore(stateRoot: stateRoot).read()?.userScripts
        ?? EnvironmentStateStore(stateRoot: stateRoot).readOwnership()?.userScripts ?? []
    } catch {
      scripts = []
      notes.append("Could not read applied user scripts: \(error)")
    }

    if dryRun {
      do {
        if let message = try accent.restorationPlan().message { notes.append(message) }
        if let message = try iconStyle.restorationPlan().message { notes.append(message) }
      } catch {
        return UnifiedSetupTeardownStage(
          succeeded: false, mutated: false, outcome: "blocked",
          message: "macOS look restoration blocked: \(error)")
      }
      if !scripts.isEmpty {
        notes.append("Would run \(scripts.count) user scripts with the teardown event.")
      }
      let summary =
        restoresAppearance
        ? "Would restore macOS appearance and remove the setup-owned canonical theme."
        : "Would remove the setup-owned canonical theme."
      return UnifiedSetupTeardownStage(
        succeeded: true,
        mutated: false,
        outcome: "planned",
        message: Self.message(summary, notes + wallpaper.plan().lines),
        plannedThemeGenerationID: expected
      )
    }

    var mutated = false
    if !scripts.isEmpty {
      do {
        let report = try UserScriptsAdapter(
          root: stateRoot, mode: UserScriptsMode(scripts: scripts.map { URL(filePath: $0) })
        ).run(event: .teardown)
        notes.append(report.message)
      } catch {
        notes.append("User scripts failed: \(error)")
      }
    }
    // Wallpaper is restored under the activation lock right before the theme is retired, so no
    // reconciliation can put Macarchy's wallpaper back in between. Its record is removed only
    // once the theme is retired; until then it is still the evidence a retry needs.
    var wallpaperReport: WallpaperRestoreReport?
    var accentReport: MacOSLookRestore?
    var iconReport: MacOSLookRestore?
    let cleanupError: String?
    do {
      cleanupError = try activator.deactivate(
        expectedGenerationID: expected,
        dryRun: false,
        beforeRetiringLocked: {
          // Re-read under the retirement lock: neither theme reconciliation nor a concurrent
          // activation may slip between the three-way decision and appearance restoration.
          let current = try appearance.read()
          restoresAppearance = current == appliedAppearance
          notes.removeAll { $0.hasPrefix("Kept the macOS ") }
          if restoresAppearance && current != originalAppearance {
            mutated = true
            let result = try appearance.apply(originalAppearance)
            guard result.status == .applied else {
              throw SetupCoreOwnershipError.invalid(
                result.message ?? "macOS appearance restoration failed.")
            }
          } else if current != originalAppearance {
            notes.append(
              "Kept the macOS \(current.rawValue) appearance, which was changed after setup.")
          }
          accentReport = try accent.restoreHoldingActivationLock()
          iconReport = try iconStyle.restoreHoldingActivationLock()
          wallpaperReport = wallpaper.restoreHoldingActivationLock()
        }
      )
    } catch {
      return UnifiedSetupTeardownStage(
        succeeded: false,
        mutated: mutated || (wallpaperReport?.mutated ?? false) || (accentReport?.mutated ?? false)
          || (iconReport?.mutated ?? false),
        outcome: "failed",
        message: Self.message(
          "Canonical theme removal failed: \(error)", notes + (wallpaperReport?.lines ?? []))
      )
    }
    if let message = accentReport?.message { notes.append(message) }
    if let message = iconReport?.message { notes.append(message) }
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
    if let report = accentReport {
      if report.consumesRecord {
        do { try MacOSAccentStore(root: stateRoot).remove() } catch {
          return UnifiedSetupTeardownStage(
            succeeded: false, mutated: true, outcome: "recovery_required",
            message: "Accent restoration record cleanup failed: \(error)")
        }
      }
    }
    if let report = iconReport {
      if report.consumesRecord {
        do { try MacOSIconStyleStore(root: stateRoot).remove() } catch {
          return UnifiedSetupTeardownStage(
            succeeded: false, mutated: true, outcome: "recovery_required",
            message: "Icon style restoration record cleanup failed: \(error)")
        }
      }
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
