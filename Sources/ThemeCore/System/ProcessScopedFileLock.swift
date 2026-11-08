import Darwin
import Dispatch
import Foundation

package struct ProcessScopedFileLock<LockError: Error>: Sendable {
  let filename: String
  /// `nil` rethrows the original Foundation directory-creation error.
  let cannotCreateRunDirectory: (@Sendable (URL, String) -> LockError)?
  let lockFileError: @Sendable (String, URL, Int32) -> LockError
  private let semaphore = DispatchSemaphore(value: 1)

  package init(
    filename: String,
    cannotCreateRunDirectory: @escaping @Sendable (URL, String) -> LockError,
    operationError: @escaping @Sendable (String, Int32) -> LockError
  ) {
    self.init(
      filename: filename,
      cannotCreateRunDirectory: cannotCreateRunDirectory,
      lockFileError: { operation, _, code in operationError(operation, code) })
  }

  /// `lockFileError` also receives the lock file's URL. Pass `nil` for
  /// `cannotCreateRunDirectory` to rethrow the original directory-creation error.
  package init(
    filename: String,
    cannotCreateRunDirectory: (@Sendable (URL, String) -> LockError)?,
    lockFileError: @escaping @Sendable (String, URL, Int32) -> LockError
  ) {
    self.filename = filename
    self.cannotCreateRunDirectory = cannotCreateRunDirectory
    self.lockFileError = lockFileError
  }

  package func withLock<Output>(
    root: URL,
    _ operation: () throws -> Output
  ) throws -> Output {
    semaphore.wait()
    defer { semaphore.signal() }
    return try withFileLock(root: root, operation)
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

  /// Holds the lock across suspension points while the calling thread blocks
  /// for it, with no cancellation check before acquisition.
  package func withLockBlockingCaller<Output>(
    root: URL,
    _ operation: () async throws -> Output
  ) async throws -> Output {
    let descriptor = try waitAndAcquire(root: root)
    defer {
      Darwin.close(descriptor)
      semaphore.signal()
    }
    return try await operation()
  }

  /// Takes only the file lock. lockf is process-scoped, so the caller must
  /// already serialize sibling threads with its own primitive.
  package func withFileLock<Output>(
    root: URL,
    _ operation: () throws -> Output
  ) throws -> sending Output {
    let descriptor = try acquire(root: root)
    defer { Darwin.close(descriptor) }
    return try operation()
  }

  /// A periodic owner check must not queue another long-lived worker.
  /// Contention skips the operation; filesystem/locking failures still throw.
  package func withLockIfAvailable(
    root: URL, _ operation: () throws -> Void
  ) throws {
    guard semaphore.wait(timeout: .now()) == .success else { return }
    defer { semaphore.signal() }
    guard let descriptor = try acquire(root: root, wait: false) else { return }
    defer { Darwin.close(descriptor) }
    try operation()
  }

  private func waitAndAcquire(root: URL) throws -> Int32 {
    semaphore.wait()
    do {
      return try acquire(root: root)
    } catch {
      semaphore.signal()
      throw error
    }
  }

  private func acquire(root: URL) throws -> Int32 {
    // The waiting variant either acquires a descriptor or throws.
    try acquire(root: root, wait: true)!
  }

  private func acquire(root: URL, wait: Bool) throws -> Int32? {
    let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(
        at: runDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      guard let cannotCreateRunDirectory else { throw error }
      throw cannotCreateRunDirectory(runDirectory, String(describing: error))
    }
    let lockURL = runDirectory.appending(path: filename)
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
      throw lockFileError("open", lockURL, errno)
    }
    while Darwin.lockf(descriptor, wait ? F_LOCK : F_TLOCK, 0) != 0 {
      if errno == EINTR { continue }
      let code = errno
      Darwin.close(descriptor)
      if !wait && (code == EACCES || code == EAGAIN) { return nil }
      throw lockFileError("acquire", lockURL, code)
    }
    return descriptor
  }
}
