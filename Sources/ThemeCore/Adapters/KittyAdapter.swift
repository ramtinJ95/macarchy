import Darwin
import Foundation

enum KittyAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case configurationTooLarge(URL)
  case missingInclude(String)
  case bridgeIsNotRegularFile(URL)
  case bridgeDoesNotMatch(URL)
  case cannotReadBridge(URL, String)
  case cannotPublishBridge(URL, String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Kitty configuration at \(url.path)"
    case .configurationTooLarge(let url):
      "Kitty configuration at \(url.path) exceeds 1 MiB"
    case .missingInclude(let directive):
      "Kitty configuration must contain '\(directive)'"
    case .bridgeIsNotRegularFile(let url):
      "Kitty bridge at \(url.path) must be an ordinary regular file"
    case .bridgeDoesNotMatch(let url):
      "Kitty bridge at \(url.path) does not match the active generation"
    case .cannotReadBridge(let url, let cause):
      "Cannot read Kitty bridge at \(url.path): \(cause)"
    case .cannotPublishBridge(let url, let cause):
      "Cannot publish Kitty bridge at \(url.path): \(cause)"
    }
  }
}

struct KittyAdapter: Sendable {
  private static let maximumConfigurationSize = 1_048_576
  private static let killallURL = URL(filePath: "/usr/bin/killall")
  static let id = "kitty"
  static let bridgePath = "state/adapters/kitty.conf"
  static let outputPath = "generated/kitty.conf"
  static let rendererVersion = 2

  let root: URL
  let configurationURL: URL
  let includeDirective: String
  let processRunner: ProcessRunner

  private var bridgeURL: URL {
    root.appending(path: Self.bridgePath)
  }

