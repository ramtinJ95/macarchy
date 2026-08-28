import Foundation
import ThemeCore

struct ThemeSetCommandRunner: Sendable {
  let preflight: @Sendable (ThemePackage, URL, ThemeConsumerPaths) throws -> Void
  let activate:
    @Sendable (ThemePackage, URL, ThemeConsumerPaths, String?) async throws -> ThemeActivationResult

  static let live = ThemeSetCommandRunner(
    preflight: { package, stateRoot, consumerPaths in
      try ThemeActivationCoordinator(
        root: stateRoot,
        consumerPaths: consumerPaths
      ).preflight(package: package)
    },
    activate: { package, stateRoot, consumerPaths, expectedActiveGenerationID in
      try await ThemeActivationCoordinator(
        root: stateRoot,
        consumerPaths: consumerPaths
      ).activate(
        package: package,
        expectedActiveGenerationID: expectedActiveGenerationID
      )
    }
  )

  func execute(
    repository: ThemeRepository,
    themeID: String,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let run: @Sendable () async throws -> (output: String, succeeded: Bool) = {
      let package = try repository.package(id: themeID)
      return try await execute(
        package: package,
        stateRoot: stateRoot,
        consumerPaths: consumerPaths,
        dryRun: dryRun,
        expectedActiveGenerationID: nil,
        json: json
      )
    }
    do {
      if dryRun { return try await run() }
      return try await ThemePackageLock(root: stateRoot).withLock(run)
    } catch {
      let report = ThemeSetReport.precommitFailure(themeID: themeID, error: error)
      return (try report.render(json: json), report.succeeded)
    }
  }

  func execute(
    package: ThemePackage,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    expectedActiveGenerationID: String?,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let report = try await report(
      package: package,
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: dryRun,
      expectedActiveGenerationID: expectedActiveGenerationID
    )
    return (try report.render(json: json), report.succeeded)
  }

  func report(
    package: ThemePackage,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    expectedActiveGenerationID: String?
  ) async throws -> ThemeSetReport {
    let report: ThemeSetReport
    if dryRun {
      do {
        try preflight(package, stateRoot, consumerPaths)
        report = .dryRun(themeID: package.id)
      } catch {
        report = .precommitFailure(themeID: package.id, error: error)
      }
    } else {
      do {
        report = .committed(
          try await activate(
            package,
            stateRoot,
            consumerPaths,
            expectedActiveGenerationID
          ),
          slackTheme: SlackAdapter.render(package: package)
        )
      } catch let error as ThemeActivationError {
        if case .activeGenerationChanged = error { throw error }
        report = .precommitFailure(themeID: package.id, error: error)
      } catch let error as ThemeCommittedActivationError {
        report = .committedActivationError(
          manifest: error.manifest,
          cause: error.cause,
          slackTheme: SlackAdapter.render(package: package)
        )
      } catch let error as ThemeCommittedWithReconciliationError {
        report = .committedError(
          manifest: error.manifest,
          cause: error.cause,
          slackTheme: SlackAdapter.render(package: package)
        )
      } catch {
        report = .precommitFailure(themeID: package.id, error: error)
      }
    }
    return report
  }
}
