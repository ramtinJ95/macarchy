import Darwin
import Foundation

enum SpicetifyLockError: Error, CustomStringConvertible, Sendable {
  case createRunDirectory(URL, String)
  case operation(String, code: Int32)

  var description: String {
    switch self {
    case .createRunDirectory(let url, let cause):
      "Cannot create Spicetify lock directory at \(url.path): \(cause)"
    case .operation(let operation, let code):
      "Cannot \(operation) Spicetify lock (errno \(code)): \(String(cString: strerror(code)))"
    }
  }
}

package struct SpicetifyLock: Sendable {
  private static let lock = ProcessScopedFileLock(
    filename: "spicetify.lock",
    cannotCreateRunDirectory: SpicetifyLockError.createRunDirectory,
    operationError: SpicetifyLockError.operation
  )

  private let root: URL

  package init(root: URL) {
    self.root = root
  }

  package func withLock<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    try Self.lock.withLock(root: root, operation)
  }

  package func withLock<Result: Sendable>(
    _ operation: @Sendable () async throws -> Result
  ) async throws -> Result {
    try await Self.lock.withLock(root: root, operation)
  }
}
