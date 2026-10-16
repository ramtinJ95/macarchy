import Darwin
import Foundation

/// The exact launch contract retained by environment ownership, not an adoption
/// mechanism. An existing unowned job, plist or helper is always a conflict.
package struct LeanFocusServiceConfiguration: Codable, Equatable, Sendable {
  package let stateRoot: String
  package let executablePath: String

  package init(stateRoot: URL, executableURL: URL) {
    self.stateRoot = stateRoot.standardizedFileURL.path
    executablePath = MacarchyCommandPath.persistentURL(for: executableURL).path
  }

  /// Both proc_pidpath and the stable entry point use realpath, including /private.
  package static func physicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  package var currentExecutablePath: String? { Self.physicalPath(executablePath) }

  package var isValid: Bool {
    [stateRoot, executablePath].allSatisfy {
      $0.hasPrefix("/") && !$0.contains("\0")
        && URL(filePath: $0).standardizedFileURL.path == $0
    } && URL(filePath: executablePath).lastPathComponent == "macarchy-focus-ring"
  }

  package var arguments: [String] {
    [executablePath, "--managed", "--state-root", stateRoot]
  }

  package var runtimeURL: URL {
    URL(filePath: stateRoot).appending(path: "environment/lean-focus-runtime.json")
  }

  package func propertyList() throws -> Data {
    guard isValid else { throw LeanFocusServiceError("invalid managed launch configuration") }
    return try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": LeanFocusService.label,
        "ProgramArguments": arguments,
        "RunAtLoad": true,
        // Retry actual crashes, not deterministic preflight/configuration refusals.
        // Stopped jobs retain their exit status and require explicit apply/repair.
        "KeepAlive": ["Crashed": true],
        "ThrottleInterval": 30,
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": URL(filePath: stateRoot).appending(
          path: "environment/lean-focus.stdout.log"
        ).path,
        "StandardErrorPath": URL(filePath: stateRoot).appending(
          path: "environment/lean-focus.stderr.log"
        ).path,
      ], format: .xml, options: 0)
  }

  /// Called by the authenticated owned helper before preflight. Bound each log to
  /// one invocation, including launchd crash retries; never truncate a redirected FD.
  package func resetLogDescriptors(
    stdout: Int32 = STDOUT_FILENO, stderr: Int32 = STDERR_FILENO
  ) throws {
    for (descriptor, name) in [
      (stdout, "lean-focus.stdout.log"), (stderr, "lean-focus.stderr.log"),
    ] {
      let url = URL(filePath: stateRoot).appending(path: "environment/\(name)")
      var opened = stat()
      var named = stat()
      guard fstat(descriptor, &opened) == 0, lstat(url.path, &named) == 0,
        opened.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
        opened.st_uid == getuid(), opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
        ftruncate(descriptor, 0) == 0
      else { throw LeanFocusServiceError("managed log descriptor is not the owned regular log") }
    }
  }
}

package struct LeanFocusServiceError: Error, CustomStringConvertible, Sendable {
  package let description: String
  package init(_ message: String) { description = "Lean focus: \(message)" }
}

package struct LeanFocusServiceInspection: Equatable, Sendable {
  package let registered: Bool
  package let loaded: Bool
  package let processID: Int32?
  package var executableIsCurrent = true
  package var lastExitStatus: Int32? = nil
  package var isRunning: Bool { processID != nil }
  package static let absent = Self(registered: false, loaded: false, processID: nil)
}

