import Foundation
import ThemeCore

/// Lock order (ADR-0105) is this lock first, then the canonical activation lock; never the reverse.
struct EnvironmentLifecycleLock: Sendable {
  private static let lock = ProcessScopedFileLock<EnvironmentLifecycleError>(
    filename: "environment.lock",
    cannotCreateRunDirectory: nil,
    lockFileError: { operation, lockURL, code in
      .system("\(operation) environment lifecycle lock", lockURL, code)
    })

  let stateRoot: URL

  func withLock<Value>(_ body: () throws -> Value) throws -> Value {
    try Self.lock.withLock(root: stateRoot, body)
  }

  /// Holds the lock across the transaction's asynchronous provider reload and verification.
  func withAsyncLock<Value>(_ body: () async throws -> Value) async throws -> Value {
    try await Self.lock.withLockBlockingCaller(root: stateRoot, body)
  }

  /// Runs `body` under this lock and then the activation lock, the order theme reconciliation uses.
  func withActivationLock<Value>(_ body: () throws -> Value) throws -> Value {
    try withLock { try ActivationLock(root: stateRoot).withLock(body) }
  }
}
