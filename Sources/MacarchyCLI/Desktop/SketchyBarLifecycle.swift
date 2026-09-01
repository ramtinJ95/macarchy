import Darwin
import Foundation
import ThemeCore

enum SketchyBarRuntimeStatus: String, Codable, Sendable {
  case running
  case stopped
}

struct SketchyBarRuntimeInspection: Codable, Equatable, Sendable {
  let status: SketchyBarRuntimeStatus
  let message: String
  let processID: Int32?
  let executablePath: String?
  let serviceLabel: String?

  enum CodingKeys: String, CodingKey {
    case status, message
    case processID = "process_id"
    case executablePath = "executable_path"
    case serviceLabel = "service_label"
  }

  static let stopped = Self(
    status: .stopped,
    message: "SketchyBar is not running",
    processID: nil,
    executablePath: nil,
    serviceLabel: nil
  )
}

struct SketchyBarLifecycleController: Sendable {
  let preflight: @Sendable () throws -> Bool
  let reload: @Sendable (URL) throws -> SketchyBarRuntimeInspection
  let start: @Sendable () throws -> SketchyBarRuntimeInspection
  let stop: @Sendable () throws -> Void

  static let live: Self = {
    let service = SketchyBarHomebrewService.live
    return Self(
      preflight: service.preflight,
      reload: service.reload,
      start: service.start,
      stop: service.stop
    )
  }()

  func activate(wasRunning: Bool, configurationURL: URL) throws -> SketchyBarRuntimeInspection {
    try wasRunning ? reload(configurationURL) : start()
  }

  func restore(wasRunning: Bool, configurationURL: URL) throws {
    if wasRunning {
      _ = try reload(configurationURL)
    } else if try preflight() {
      try stop()
    }
  }
}

struct SketchyBarHomebrewService: Sendable {
  static let formula = "felixkratz/formulae/sketchybar"
  static let serviceLabel = "homebrew.mxcl.sketchybar"
  static let controlURL = URL(filePath: "/opt/homebrew/bin/sketchybar")
  static let serviceExecutableURL = URL(filePath: "/opt/homebrew/opt/sketchybar/bin/sketchybar")
  static let brewURL = URL(filePath: "/opt/homebrew/bin/brew")
  static let mutationEnvironment = [
    "HOMEBREW_NO_ANALYTICS": "1",
    "HOMEBREW_NO_AUTO_UPDATE": "1",
  ]

  let processRunner: ProcessRunner
  let serviceInspection: @Sendable () throws -> SketchyBarRuntimeInspection
  let controlIsAvailable: @Sendable () -> Bool
  let wait: @Sendable () -> Void