/// This mutator only operates on this user's one explicitly owned launchd job.
/// The caller persists the configuration in the environment journal BEFORE start/stop.
package struct LeanFocusService: Sendable {
  package static let label = "io.github.ramtinj95.macarchy.focus-ring"
  let homeDirectory: URL
  let runner: ProcessRunner
  let processPath: @Sendable (Int32) throws -> String
  let wait: @Sendable () -> Void
  let currentHomeDirectory: URL

  package init(
    homeDirectory: URL,
    runner: ProcessRunner = .live,
    processPath: @escaping @Sendable (Int32) throws -> String = BordersService.nativeProcessPath,
    wait: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.1) },
    currentHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.homeDirectory = homeDirectory
    self.runner = runner
    self.processPath = processPath
    self.wait = wait
    self.currentHomeDirectory = currentHomeDirectory
  }

  package var propertyListURL: URL {
    homeDirectory.appending(path: "Library/LaunchAgents/\(Self.label).plist")
  }
  private var domain: String { "gui/\(getuid())" }
  private var job: String { "\(domain)/\(Self.label)" }

  package func inspect(
    configuration: LeanFocusServiceConfiguration?
  ) throws -> LeanFocusServiceInspection {
    let plist = try propertyListData()
    let loaded = try command(["print", job])
    guard loaded.terminationStatus == 0 || loaded.terminationStatus == 113 else {
      throw LeanFocusServiceError("cannot inspect launchd job: \(loaded.output)")
    }
    // Darwin truncates p_comm. The conservative prefix also refuses unknown
    // similarly named processes; it never authorizes killing any of them.
    let processes = try runner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/pgrep"),
        // The helper also inspects itself at startup. Darwin pgrep excludes
        // ancestors unless -a is explicit, including its calling helper.
        arguments: ["-a", "-u", String(getuid()), "-x", "macarchy-focus.*"], timeout: 2))
    guard [0, 1].contains(processes.terminationStatus) else {
      throw LeanFocusServiceError("cannot inspect helper processes: \(processes.output)")
    }
    if plist == nil, loaded.terminationStatus == 113, processes.terminationStatus == 1 {
      return .absent
    }
    guard let configuration, configuration.isValid, let plist,
      plist == (try configuration.propertyList())
    else {
      throw LeanFocusServiceError(
        "an unowned or changed helper/job/plist exists; refusing to adopt or replace it")
    }
    let lines = loaded.output.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    var pid: Int32?
    if loaded.terminationStatus == 0 {
      guard lines.contains("path = \(propertyListURL.path)"),
        lines.contains("program = \(configuration.executablePath)"),
        let start = lines.firstIndex(of: "arguments = {"),
        let end = lines.dropFirst(start + 1).firstIndex(of: "}"),
        Array(lines[(start + 1)..<end]) == configuration.arguments
      else { throw LeanFocusServiceError("loaded job differs from retained launch arguments") }
      let pidLines = lines.filter { $0.hasPrefix("pid = ") }
      guard pidLines.count <= 1 else { throw LeanFocusServiceError("ambiguous launchd PID") }
      if let value = pidLines.first {
        guard let parsed = Int32(value.dropFirst(6)), parsed > 0,
          lines.contains("state = running")
        else { throw LeanFocusServiceError("invalid launchd process state") }
        pid = parsed
      } else if lines.contains("state = running") {
        throw LeanFocusServiceError("running job has no PID")
      }
    }
    let rows = processes.output.split(whereSeparator: \.isNewline)
    var executableIsCurrent = true
    if let pid {
      guard processes.terminationStatus == 0, rows.count == 1,
        Int32(rows[0].trimmingCharacters(in: .whitespaces)) == pid
      else { throw LeanFocusServiceError("helper process and owned launchd job disagree") }
      // The label, exact plist and arguments above establish ownership. A changed
      // stable-path target makes this owned PID stale, not a foreign process.
      let actual = LeanFocusServiceConfiguration.physicalPath(try processPath(pid))
      executableIsCurrent = actual != nil && actual == configuration.currentExecutablePath
    } else if processes.terminationStatus != 1 {
      throw LeanFocusServiceError("a helper process exists outside the owned launchd job")
    }
    let lastExit = lines.first { $0.hasPrefix("last exit code = ") }
      .flatMap {
        Int32($0.dropFirst("last exit code = ".count).prefix { $0 == "-" || $0.isNumber })
      }
    return .init(
      registered: true, loaded: loaded.terminationStatus == 0, processID: pid,
      executableIsCurrent: executableIsCurrent, lastExitStatus: lastExit)
  }

  package func start(_ configuration: LeanFocusServiceConfiguration) throws {
    try requireCurrentHome()
    guard configuration.isValid,
      FileManager.default.isExecutableFile(atPath: configuration.executablePath)
    else {
      throw LeanFocusServiceError("the matching packaged helper is missing or not executable")
    }
    let before = try inspect(configuration: configuration)
    if before.isRunning, before.executableIsCurrent { return }
    if !before.registered {
      let library = homeDirectory.appending(path: "Library")
      let parent = try PinnedFilesystem.openDirectory(at: library)
      defer { Darwin.close(parent) }
      let agents = library.appending(path: "LaunchAgents")
      let directory =
        try PinnedFilesystem.openDirectoryIfPresent(
          parentDescriptor: parent, name: "LaunchAgents", url: agents)
        ?? PinnedFilesystem.createDirectory(
          parentDescriptor: parent, name: "LaunchAgents", url: agents, mode: 0o700)
      defer { Darwin.close(directory) }
      try PinnedFilesystem.writeNewRegularFile(
        parentDescriptor: directory, name: propertyListURL.lastPathComponent,
        url: propertyListURL, data: configuration.propertyList(), mode: 0o600)
    }
    // A persisted attempt may resume an exact dormant registration, never an
    // arbitrary plist. After an upgrade, restart only the exact owned label.
    let arguments =
      before.isRunning
      ? ["kickstart", "-k", job]
      : before.loaded ? ["kickstart", job] : ["bootstrap", domain, propertyListURL.path]
    let result = try command(
      arguments)
    guard result.terminationStatus == 0 else {
      throw LeanFocusServiceError("launch failed: \(result.output)")
    }
    try settle(configuration: configuration, running: true)
  }

  package func stop(_ configuration: LeanFocusServiceConfiguration) throws {
    try requireCurrentHome()
    let before = try inspect(configuration: configuration)
    guard before.registered else {
      try LeanFocusRuntime.remove(configuration: configuration)
      return
    }
    if before.loaded {
      let result = try command(["bootout", job])
      guard result.terminationStatus == 0 else {
        throw LeanFocusServiceError("owned job stop failed: \(result.output)")
      }
      try settle(configuration: configuration, running: false)
    }
    // Re-read through a pinned parent immediately before removing the owned file.
    let parent = try PinnedFilesystem.openDirectory(at: propertyListURL.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let data = try PinnedFilesystem.readRegularFile(
      parentDescriptor: parent, name: propertyListURL.lastPathComponent,
      url: propertyListURL, maximumSize: 65_536
    ).data
    guard data == (try configuration.propertyList()) else {
      throw LeanFocusServiceError("owned plist changed before removal")
    }
    guard unlinkat(parent, propertyListURL.lastPathComponent, 0) == 0, fsync(parent) == 0 else {
      throw LeanFocusServiceError("cannot remove owned plist (errno \(errno))")
    }
    guard try inspect(configuration: nil) == .absent else {
      throw LeanFocusServiceError("owned service did not unregister")
    }
    try LeanFocusRuntime.remove(configuration: configuration)
  }

  private func settle(configuration: LeanFocusServiceConfiguration, running: Bool) throws {
    var last = "unexpected service state"
    for attempt in 0..<30 {
      do {
        let state = try inspect(configuration: configuration)
        if running
          ? state.isRunning && state.executableIsCurrent : !state.isRunning && !state.loaded
        {
          return
        }
      } catch { last = String(describing: error) }
      if attempt < 29 { wait() }
    }
    throw LeanFocusServiceError("service did not settle: \(last)")
  }

  private func propertyListData() throws -> Data? {
    guard
      let parent = try PinnedFilesystem.openDirectoryIfPresent(
        at: propertyListURL.deletingLastPathComponent())
    else { return nil }
    defer { Darwin.close(parent) }
    do {
      return try PinnedFilesystem.readRegularFile(
        parentDescriptor: parent, name: propertyListURL.lastPathComponent,
        url: propertyListURL, maximumSize: 65_536
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
  }

  private func requireCurrentHome() throws {
    guard
      homeDirectory.standardizedFileURL
        == currentHomeDirectory.standardizedFileURL
    else { throw LeanFocusServiceError("service mutation requires the current user's real HOME") }
  }

  private func command(_ arguments: [String]) throws -> ProcessResult {
    try runner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/bin/launchctl"), arguments: arguments, timeout: 5))
  }
}