  func preflight() throws {
    let values: URLResourceValues
    do {
      values = try configurationURL.resourceValues(forKeys: [.isRegularFileKey])
    } catch {
      throw KittyAdapterError.cannotReadConfiguration(configurationURL)
    }
    guard values.isRegularFile == true else {
      throw KittyAdapterError.cannotReadConfiguration(configurationURL)
    }

    let data: Data
    do {
      let handle = try FileHandle(forReadingFrom: configurationURL)
      defer { try? handle.close() }
      data = try handle.read(upToCount: Self.maximumConfigurationSize + 1) ?? Data()
    } catch {
      throw KittyAdapterError.cannotReadConfiguration(configurationURL)
    }
    guard data.count <= Self.maximumConfigurationSize else {
      throw KittyAdapterError.configurationTooLarge(configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw KittyAdapterError.cannotReadConfiguration(configurationURL)
    }
    guard
      configuration.split(separator: "\n").contains(where: { line in
        line.trimmingCharacters(in: .whitespaces) == includeDirective
      })
    else {
      throw KittyAdapterError.missingInclude(includeDirective)
    }
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      do {
        try ActivationLock(root: root).withLock {
          let desired = try activeConfiguration()
          let bridge = try readBridge()
          guard bridge == desired else {
            throw KittyAdapterError.bridgeDoesNotMatch(bridgeURL)
          }
        }
      } catch ReconciliationStatusError.noActiveGeneration {
        // The include seam can be healthy before the first activation creates a bridge.
      }
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required
      )
    } catch {
      let status: AdapterInspectionStatus
      switch error {
      case KittyAdapterError.missingInclude, KittyAdapterError.bridgeDoesNotMatch:
        status = .drifted
      default:
        status = .failed
      }
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        status: status,
        message: String(describing: error)
      )
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .required) {
      let bridgeOutcome: AdapterOutcome? = try ActivationLock(root: root).withLock {
        do {
          try preflight()
        } catch {
          return AdapterOutcome(status: .drifted, message: String(describing: error))
        }

        let desired = try activeConfiguration()
        do {
          try publishBridge(desired)
        } catch {
          return AdapterOutcome(status: .failed, message: String(describing: error))
        }
        return nil
      }
      if let bridgeOutcome { return bridgeOutcome }

      let reload = try processRunner.run(
        ProcessRequest(
          executableURL: Self.killallURL,
          arguments: ["-USR1", "kitty"]
        )
      )
      guard reload.terminationStatus != 0 else {
        return AdapterOutcome(status: .applied)
      }

      let stillRunning = try processRunner.run(
        ProcessRequest(
          executableURL: Self.killallURL,
          arguments: ["-0", "kitty"]
        )
      )
      guard stillRunning.terminationStatus == 0 else {
        return AdapterOutcome(status: .applied)
      }
      return AdapterOutcome(
        status: .failed,
        message: reload.output.isEmpty ? "Kitty rejected its reload signal" : reload.output
      )
    }
  }

  private func activeConfiguration() throws -> Data {
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    return try BoundedRegularFile.read(
      at: root.appending(
        path: "generations/\(manifest.generationID)/\(Self.outputPath)"
      )
    ).data
  }

  private func readBridge() throws -> Data {
    do {
      return try BoundedRegularFile.read(at: bridgeURL).data
    } catch BoundedRegularFileError.notRegular {
      throw KittyAdapterError.bridgeIsNotRegularFile(bridgeURL)
    } catch BoundedRegularFileError.system(operation: "open", code: ELOOP) {
      throw KittyAdapterError.bridgeIsNotRegularFile(bridgeURL)
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT),
      BoundedRegularFileError.tooLarge
    {
      throw KittyAdapterError.bridgeDoesNotMatch(bridgeURL)
    } catch {
      throw KittyAdapterError.cannotReadBridge(bridgeURL, String(describing: error))
    }
  }

  private func publishBridge(_ data: Data) throws {
    let parent = bridgeURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true
      )
      try data.write(to: bridgeURL, options: .atomic)
    } catch {
      throw KittyAdapterError.cannotPublishBridge(bridgeURL, String(describing: error))
    }
    guard try readBridge() == data else {
      throw KittyAdapterError.bridgeDoesNotMatch(bridgeURL)
    }
  }

  static func render(package: ThemePackage) -> String {
    var lines = [
      "# Generated by Macarchy. Do not edit.",
      "foreground \(package.terminal.foreground.rawValue)",
      "background \(package.terminal.background.rawValue)",
      "cursor \(package.terminal.cursor.rawValue)",
      "cursor_text_color \(package.terminal.background.rawValue)",
      "selection_foreground \(package.terminal.selectionForeground.rawValue)",
      "selection_background \(package.terminal.selectionBackground.rawValue)",
      "active_border_color \(package.semantic.accent.rawValue)",
      "inactive_border_color \(package.semantic.border.rawValue)",
      "tab_bar_background \(package.semantic.background.rawValue)",
      "active_tab_foreground \(package.semantic.accent.rawValue)",
      "active_tab_background \(package.semantic.background.rawValue)",
      "inactive_tab_foreground \(package.semantic.mutedText.rawValue)",
      "inactive_tab_background \(package.semantic.background.rawValue)",
    ]
    lines.append(
      contentsOf: package.terminal.ansi.enumerated().map {
        "color\($0.offset) \($0.element.rawValue)"
      }
    )
    return lines.joined(separator: "\n") + "\n"
  }
}

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
      if completion.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if completion.wait(timeout: .now() + 1) == .timedOut {
          Darwin.kill(process.processIdentifier, SIGKILL)
          process.waitUntilExit()
        }
        _ = output.fileHandleForReading.readDataToEndOfFile()
        throw ProcessRunnerError.timedOut(request.executableURL, timeout)
      }
      data = output.fileHandleForReading.readDataToEndOfFile()
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

enum ProcessRunnerError: Error, CustomStringConvertible, Equatable, Sendable {
  case timedOut(URL, TimeInterval)

  var description: String {
    switch self {
    case .timedOut(let executableURL, let timeout):
      "Process \(executableURL.path) exceeded its \(timeout)-second timeout"
    }
  }
}
