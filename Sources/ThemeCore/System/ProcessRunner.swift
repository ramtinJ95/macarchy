import Darwin
import Foundation
import Synchronization

package struct ProcessRequest: Equatable, Sendable {
  package let executableURL: URL
  package let arguments: [String]
  package let timeout: TimeInterval?
  package let environmentOverrides: [String: String]
  package let environmentRemovals: Set<String>
  package let isolatedProcessGroup: Bool

  package init(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval? = nil,
    environmentOverrides: [String: String] = [:],
    environmentRemovals: Set<String> = [],
    isolatedProcessGroup: Bool = false
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.timeout = timeout
    self.environmentOverrides = environmentOverrides
    self.environmentRemovals = environmentRemovals
    self.isolatedProcessGroup = isolatedProcessGroup
  }
}

package struct ProcessResult: Equatable, Sendable {
  package let terminationStatus: Int32
  package let output: String

  package init(terminationStatus: Int32, output: String) {
    self.terminationStatus = terminationStatus
    self.output = output
  }
}

package struct ProcessRunner: Sendable {
  package let run: @Sendable (ProcessRequest) throws -> ProcessResult

  package init(run: @escaping @Sendable (ProcessRequest) throws -> ProcessResult) {
    self.run = run
  }

  package static let live = ProcessRunner { request in
    try Task.checkCancellation()
    if request.isolatedProcessGroup { return try runIsolated(request) }
    let process = Process()
    let output = Pipe()
    process.executableURL = request.executableURL
    process.arguments = request.arguments
    if !request.environmentOverrides.isEmpty || !request.environmentRemovals.isEmpty {
      var environment = ProcessInfo.processInfo.environment
      for key in request.environmentRemovals {
        environment.removeValue(forKey: key)
      }
      environment.merge(
        request.environmentOverrides,
        uniquingKeysWith: { _, override in override }
      )
      process.environment = environment
    }
    process.standardOutput = output
    process.standardError = output
    let completion = request.timeout.map { _ in DispatchSemaphore(value: 0) }
    if let completion {
      process.terminationHandler = { _ in completion.signal() }
    }
    try process.run()
    let data: Data
    if let timeout = request.timeout, let completion {
      // Drain concurrently: waiting for exit first deadlocks when a provider's
      // stdout/stderr fills the pipe (for example starship print-config).
      let capture = try OutputCapture(output.fileHandleForReading)
      let deadline = DispatchTime.now() + timeout
      if completion.wait(timeout: deadline) == .timedOut {
        process.terminate()
        if completion.wait(timeout: .now() + 1) == .timedOut {
          Darwin.kill(process.processIdentifier, SIGKILL)
          process.waitUntilExit()
        }
        capture.stop()
        throw ProcessRunnerError.timedOut(request.executableURL, timeout)
      }
      guard capture.drained.wait(timeout: deadline) == .success else {
        capture.stop()
        throw ProcessRunnerError.timedOut(request.executableURL, timeout)
      }
      data = try capture.result()
    } else {
      data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
    }
    try Task.checkCancellation()
    return ProcessResult(
      terminationStatus: process.terminationStatus,
      output: String(decoding: data, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
    )
  }

  /// CLI wrappers may fork Electron. Own their group, not just the wrapper PID.
  private static func runIsolated(_ request: ProcessRequest) throws -> ProcessResult {
    let output = Pipe()
    let capture = try OutputCapture(output.fileHandleForReading)
    defer { capture.stop() }
    var environment = ProcessInfo.processInfo.environment
    for key in request.environmentRemovals { environment.removeValue(forKey: key) }
    environment.merge(request.environmentOverrides) { _, override in override }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in [SIGINT, SIGTERM, SIGHUP] { sigaddset(&defaults, signal) }
    let pid = try ChildProcess.spawn(
      request.executableURL.path, arguments: request.arguments,
      flags: POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF,
      signalDefaults: defaults, processGroup: 0,
      fileActions: [
        .open(descriptor: STDIN_FILENO, path: "/dev/null", flags: O_RDONLY, mode: 0),
        .duplicate(output.fileHandleForWriting.fileDescriptor, to: STDOUT_FILENO),
        .duplicate(output.fileHandleForWriting.fileDescriptor, to: STDERR_FILENO),
      ], environment: environment.map { "\($0.key)=\($0.value)" }
    ).get()
    // Retain the unreaped leader's PID until group cleanup, preventing PID/PGID reuse.
    defer { ChildProcess.killAndReap(pid, target: -pid) }
    try output.fileHandleForWriting.close()
    let deadline = request.timeout.map { DispatchTime.now() + $0 }
    var info = siginfo_t()
    while true {
      try Task.checkCancellation()
      let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
      if result == -1 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
      if result == 0 && info.si_pid == pid { break }
      if let deadline, DispatchTime.now() >= deadline {
        throw ProcessRunnerError.timedOut(request.executableURL, request.timeout!)
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    // Stop descendants even when the wrapper exited successfully. They must not keep
    // mutating the extension store after the command has returned.
    _ = Darwin.kill(-pid, SIGKILL)
    guard capture.drained.wait(timeout: deadline ?? .distantFuture) == .success else {
      throw ProcessRunnerError.timedOut(request.executableURL, request.timeout!)
    }
    return ProcessResult(
      terminationStatus: info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status,
      output: String(decoding: try capture.result(), as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines))
  }
}

/// The reader owns close. Nonblocking reads avoid closing a descriptor under a blocked
/// FileHandle read (which can itself block), and bound cleanup even if a descendant
/// escapes its group while retaining stdout. No abandoned blocking reader threads.
private final class OutputCapture: Sendable {
  private struct State {
    var stopped = false
    var bytes = Data()
    var error: POSIXError?
  }
  private let state = Mutex(State())
  let drained = DispatchGroup()

  init(_ handle: FileHandle) throws {
    let descriptor = handle.fileDescriptor
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
    drained.enter()
    Thread.detachNewThread { [self] in
      defer {
        try? handle.close()
        drained.leave()
      }
      var buffer = [UInt8](repeating: 0, count: 16384)
      while !state.withLock({ $0.stopped }) {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
          state.withLock { $0.bytes.append(contentsOf: buffer.prefix(count)) }
        } else if count == 0 {
          return
        } else if errno == EAGAIN || errno == EINTR {
          Thread.sleep(forTimeInterval: 0.01)
        } else {
          let error = POSIXError(POSIXErrorCode(rawValue: errno)!)
          state.withLock { $0.error = error }
          return
        }
      }
    }
  }

  func stop() {
    if drained.wait(timeout: .now() + 0.1) == .success { return }
    state.withLock { $0.stopped = true }
    _ = drained.wait(timeout: .now() + 0.1)
  }

  func result() throws -> Data {
    try state.withLock {
      if let error = $0.error { throw error }
      return $0.bytes
    }
  }
}

package enum ProcessRunnerError: Error, CustomStringConvertible, Equatable, Sendable {
  case timedOut(URL, TimeInterval)

  package var description: String {
    switch self {
    case .timedOut(let executableURL, let timeout):
      "Process \(executableURL.path) exceeded its \(timeout)-second timeout"
    }
  }
}
