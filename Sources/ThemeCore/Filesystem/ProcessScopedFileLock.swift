import Darwin
import Dispatch
import Foundation

package struct ProcessScopedFileLock<LockError: Error>: Sendable {
  let filename: String
  let cannotCreateRunDirectory: @Sendable (URL, String) -> LockError
  let operationError: @Sendable (String, Int32) -> LockError
  private let semaphore = DispatchSemaphore(value: 1)

  package init(
    filename: String,
    cannotCreateRunDirectory: @escaping @Sendable (URL, String) -> LockError,
    operationError: @escaping @Sendable (String, Int32) -> LockError
  ) {
    self.filename = filename
    self.cannotCreateRunDirectory = cannotCreateRunDirectory
    self.operationError = operationError
  }

  package func withLock<Output>(
    root: URL,
    _ operation: () throws -> Output
  ) throws -> Output {
    semaphore.wait()
    defer { semaphore.signal() }
    let descriptor = try acquire(root: root)
    defer { Darwin.close(descriptor) }
    return try operation()
  }

  package func withLock<Output: Sendable>(
    root: URL,
    _ operation: @Sendable () async throws -> Output
  ) async throws -> Output {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        semaphore.wait()
        continuation.resume()
      }
    }
    defer { semaphore.signal() }
    try Task.checkCancellation()
    let descriptor = try acquire(root: root)
    defer { Darwin.close(descriptor) }
    return try await operation()
  }

  private func acquire(root: URL) throws -> Int32 {
    let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(
        at: runDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      throw cannotCreateRunDirectory(runDirectory, String(describing: error))
    }
    let lockURL = runDirectory.appending(path: filename)
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
      throw operationError("open", errno)
    }
    while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
      if errno == EINTR { continue }
      let code = errno
      Darwin.close(descriptor)
      throw operationError("acquire", code)
    }
    return descriptor
  }
}
