import Foundation

@testable import MacarchyCLI
@testable import ThemeCore

// Shares command wiring only; fixtures retain provider setup, runners, and consumer paths.
struct PresetLifecycleTestHarness {
  let profile: URL
  let state: URL
  let home: URL

  func plan() throws -> (output: String, succeeded: Bool) {
    try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
  }

  func apply(
    runner: EnvironmentApplyCommandRunner,
    consumerPaths: ThemeConsumerPaths,
    adopt: String?
  ) async throws -> (output: String, succeeded: Bool) {
    try await runner.execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      adopt: adopt,
      json: true
    )
  }

  func status(
    runner: EnvironmentStatusCommandRunner,
    consumerPaths: ThemeConsumerPaths
  ) throws -> (output: String, succeeded: Bool) {
    try runner.execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      json: true
    )
  }

  func teardown(consumerPaths: ThemeConsumerPaths) async throws -> (
    output: String, succeeded: Bool
  ) {
    try await EnvironmentTeardownCommandRunner().execute(
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      dryRun: false,
      json: true
    )
  }
}
