import Foundation
import ThemeCore

/// An error that is only its message: the whole text a command prints when it fails.
struct MessageError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension ProcessScopedFileLock where LockError == MessageError {
  /// `<state root>/run/<filename>`, called "the `lockName` lock" in its errors. Each caller keeps
  /// its own lock order.
  init(filename: String, lockName: String) {
    self.init(
      filename: filename,
      cannotCreateRunDirectory: { url, error in
        MessageError("cannot create \(url.path): \(error)")
      },
      operationError: { operation, code in
        MessageError("cannot \(operation) the \(lockName) lock (errno \(code))")
      })
  }
}