  static let live: Self = {
    let runner = ProcessRunner.live
    return Self(
      processRunner: runner,
      serviceInspection: { try inspectLive(processRunner: runner) },
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: controlURL.path)
      },
      wait: { Thread.sleep(forTimeInterval: 0.1) }
    )
  }()

  func preflight() throws -> Bool {
    guard controlIsAvailable() else {
      throw SketchyBarDesktopError.lifecycle(
        "supported SketchyBar is unavailable at \(Self.controlURL.path)"
      )
    }
    let version = try run(Self.controlURL, ["--version"], timeout: 2)
    guard version.terminationStatus == 0, version.output.hasPrefix("sketchybar-v2.") else {
      throw SketchyBarDesktopError.lifecycle(
        "unsupported SketchyBar version: \(version.output.isEmpty ? "no version reported" : version.output)"
      )
    }
    let runtime = try serviceInspection()
    switch runtime.status {
    case .running: return true
    case .stopped: return false
    }
  }

  func reload(configurationURL: URL) throws -> SketchyBarRuntimeInspection {
    try requireSuccess(
      Self.controlURL,
      ["--reload", configurationURL.standardizedFileURL.path],
      operation: "reload SketchyBar",
      timeout: 2
    )
    let runtime = try serviceInspection()
    guard runtime.status == .running else {
      throw SketchyBarDesktopError.lifecycle("SketchyBar stopped after reload")
    }
    return runtime
  }

  func start() throws -> SketchyBarRuntimeInspection {
    let result = try run(
      Self.brewURL,
      ["services", "start", Self.formula],
      timeout: 30,
      environment: Self.mutationEnvironment
    )
    guard result.terminationStatus == 0 else {
      let detail = result.output.isEmpty ? "no output" : result.output
      if detail.localizedCaseInsensitiveContains("trust") {
        throw SketchyBarDesktopError.lifecycle(
          "Homebrew refused to start SketchyBar because its formula is not trusted; review and run 'brew trust \(Self.formula)', then retry: \(detail)"
        )
      }
      throw SketchyBarDesktopError.lifecycle(
        "Homebrew could not start SketchyBar (status \(result.terminationStatus)): \(detail)"
      )
    }
    return try settle(expectedRunning: true)
  }

  func stop() throws {
    try requireSuccess(
      Self.brewURL,
      ["services", "stop", Self.formula],
      operation: "stop SketchyBar through Homebrew",
      timeout: 30,
      environment: Self.mutationEnvironment
    )
    _ = try settle(expectedRunning: false)
  }

  private func settle(expectedRunning: Bool) throws -> SketchyBarRuntimeInspection {
    var lastError: (any Error)?
    for attempt in 0..<20 {
      do {
        let runtime = try serviceInspection()
        lastError = nil
        if expectedRunning ? runtime.status == .running : runtime.status == .stopped {
          return runtime
        }
      } catch {
        lastError = error
      }
      if attempt < 19 { wait() }
    }
    let detail = lastError.map { ": \($0)" } ?? ""
    throw SketchyBarDesktopError.lifecycle(
      expectedRunning
        ? "SketchyBar did not start through its Homebrew service\(detail)"
        : "SketchyBar did not stop through its Homebrew service\(detail)"
    )
  }

  private func requireSuccess(
    _ executable: URL,
    _ arguments: [String],
    operation: String,
    timeout: TimeInterval,
    environment: [String: String] = [:]
  ) throws {
    let result = try run(executable, arguments, timeout: timeout, environment: environment)
    guard result.terminationStatus == 0 else {
      throw SketchyBarDesktopError.lifecycle(
        "\(operation) exited with status \(result.terminationStatus): \(result.output.isEmpty ? "no output" : result.output)"
      )
    }
  }

  private func run(
    _ executable: URL,
    _ arguments: [String],
    timeout: TimeInterval,
    environment: [String: String] = [:]
  ) throws -> ProcessResult {
    try processRunner.run(
      ProcessRequest(
        executableURL: executable,
        arguments: arguments,
        timeout: timeout,
        environmentOverrides: environment
      )
    )
  }

  private static func inspectLive(
    processRunner: ProcessRunner
  ) throws -> SketchyBarRuntimeInspection {
    let uid = String(getuid())
    let processResult = try processRunner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/pgrep"),
        arguments: ["-u", uid, "-x", "sketchybar"],
        timeout: 2
      )
    )
    let launchResult = try processRunner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/bin/launchctl"),
        arguments: ["print", "gui/\(uid)/\(serviceLabel)"],
        timeout: 2
      )
    )
    if processResult.terminationStatus == 1 {
      if launchResult.terminationStatus == 113 { return .stopped }
      guard launchResult.terminationStatus == 0 else {
        throw SketchyBarDesktopError.lifecycle(
          "cannot inspect the SketchyBar Homebrew service (launchctl status \(launchResult.terminationStatus))"
        )
      }
      throw SketchyBarDesktopError.lifecycle(
        "the SketchyBar Homebrew service is loaded without its process"
      )
    }
    guard processResult.terminationStatus == 0 else {
      throw SketchyBarDesktopError.lifecycle("cannot inspect the SketchyBar process identity")
    }
    let processIDs = processResult.output.split(whereSeparator: \.isNewline).compactMap {
      Int32($0.trimmingCharacters(in: .whitespaces))
    }
    guard processIDs.count == 1, let processID = processIDs.first else {
      throw SketchyBarDesktopError.lifecycle(
        "expected one UID-scoped SketchyBar process; found \(processIDs.count)"
      )
    }
    guard launchResult.terminationStatus == 0 else {
      throw SketchyBarDesktopError.lifecycle(
        "SketchyBar is running outside the supported Homebrew service"
      )
    }
    let expectedPlist = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/LaunchAgents/\(serviceLabel).plist").path
    guard
      loadedServiceMatches(
        launchResult.output,
        propertyListPath: expectedPlist,
        processID: processID
      )
    else {
      throw SketchyBarDesktopError.lifecycle(
        "the loaded SketchyBar Homebrew service does not match its running process"
      )
    }
    try validateServicePropertyList(URL(filePath: expectedPlist))

    var pathBuffer = [CChar](repeating: 0, count: 4_096)
    guard proc_pidpath(processID, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
      throw SketchyBarDesktopError.lifecycle("cannot resolve SketchyBar PID \(processID)")
    }
    let executablePath = String(
      decoding: pathBuffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
      as: UTF8.self
    )
    let supportedPath = serviceExecutableURL.resolvingSymlinksInPath().path
    guard executablePath == supportedPath else {
      throw SketchyBarDesktopError.lifecycle(
        "SketchyBar PID \(processID) uses unsupported executable \(executablePath)"
      )
    }
    return SketchyBarRuntimeInspection(
      status: .running,
      message: "the UID-scoped Homebrew SketchyBar service is running",
      processID: processID,
      executablePath: executablePath,
      serviceLabel: serviceLabel
    )
  }

  private static func validateServicePropertyList(_ url: URL) throws {
    let data = try BoundedRegularFile.read(at: url, maximumSize: 65_536).data
    guard
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      plist["Label"] as? String == serviceLabel,
      plist["ProgramArguments"] as? [String] == [serviceExecutableURL.path],
      plist["KeepAlive"] as? Bool == true,
      plist["RunAtLoad"] as? Bool == true
    else {
      throw SketchyBarDesktopError.lifecycle(
        "the SketchyBar Homebrew LaunchAgent has unsupported configuration"
      )
    }
  }

  static func loadedServiceMatches(
    _ output: String,
    propertyListPath: String,
    processID: Int32
  ) -> Bool {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let fields = Set(lines.map { $0.trimmingCharacters(in: .whitespaces) })
    guard
      fields.contains("path = \(propertyListPath)"),
      fields.contains("state = running"),
      fields.contains("program = \(serviceExecutableURL.path)"),
      fields.contains("pid = \(processID)"),
      let argumentsStart = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "arguments = {"
      })
    else { return false }

    var arguments: [String] = []
    for line in lines.dropFirst(argumentsStart + 1) {
      let value = line.trimmingCharacters(in: .whitespaces)
      if value == "}" { break }
      if !value.isEmpty { arguments.append(value) }
    }
    return arguments == [serviceExecutableURL.path]
  }
}

