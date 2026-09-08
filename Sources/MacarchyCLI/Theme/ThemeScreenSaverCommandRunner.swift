import Foundation
import ThemeCore

struct ThemeScreenSaverCommandRunner: Sendable {
  func execute(
    repository: ThemeRepository,
    stateRoot: URL,
    themeID: String?,
    backgroundID: String?,
    followWallpaper: Bool
  ) async throws -> String {
    try await ThemePackageLock(root: stateRoot).withLock {
      let images = ScreenSaverImageStore(root: stateRoot)
      guard backgroundID != nil || followWallpaper else { return try images.reconcile() }
      let selectedThemeID =
        try themeID
        ?? ReconciliationStatusStore(root: stateRoot).activeManifest().themeID
      let preferences = ScreenSaverPreferenceStore(root: stateRoot)
      if let backgroundID {
        let package = try MacarchyConfigurationStore(root: stateRoot).addingPersonalBackgrounds(
          to: repository.package(id: selectedThemeID))
        try preferences.select(package: package, backgroundID: backgroundID)
      } else {
        try preferences.followWallpaper(themeID: selectedThemeID)
      }
      let saved =
        backgroundID.map { "Saved screensaver image '\($0)' for '\(selectedThemeID)'." }
        ?? "Screensaver for '\(selectedThemeID)' now follows its wallpaper."
      do {
        let active: GenerationManifest?
        do {
          active = try ReconciliationStatusStore(root: stateRoot).activeManifest()
        } catch ReconciliationStatusError.noActiveGeneration {
          active = nil
        }
        guard active?.themeID == selectedThemeID else {
          return saved
            + " It will be used when this theme is active. Theme and wallpaper unchanged."
        }
        return saved + " " + (try images.reconcile()) + " Theme and wallpaper unchanged."
      } catch {
        throw ThemeScreenSaverCommandError.exportFailedAfterSave(saved, String(describing: error))
      }
    }
  }
}

enum ThemeScreenSaverCommandError: Error, CustomStringConvertible {
  case exportFailedAfterSave(String, String)

  var description: String {
    switch self {
    case .exportFailedAfterSave(let saved, let reason):
      saved + " Photos export failed: " + reason
        + ". The selection was retained; run macarchy theme screensaver to retry."
    }
  }
}
