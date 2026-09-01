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
  let preflight: @Sendable (ThemePackage, String, URL, ThemeConsumerPaths) throws -> Void
  let activate:
    @Sendable (ThemePackage, String, URL, ThemeConsumerPaths, String) async throws
      -> ThemeActivationResult

  static let live = ThemeBackgroundCommandRunner(
    activeManifest: { root in
      try ReconciliationStatusStore(root: root).activeManifest()
    },
    preflight: { package, backgroundID, root, consumerPaths in
      try ThemeActivationCoordinator(root: root, consumerPaths: consumerPaths).preflight(
        package: package,
        requestedBackgroundID: backgroundID
      )
    },
    activate: { package, backgroundID, root, consumerPaths, expectedGenerationID in
      try await ThemeActivationCoordinator(root: root, consumerPaths: consumerPaths).activate(
        package: package,
        expectedActiveGenerationID: expectedGenerationID,
        requestedBackgroundID: backgroundID
      )
    }
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
  ) async throws -> (output: String, succeeded: Bool) {
    let operation: @Sendable () async throws -> (output: String, succeeded: Bool) = {
      while true {
        let active = try currentManifest(stateRoot: stateRoot)
        let package = try repository.package(id: active.themeID)
        do {
          return try await apply(
            package: package,
            backgroundID: backgroundID,
            stateRoot: stateRoot,
            consumerPaths: consumerPaths,
            dryRun: dryRun,
            expectedGenerationID: active.generationID
          )
        } catch ThemeActivationError.activeGenerationChanged {
          continue
        }
      }
    }
    if dryRun { return try await operation() }
    return try await ThemePackageLock(root: stateRoot).withLock(operation)
  }

  func next(
    repository: ThemeRepository,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let operation: @Sendable () async throws -> (output: String, succeeded: Bool) = {
      while true {
        let active = try currentManifest(stateRoot: stateRoot)
        let package = try repository.package(id: active.themeID)
        let effectivePackage = try configuredPackage(
          package,
          stateRoot: stateRoot
        )
        guard !effectivePackage.backgrounds.isEmpty else {
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
          backgroundID = effectivePackage.backgrounds[0].id
        }

        do {
          return try await apply(
            package: package,
            backgroundID: backgroundID,
            stateRoot: stateRoot,
            consumerPaths: consumerPaths,
            dryRun: dryRun,
            expectedGenerationID: active.generationID
          )
        } catch ThemeActivationError.activeGenerationChanged {
          continue
        }
      }
    }
    if dryRun { return try await operation() }
    return try await ThemePackageLock(root: stateRoot).withLock(operation)
  }

  private func apply(
    package: ThemePackage,
    backgroundID: String,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    expectedGenerationID: String
  ) async throws -> (output: String, succeeded: Bool) {
    if dryRun {
      try preflight(package, backgroundID, stateRoot, consumerPaths)
      return (
        "Background '\(backgroundID)' for theme '\(package.id)' is valid.\n"
          + "Canonical state: unchanged (dry run).",
        true
      )
    }

    let result: ThemeActivationResult
    do {
      result = try await activate(
        package,
        backgroundID,
        stateRoot,
        consumerPaths,
        expectedGenerationID
      )
    } catch let error as ThemeCommittedActivationError {
      return (
        committedFailure(
          manifest: error.manifest,
          backgroundID: backgroundID,
          cause: "Postcommit activation work could not complete: \(error.cause)"
        ),
        false
      )
    } catch let error as ThemeCommittedWithReconciliationError {
      return (
        committedFailure(
          manifest: error.manifest,
          backgroundID: backgroundID,
          cause: "Reconciliation could not complete: \(error.cause)"
        ),
        false
      )
    }
    var lines = [
      "Activated background '\(backgroundID)' for theme '\(package.id)' as generation "
        + "'\(result.manifest.generationID)'."
    ]
    if let notice = result.notice { lines.append("Notice: \(notice)") }
    lines.append("Reconciliation:")
    lines.append(contentsOf: result.reconciliation.results.map(renderAdapterResult))
    let succeeded = !hasRequiredReconciliationFailure(result.reconciliation.results)
    if !succeeded {
      lines.append("Required reconciliation failed; the commit was not rolled back.")
    }
    return (lines.joined(separator: "\n"), succeeded)
  }

  private func committedFailure(
    manifest: GenerationManifest,
    backgroundID: String,
    cause: String
  ) -> String {
    [
      "Committed background '\(backgroundID)' for theme '\(manifest.themeID)' as generation "
        + "'\(manifest.generationID)'.",
      cause,
      "The commit was not rolled back.",
    ].joined(separator: "\n")
  }

  private func currentManifest(stateRoot: URL) throws -> GenerationManifest {
    do {
      return try activeManifest(stateRoot)
    } catch ReconciliationStatusError.noActiveGeneration {
      throw ThemeBackgroundCommandError.noActiveTheme
    }
  }

  private func configuredPackage(_ package: ThemePackage, stateRoot: URL) throws -> ThemePackage {
    try MacarchyConfigurationStore(root: stateRoot).addingPersonalBackgrounds(to: package)
  }
}
