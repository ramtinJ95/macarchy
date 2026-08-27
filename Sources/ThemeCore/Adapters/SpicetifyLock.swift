import Darwin
import Dispatch
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
  private static let processSemaphore = DispatchSemaphore(value: 1)

  private let root: URL

  package init(root: URL) {
    self.root = root
  }

  package func withLock<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    Self.processSemaphore.wait()
    defer { Self.processSemaphore.signal() }
    let descriptor = try acquireFileLock()
    defer { Darwin.close(descriptor) }
    return try operation()
  }

  package func withLock<Result: Sendable>(
    _ operation: @Sendable () async throws -> Result
  ) async throws -> Result {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        Self.processSemaphore.wait()
        continuation.resume()
      }
    }
    defer { Self.processSemaphore.signal() }
    try Task.checkCancellation()
    let descriptor = try acquireFileLock()
    defer { Darwin.close(descriptor) }
    return try await operation()
  }

  private func acquireFileLock() throws -> Int32 {
    let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(
        at: runDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      throw SpicetifyLockError.createRunDirectory(runDirectory, String(describing: error))
    }
    let lockURL = runDirectory.appending(path: "spicetify.lock")
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
      throw SpicetifyLockError.operation("open", code: errno)
    }
    while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
      if errno == EINTR { continue }
      let code = errno
      Darwin.close(descriptor)
      throw SpicetifyLockError.operation("acquire", code: code)
    }
    return descriptor
  }
}
