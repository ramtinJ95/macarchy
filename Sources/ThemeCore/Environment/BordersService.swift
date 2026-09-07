import Darwin
import Foundation

package enum BordersServiceError: Error, CustomStringConvertible {
  case blocked(String)

  package var description: String {
    switch self {
    case .blocked(let message): "Borders: \(message)"
    }
  }
}

/// Process/service evidence, not readback of Borders' appearance settings.
package struct BordersServiceInspection: Codable, Equatable, Sendable {
  package let processID: Int32?
  package let executablePath: String?
  package let propertyListDigest: String?

  package static let stopped = Self(
    processID: nil, executablePath: nil, propertyListDigest: nil)

  package var isRunning: Bool { processID != nil }
  package var isRegistered: Bool { propertyListDigest != nil }

  package var hasValidShape: Bool {
    if processID == nil, executablePath == nil, propertyListDigest == nil { return true }
    guard processID.map({ $0 > 0 }) ?? true,
      let executablePath, let propertyListDigest
    else { return false }
    let knownExecutable =
      (processID == nil && executablePath == BordersService.serviceExecutableURL.path)
      || (executablePath.hasPrefix("/opt/homebrew/Cellar/borders/")
        && executablePath.hasSuffix("/bin/borders"))
    return knownExecutable
      && URL(filePath: executablePath).standardizedFileURL.path == executablePath
      && propertyListDigest.hasPrefix("sha256:") && propertyListDigest.count == 71
      && propertyListDigest.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
  }
}

