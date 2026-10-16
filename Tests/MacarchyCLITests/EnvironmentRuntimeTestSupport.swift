import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

extension EnvironmentLeanRuntime {
  /// A new lean test must explicitly inject its fake, never inherit launchctl.
  static let unexpectedInTest = Self(
    configuration: {
      LeanFocusServiceConfiguration(
        stateRoot: $0, executableURL: URL(filePath: "/fixture/macarchy-focus-ring"))
    },
    inspect: { _, _ in
      Issue.record("test did not inject lean inspection")
      throw EnvironmentLifecycleError.blocked("unexpected lean inspection")
    },
    start: { _, _ in
      Issue.record("test did not inject lean start")
      throw EnvironmentLifecycleError.blocked("unexpected lean start")
    },
    stop: { _, _ in
      Issue.record("test did not inject lean stop")
      throw EnvironmentLifecycleError.blocked("unexpected lean stop")
    },
    acknowledge: { _, _, _ in
      Issue.record("test did not inject lean acknowledgement")
      throw EnvironmentLifecycleError.blocked("unexpected lean acknowledgement")
    })
}