struct SketchyBarLifecycleEvidence: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let generationID: String
  let runtime: SketchyBarRuntimeInspection

  init(generationID: String, runtime: SketchyBarRuntimeInspection) {
    schemaVersion = 1
    self.generationID = generationID
    self.runtime = runtime
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case runtime
  }

  var isValid: Bool {
    guard
      schemaVersion == 1,
      SketchyBarGenerationInspector.isGenerationID(generationID),
      runtime.status == .running,
      runtime.processID.map({ $0 > 0 }) == true,
      runtime.serviceLabel == SketchyBarHomebrewService.serviceLabel,
      let executablePath = runtime.executablePath,
      !executablePath.contains("\0"),
      !executablePath.contains("\n")
    else { return false }

    let executable = URL(filePath: executablePath).standardizedFileURL
    let cellarPrefix = "/opt/homebrew/Cellar/sketchybar/"
    return executable.path == executablePath
      && executablePath.hasPrefix(cellarPrefix)
      && executablePath.hasSuffix("/bin/sketchybar")
  }
}

struct SketchyBarLifecycleEvidenceStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "desktop/sketchybar", directoryHint: .isDirectory)
  }

  private var file: URL { directory.appending(path: "lifecycle.json") }

  func read() throws -> SketchyBarLifecycleEvidence? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let data = try BoundedRegularFile.read(at: file, maximumSize: 32_768).data
    let evidence = try JSONDecoder().decode(SketchyBarLifecycleEvidence.self, from: data)
    guard evidence.isValid else {
      throw SketchyBarDesktopError.invalidState("SketchyBar lifecycle evidence is invalid")
    }
    return evidence
  }

  func write(_ evidence: SketchyBarLifecycleEvidence) throws {
    guard evidence.isValid else {
      throw SketchyBarDesktopError.invalidState("SketchyBar lifecycle evidence is invalid")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(evidence).write(to: file, options: .atomic)
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}