package struct BordersService: Sendable {
  package static let formula = "felixkratz/formulae/borders"
  package static let label = "homebrew.mxcl.borders"
  package static let executableURL = URL(filePath: "/opt/homebrew/bin/borders")
  package static let serviceExecutableURL = URL(filePath: "/opt/homebrew/opt/borders/bin/borders")

  let homeDirectory: URL
  let runner: ProcessRunner
  let processPath: @Sendable (Int32) throws -> String
  let wait: @Sendable () -> Void

  package init(
    homeDirectory: URL,
    runner: ProcessRunner = .live,
    processPath: @escaping @Sendable (Int32) throws -> String = Self.nativeProcessPath,
    wait: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
  ) {
    self.homeDirectory = homeDirectory
    self.runner = runner
    self.processPath = processPath
    self.wait = wait
  }

  package func inspectForPlan() throws -> BordersServiceInspection {
    if FileManager.default.fileExists(atPath: Self.executableURL.path) {
      return try preflight()
    }
    return try inspect()
  }

  package func preflight(allowInterruptedRegistration: Bool = false) throws
    -> BordersServiceInspection
  {
    let result = try run(Self.executableURL, ["--version"])
    guard result.terminationStatus == 0,
      result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "borders-v1.9.0"
    else {
      throw BordersServiceError.blocked("requires the qualified Borders 1.9.0 provider")
    }
    // Native 1.9.0 passes its HOME-based rc path to sh -c without quoting.
    guard
      homeDirectory.path.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 47, 95].contains($0)
      })
    else {
      throw BordersServiceError.blocked("native startup does not safely quote this HOME path")
    }
    return try inspect(allowInterruptedRegistration: allowInterruptedRegistration)
  }

  package func inspect(allowInterruptedRegistration: Bool = false) throws
    -> BordersServiceInspection
  {
    let plistURL = homeDirectory.appending(path: "Library/LaunchAgents/\(Self.label).plist")
    let processes = try run(
      URL(filePath: "/usr/bin/pgrep"), ["-u", String(getuid()), "-x", "borders"])
    let job = try run(URL(filePath: "/bin/launchctl"), ["print", "gui/\(getuid())/\(Self.label)"])
    if processes.terminationStatus == 1, job.terminationStatus == 113 {
      var metadata = stat()
      if lstat(plistURL.path, &metadata) == 0 {
        if allowInterruptedRegistration {
          return try registrationInspection(plistURL: plistURL, processID: nil)
        }
        throw BordersServiceError.blocked(
          "an unloaded LaunchAgent exists; its registration requires explicit resolution before apply"
        )
      }
      guard errno == ENOENT else {
        throw BordersServiceError.blocked("cannot inspect the LaunchAgent: errno \(errno)")
      }
      return .stopped
    }
    if allowInterruptedRegistration, processes.terminationStatus == 1,
      job.terminationStatus == 0,
      Self.loadedServiceMatches(job.output, propertyListPath: plistURL.path, processID: nil)
    {
      return try registrationInspection(plistURL: plistURL, processID: nil)
    }
    guard processes.terminationStatus == 0, job.terminationStatus == 0 else {
      throw BordersServiceError.blocked(
        "process and Homebrew job disagree or could not be inspected; refusing to control an external singleton"
      )
    }
    let rows = processes.output.split(whereSeparator: \.isNewline)
    guard rows.count == 1, let pid = Int32(rows[0].trimmingCharacters(in: .whitespaces)), pid > 0,
      Self.loadedServiceMatches(job.output, propertyListPath: plistURL.path, processID: pid)
    else {
      throw BordersServiceError.blocked(
        "expected one UID-scoped Borders process belonging to the supported Homebrew job")
    }
    return try registrationInspection(plistURL: plistURL, processID: pid)
  }

  private func registrationInspection(plistURL: URL, processID: Int32?) throws
    -> BordersServiceInspection
  {
    let data = try BoundedRegularFile.read(at: plistURL, maximumSize: 65_536).data
    guard
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      plist["Label"] as? String == Self.label,
      plist["ProgramArguments"] as? [String] == [Self.serviceExecutableURL.path],
      plist["KeepAlive"] as? Bool == true,
      plist["RunAtLoad"] as? Bool == true,
      plist["ProcessType"] as? String == "Interactive",
      plist["StandardOutPath"] as? String == "/opt/homebrew/var/log/borders/borders.out.log",
      plist["StandardErrorPath"] as? String == "/opt/homebrew/var/log/borders/borders.err.log",
      plist["LimitLoadToSessionType"] as? [String] == [
        "Aqua", "Background", "LoginWindow", "StandardIO", "System",
      ],
      plist["EnvironmentVariables"] as? [String: String] == [
        "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
      ],
      Set(plist.keys) == [
        "Label", "ProgramArguments", "KeepAlive", "RunAtLoad", "ProcessType",
        "StandardOutPath", "StandardErrorPath", "LimitLoadToSessionType", "EnvironmentVariables",
      ]
    else {
      throw BordersServiceError.blocked("the Homebrew LaunchAgent has unsupported configuration")
    }
    let path =
      try processID.map { try processPath($0) }
      ?? Self.serviceExecutableURL.path
    guard processID == nil || path == Self.serviceExecutableURL.resolvingSymlinksInPath().path
    else {
      throw BordersServiceError.blocked(
        "the process does not use the supported Homebrew executable")
    }
    return BordersServiceInspection(
      processID: processID, executablePath: path, propertyListDigest: sha256Digest(data))
  }

  /// The caller must have persisted rollback state before any service mutation.
  package func start() throws { try mutate("start", expectedRunning: true) }
  package func restart() throws { try mutate("restart", expectedRunning: true) }
  package func stop() throws { try mutate("stop", expectedRunning: false) }

  package func request(_ palette: BordersPalette) throws -> String {
    let before = try inspect()
    guard before.isRunning else {
      throw BordersServiceError.blocked("managed service is stopped; apply is required")
    }
    let result = try run(Self.executableURL, palette.arguments)
    guard result.terminationStatus == 0 else {
      throw BordersServiceError.blocked("appearance request failed: \(result.output)")
    }
    guard try inspect() == before else {
      throw BordersServiceError.blocked("service identity changed during the appearance request")
    }
    return
      "Borders' client returned success for the canonical palette request; native settings and rendered pixels have no readback"
  }

  private func mutate(_ action: String, expectedRunning: Bool) throws {
    guard
      homeDirectory.standardizedFileURL
        == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    else {
      throw BordersServiceError.blocked(
        "Homebrew service mutation requires the current user's real HOME")
    }
    let result = try runner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/opt/homebrew/bin/brew"),
        arguments: ["services", action, Self.formula],
        timeout: 30,
        environmentOverrides: ["HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_AUTO_UPDATE": "1"]
      ))
    guard result.terminationStatus == 0 else {
      throw BordersServiceError.blocked(
        "Homebrew services \(action) failed: \(result.output). Formula trust must be reviewed separately; Macarchy never grants it"
      )
    }
    var lastError: (any Error)?
    for attempt in 0..<20 {
      do {
        if try inspect().isRunning == expectedRunning { return }
      } catch { lastError = error }
      if attempt < 19 { wait() }
    }
    throw BordersServiceError.blocked(
      "Homebrew services \(action) did not settle: \(lastError.map(String.init(describing:)) ?? "unexpected running state")"
    )
  }

  private func run(_ executable: URL, _ arguments: [String]) throws -> ProcessResult {
    try runner.run(ProcessRequest(executableURL: executable, arguments: arguments, timeout: 2))
  }

  package static func nativeProcessPath(_ pid: Int32) throws -> String {
    var buffer = [CChar](repeating: 0, count: 4_096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
      throw BordersServiceError.blocked("cannot resolve PID \(pid)")
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  package static func loadedServiceMatches(
    _ output: String, propertyListPath: String, processID: Int32?
  ) -> Bool {
    let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let fields = Set(lines)
    let stateMatches =
      processID.map {
        fields.contains("state = running") && fields.contains("pid = \($0)")
      }
      ?? (!lines.contains { $0.hasPrefix("pid = ") }
        && !fields.contains("state = running"))
    guard stateMatches, fields.contains("path = \(propertyListPath)"),
      fields.contains("program = \(serviceExecutableURL.path)"),
      let start = lines.firstIndex(of: "arguments = {")
    else { return false }
    let rest = lines.dropFirst(start + 1)
    guard let end = rest.firstIndex(of: "}") else { return false }
    return Array(rest[..<end]) == [serviceExecutableURL.path]
  }
}
