import Foundation
import ThemeCore

enum ThemeBrowserDeletionAvailability: Sendable {
  case available(ThemePackageDeletionTarget)
  case unavailable(String)

  var target: ThemePackageDeletionTarget? {
    if case .available(let target) = self { return target }
    return nil
  }

  var explanation: String {
    switch self {
    case .available:
      "Delete Theme moves this user-library package to Trash."
    case .unavailable(let reason):
      reason
    }
  }
}

enum ThemeBrowserDeletionOutcome: Sendable {
  case cancelled
  case failed(String)
  case deleted(ThemeBrowserContent)
  case deletedButRefreshFailed(String)
}

struct ThemeBrowserDeletionRunner: Sendable {
  let activeThemeID: @Sendable (URL) throws -> String?
  let moveToTrash: @Sendable (URL) throws -> Void
  let loadContent: @Sendable (ThemeRepository, URL) throws -> ThemeBrowserContent

  static let live = ThemeBrowserDeletionRunner(
    activeThemeID: { try ThemeBrowserCommandLoader.live.loadActiveManifest($0)?.themeID },
    moveToTrash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
    loadContent: { try ThemeBrowserCommandLoader.live.load(repository: $0, stateRoot: $1) }
  )

  func execute(
    target: ThemePackageDeletionTarget,
    repository: ThemeRepository,
    stateRoot: URL
  ) async -> ThemeBrowserDeletionOutcome {
    do {
      return try await ThemePackageLock(root: stateRoot).withLock {
        try repository.validateDeletionTarget(target)
        guard try activeThemeID(stateRoot) != target.themeID else {
          return .failed("Apply another theme before deleting the active theme.")
        }
        try moveToTrash(target.packageURL)
        // A committed deletion must never be reported as an unchanged-library
        // failure merely because a later inventory/preview read failed.
        do {
          return .deleted(try loadContent(repository, stateRoot))
        } catch {
          return .deletedButRefreshFailed(String(describing: error))
        }
      }
    } catch {
      return .failed(String(describing: error))
    }
  }
}
