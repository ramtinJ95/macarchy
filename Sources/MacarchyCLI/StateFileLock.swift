import Darwin
import Dispatch
import Foundation

struct StateFileLock: Sendable {
  enum Identity: Equatable, Sendable {
    case updateCheck
    case homebrewUpdate

    fileprivate var filename: String {
      switch self {
      case .updateCheck:
        "update-check.lock"
      case .homebrewUpdate:
        "homebrew-update.lock"
      }
    }

    fileprivate var displayName: String {
      switch self {
      case .updateCheck:
        "update-check"
      case .homebrewUpdate:
        "Homebrew update"
      }
    }
  }

  private static let updateCheckProcessSemaphore = DispatchSemaphore(value: 1)
  private static let homebrewUpdateProcessSemaphore = DispatchSemaphore(value: 1)

  private let root: URL
  private let identity: Identity

  init(root: URL, identity: Identity) {
    self.root = root.standardizedFileURL
    self.identity = identity
  }

  func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
    let processSemaphore: DispatchSemaphore
    switch identity {
    case .updateCheck:
      processSemaphore = Self.updateCheckProcessSemaphore
    case .homebrewUpdate:
      processSemaphore = Self.homebrewUpdateProcessSemaphore
    }
    processSemaphore.wait()
    defer { processSemaphore.signal() }
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

enum StateFileLockError: Error, CustomStringConvertible, Equatable, Sendable {
  case system(StateFileLock.Identity, String, Int32)

  var description: String {
    switch self {
    case .system(let identity, let operation, let code):
      "Cannot \(operation) \(identity.displayName) lock (errno \(code)): "
        + String(cString: strerror(code))
    }
  }
}
