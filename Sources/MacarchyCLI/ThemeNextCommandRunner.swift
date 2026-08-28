import Foundation
import ThemeCore

enum ThemeNextError: Error, CustomStringConvertible, Equatable {
  case noActiveTheme
  case activeThemeUnavailable(String)

  var description: String {
    switch self {
    case .noActiveTheme:
      "No active theme; activate one with 'macarchy theme set <theme-id>'"
    case .activeThemeUnavailable(let themeID):
      "Active theme '\(themeID)' is not available; cannot determine the next theme"
    }
  }
}

struct ThemeNextCommandRunner: Sendable {
  let activeManifest: @Sendable (URL) throws -> GenerationManifest
  let activation: ThemeSetCommandRunner

  static let live = ThemeNextCommandRunner(
    activeManifest: { root in
      try ReconciliationStatusStore(root: root).activeManifest()
    },
    activation: .live
  )

  func execute(
    repository: ThemeRepository,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let run: @Sendable () async throws -> (output: String, succeeded: Bool) = {
      let packages = try repository.packages()
      while true {
        let active: GenerationManifest
        do {
          active = try activeManifest(stateRoot)
        } catch ReconciliationStatusError.noActiveGeneration {
          throw ThemeNextError.noActiveTheme
        }
        guard let activeIndex = packages.firstIndex(where: { $0.id == active.themeID }) else {
          throw ThemeNextError.activeThemeUnavailable(active.themeID)
        }
        let package = packages[(activeIndex + 1) % packages.count]
        do {
          return try await activation.execute(
            package: package,
            stateRoot: stateRoot,
            consumerPaths: consumerPaths,
            dryRun: dryRun,
            expectedActiveGenerationID: dryRun ? nil : active.generationID,
            json: false
          )
        } catch ThemeActivationError.activeGenerationChanged {
          continue
        }
      }
    }
    if dryRun { return try await run() }
    return try await ThemePackageLock(root: stateRoot).withLock(run)
  }
}
