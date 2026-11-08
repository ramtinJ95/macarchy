import Darwin
import Foundation
import Synchronization

package struct ProcessRequest: Equatable, Sendable {
  package let executableURL: URL
  package let arguments: [String]
  package let timeout: TimeInterval?
  package let environmentOverrides: [String: String]
  package let environmentRemovals: Set<String>

  package init(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval? = nil,
    environmentOverrides: [String: String] = [:],
    environmentRemovals: Set<String> = []
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.timeout = timeout
    self.environmentOverrides = environmentOverrides
    self.environmentRemovals = environmentRemovals
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
      let captured = Mutex(Data())
      let drained = DispatchSemaphore(value: 0)
      // A blocking reader must not depend on the cooperative/global pool that
      // callers may already saturate while waiting for their subprocesses.
      Thread.detachNewThread {
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        captured.withLock { $0 = bytes }
        drained.signal()
      }
      if completion.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if completion.wait(timeout: .now() + 1) == .timedOut {
          Darwin.kill(process.processIdentifier, SIGKILL)
          process.waitUntilExit()
        }
        drained.wait()
        throw ProcessRunnerError.timedOut(request.executableURL, timeout)
      }
      drained.wait()
      data = captured.withLock { $0 }
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
