import Darwin
import Dispatch
import Foundation

struct StateFileLock: Sendable {
  struct Identity: Sendable {
    fileprivate let filename: String
    fileprivate let displayName: String
    fileprivate let processSemaphore: DispatchSemaphore

    static let updateCheck = Self(
      filename: "update-check.lock",
      displayName: "update-check",
      processSemaphore: DispatchSemaphore(value: 1)
    )
    static let homebrewUpdate = Self(
      filename: "homebrew-update.lock",
      displayName: "Homebrew update",
      processSemaphore: DispatchSemaphore(value: 1)
    )
  }

  private let root: URL
  private let identity: Identity

  init(root: URL, identity: Identity) {
    self.root = root.standardizedFileURL
    self.identity = identity
  }

  func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
    identity.processSemaphore.wait()
    defer { identity.processSemaphore.signal() }
    return try withFileLock(operation)
  }

  private func withFileLock<Value>(_ operation: () throws -> Value) throws -> Value {
    let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: runDirectory,
      withIntermediateDirectories: true
    )
    let lockURL = runDirectory.appending(path: identity.filename)
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
      throw StateFileLockError.system(identity, "open", errno)
    }
    defer { Darwin.close(descriptor) }
    while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
      if errno == EINTR { continue }
      throw StateFileLockError.system(identity, "acquire", errno)
    }
    return try operation()
  }
}

enum StateFileLockError: Error, CustomStringConvertible, Sendable {
  case system(StateFileLock.Identity, String, Int32)

  var description: String {
    switch self {
    case .system(let identity, let operation, let code):
      "Cannot \(operation) \(identity.displayName) lock (errno \(code)): "
        + String(cString: strerror(code))
    }
  }
}
