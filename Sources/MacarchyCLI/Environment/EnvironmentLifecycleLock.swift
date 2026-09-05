import Darwin
import Dispatch
import Foundation

struct EnvironmentLifecycleLock: Sendable {
  private static let processSemaphore = DispatchSemaphore(value: 1)

  let stateRoot: URL

  func acquire() throws -> Int32 {
    Self.processSemaphore.wait()
    do {
      let runDirectory = stateRoot.appending(path: "run", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
      let lockURL = runDirectory.appending(path: "environment.lock")
      let descriptor = lockURL.path.withCString {
        Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      }
      guard descriptor >= 0 else {
        throw EnvironmentLifecycleError.system("open environment lifecycle lock", lockURL, errno)
      }
      while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
        if errno == EINTR { continue }
        let code = errno
        Darwin.close(descriptor)
        throw EnvironmentLifecycleError.system("acquire environment lifecycle lock", lockURL, code)
      }
      return descriptor
    } catch {
      Self.processSemaphore.signal()
      throw error
    }
  }

  func release(_ descriptor: Int32) {
    Darwin.close(descriptor)
    Self.processSemaphore.signal()
  }
}
