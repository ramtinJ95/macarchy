import Foundation
import ThemeCore

enum ThemeBackgroundCommandError: Error, CustomStringConvertible, Equatable {
  case activeBackgroundUnavailable(themeID: String, backgroundID: String)
  case legacyGeneration
  case noActiveTheme

  var description: String {
    switch self {
    case .activeBackgroundUnavailable(let themeID, let backgroundID):
      "Active background '\(backgroundID)' is no longer available in theme '\(themeID)'"
    case .legacyGeneration:
      "The active generation predates recorded background identity; reactivate its theme first"
    case .noActiveTheme:
      "No active theme; activate one with 'macarchy theme set <theme-id>'"
    }
  }
}

struct ThemeBackgroundCommandRunner: Sendable {
  let activeManifest: @Sendable (URL) throws -> GenerationManifest
  let activation: ThemeActivationService

  static let live = ThemeBackgroundCommandRunner(
    activeManifest: { root in
      try ThemeGenerationReader(root: root).activeManifest()
    },
    activation: .live
  )

  func current(stateRoot: URL) throws -> String {
    let manifest = try currentManifest(stateRoot: stateRoot)
    guard manifest.manifestSchemaVersion == GenerationManifest.currentSchemaVersion else {
      throw ThemeBackgroundCommandError.legacyGeneration
    }
    guard let background = manifest.background else { return "unmanaged" }
    return "\(background.id)\t\(background.format.rawValue)"
  }

  func set(
    repository: ThemeRepository,
    backgroundID: String,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool
  ) async throws -> CommandExecution {
    try await withThemePackageLock(stateRoot: stateRoot, unlessDryRun: dryRun) {
      try await retryingActiveGenerationChanges {
        let active = try currentManifest(stateRoot: stateRoot)
        return try await applyLocked(
          package: try repository.package(id: active.themeID),
          backgroundID: backgroundID,
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          dryRun: dryRun,
          expectedGenerationID: active.generationID
        )
      }
    }
  }

  func next(
    repository: ThemeRepository,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool
  ) async throws -> CommandExecution {
    try await withThemePackageLock(stateRoot: stateRoot, unlessDryRun: dryRun) {
      try await retryingActiveGenerationChanges {
        let active = try currentManifest(stateRoot: stateRoot)
        let package = try repository.package(id: active.themeID)
        let effectivePackage = try MacarchyConfigurationStore(root: stateRoot)
          .addingPersonalBackgrounds(to: package)
        guard let defaultBackground = effectivePackage.defaultBackground else {
          throw BackgroundSelectionError.noBackgrounds(themeID: effectivePackage.id)
        }
        let backgroundID: String
        if let currentID = active.background?.id {
          guard
            let currentIndex = effectivePackage.backgrounds.firstIndex(where: {
              $0.id == currentID
            })
          else {
            throw ThemeBackgroundCommandError.activeBackgroundUnavailable(
              themeID: effectivePackage.id,
              backgroundID: currentID
            )
          }
          backgroundID =
            effectivePackage.backgrounds[(currentIndex + 1) % effectivePackage.backgrounds.count].id
        } else {
          backgroundID = defaultBackground.id
        }
        return try await applyLocked(
          package: package,
          backgroundID: backgroundID,
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          dryRun: dryRun,
          expectedGenerationID: active.generationID
        )
      }
    }
  }

  private func applyLocked(
    package: ThemePackage,
    backgroundID: String,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    expectedGenerationID: String
  ) async throws -> CommandExecution {
    if dryRun {
      try activation.review(package, backgroundID, stateRoot, consumerPaths).requireApplicable()
      return (
        "Background '\(backgroundID)' for theme '\(package.id)' is valid.\n"
          + "Canonical state: unchanged (dry run).",
        true
      )
    }

    let outcome = try await activation.activateLocked(
      package: package,
      backgroundID: backgroundID,
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      expectedActiveGenerationID: expectedGenerationID
    )
    switch outcome {
    case .precommitFailure(let error):
      throw error
    case .committedActivationError(let manifest, let cause):
      return (
        committedFailure(
          manifest: manifest,
          backgroundID: backgroundID,
          cause: "Postcommit activation work could not complete: \(cause)"
        ),
        false
      )
    case .committedReconciliationError(let manifest, let cause):
      return (
        committedFailure(
          manifest: manifest,
          backgroundID: backgroundID,
          cause: "Reconciliation could not complete: \(cause)"
        ),
        false
      )
    case .committed(let result, let requiredFailure):
      let lines = renderCommittedActivation(
        headline:
          "Activated background '\(backgroundID)' for theme '\(package.id)' as generation "
          + "'\(result.manifest.generationID)'.",
        result: result, requiredFailure: requiredFailure)
      return (lines.joined(separator: "\n"), !requiredFailure)
    }
  }

  private func committedFailure(
    manifest: GenerationManifest,
    backgroundID: String,
    cause: String
  ) -> String {
    renderCommittedFailure(
      headline:
        "Committed background '\(backgroundID)' for theme '\(manifest.themeID)' as generation "
        + "'\(manifest.generationID)'.",
      cause: cause
    ).joined(separator: "\n")
  }

  private func currentManifest(stateRoot: URL) throws -> GenerationManifest {
    do {
      return try activeManifest(stateRoot)
    } catch ReconciliationStatusError.noActiveGeneration {
      throw ThemeBackgroundCommandError.noActiveTheme
    }
  }
}
