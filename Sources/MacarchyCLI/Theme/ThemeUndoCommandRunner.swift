import Foundation
import ThemeCore

enum ThemeUndoError: Error, CustomStringConvertible, Equatable {
  case noActiveTheme
  case nothingToUndo

  var description: String {
    switch self {
    case .noActiveTheme:
      "No active theme; activate one with 'macarchy theme set <theme-id>'"
    case .nothingToUndo:
      "Nothing to undo: the theme history has no earlier theme or background"
    }
  }
}

/// The undo's text output, whether it succeeded, and the activation notice that a menu
/// launch, which has no terminal, shows in an alert.
struct ThemeUndoExecution: Sendable {
  let output: String
  let succeeded: Bool
  let notice: String?

  var command: CommandExecution { (output, succeeded) }
}

/// `theme undo`: activates the newest recorded selection that differs from the active one,
/// through the same activation as `theme set`, and drops the undone history entries once that
/// activation commits. There is no redo.
struct ThemeUndoCommandRunner: Sendable {
  let activeManifest: @Sendable (URL) throws -> GenerationManifest
  let loadHistory: @Sendable (URL) throws -> [ThemeHistoryEntry]
  let activation: ThemeActivationService

  static let live = ThemeUndoCommandRunner(
    activeManifest: { try ThemeGenerationReader(root: $0).activeManifest() },
    loadHistory: { try ThemeHistoryStore(root: $0).load() },
    activation: .live
  )

  func execute(
    repository: ThemeRepository,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool
  ) async throws -> ThemeUndoExecution {
    try await withThemePackageLock(stateRoot: stateRoot, unlessDryRun: dryRun) {
      try await retryingActiveGenerationChanges {
        let active: GenerationManifest
        do {
          active = try activeManifest(stateRoot)
        } catch ReconciliationStatusError.noActiveGeneration {
          throw ThemeUndoError.noActiveTheme
        }
        guard
          let step = ThemeHistory.undoStep(
            try loadHistory(stateRoot),
            activeThemeID: active.themeID,
            activeBackgroundID: active.background?.id
          )
        else {
          throw ThemeUndoError.nothingToUndo
        }
        let report = try await activation.reportLocked(
          package: try repository.package(id: step.target.themeID),
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          dryRun: dryRun,
          expectedActiveGenerationID: dryRun ? nil : active.generationID,
          requestedBackgroundID: step.target.backgroundID,
          historyUpdate: .undo(remaining: step.remaining)
        )
        let execution = try report.execution(json: false)
        return ThemeUndoExecution(
          output: Self.headline(step.target, dryRun: dryRun) + "\n" + execution.output,
          succeeded: execution.succeeded,
          notice: report.jsonReport.notice
        )
      }
    }
  }

  private static func headline(_ target: ThemeHistoryEntry, dryRun: Bool) -> String {
    let selection =
      target.backgroundID.map { "theme '\(target.themeID)' with background '\($0)'" }
      ?? "theme '\(target.themeID)'"
    return dryRun ? "Undo would return to \(selection)." : "Undo: returning to \(selection)."
  }
}
