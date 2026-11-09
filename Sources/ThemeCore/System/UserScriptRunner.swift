import Darwin
import Foundation

/// Runs the executables a profile declares after each theme change and at teardown. A script
/// runs without a shell, with a short fixed `PATH`, the active palette in its environment, a time
/// limit, and its whole process group stopped when it ends. It runs only when it and its
/// directory, after resolving links, belong to the user and no one else can write to them.
package struct UserScriptRunner: Sendable {
  package enum Event: String, Sendable {
    case apply
    case teardown
  }

  package enum Outcome: Equatable, Sendable {
    case succeeded
    /// Not started, because the script cannot be trusted or found.
    case refused(String)
    /// Started, then exited unsuccessfully, timed out or could not be waited for.
    case failed(String)
  }

  package static let executionLimit: TimeInterval = 10
  package static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
  /// Characters of a failed script's standard error included in its report.
  static let reportedErrorLength = 200
  /// Variables passed through from Macarchy's own environment when set.
  static let inheritedVariables = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]

  let executionLimit: TimeInterval
  let pollInterval: TimeInterval
  let userID: uid_t

  package init(
    executionLimit: TimeInterval = Self.executionLimit,
    pollInterval: TimeInterval = 0.01,
    userID: uid_t = getuid()
  ) {
    self.executionLimit = executionLimit
    self.pollInterval = pollInterval
    self.userID = userID
  }

  /// The environment a script receives for `event` with `theme`, whose canonical file is
  /// `themeFile`. Colors come from the validated theme, so each is `#rrggbb`.
  package static func environment(
    event: Event,
    theme: NormalizedTheme,
    themeFile: URL,
    inherited: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = inherited.filter { inheritedVariables.contains($0.key) }
    environment["PATH"] = path
    environment["MACARCHY_EVENT"] = event.rawValue
    environment["MACARCHY_THEME_ID"] = theme.themeID
    environment["MACARCHY_APPEARANCE"] = theme.appearance.rawValue
    environment["MACARCHY_THEME_FILE"] = themeFile.path
    let semantic = theme.semantic
    let roles: [(String, SRGBColor)] = [
      ("BACKGROUND", semantic.background), ("SURFACE", semantic.surface),
      ("OVERLAY", semantic.overlay), ("BORDER", semantic.border), ("TEXT", semantic.text),
      ("MUTED_TEXT", semantic.mutedText), ("ACCENT", semantic.accent),
      ("SELECTION", semantic.selection), ("INFO", semantic.info),
      ("SUCCESS", semantic.success), ("WARNING", semantic.warning), ("ERROR", semantic.error),
    ]
    for (role, color) in roles {
      environment["MACARCHY_\(role)"] = color.rawValue
    }
    for (index, color) in theme.terminal.ansi.enumerated() {
      environment["MACARCHY_ANSI_\(index)"] = color.rawValue
    }
    return environment
  }

  /// The path to run for `script`, with every link resolved, or why it must not run. The check
  /// and the start are not atomic; a script whose owner can replace it is trusted anyway.
  package func trustedPath(of script: URL) -> Result<String, Refusal> {
    guard let resolvedPointer = realpath(script.path, nil) else {
      return .failure(Refusal("it cannot be found (\(String(cString: strerror(errno))))"))
    }
    let resolved = String(cString: resolvedPointer)
    free(resolvedPointer)

    var file = stat()
    guard lstat(resolved, &file) == 0 else {
      return .failure(Refusal("it cannot be inspected (\(String(cString: strerror(errno))))"))
    }
    guard file.st_mode & S_IFMT == S_IFREG else {
      return .failure(Refusal("it is not a regular file"))
    }
    if let problem = ownershipProblem(file, what: "it") { return .failure(Refusal(problem)) }
    guard file.st_mode & S_IXUSR != 0 else {
      return .failure(Refusal("it is not executable by its owner"))
    }

    let directory = (resolved as NSString).deletingLastPathComponent
    var parent = stat()
    guard lstat(directory, &parent) == 0 else {
      return .failure(
        Refusal("its directory cannot be inspected (\(String(cString: strerror(errno))))"))
    }
    if let problem = ownershipProblem(parent, what: "its directory \(directory)") {
      return .failure(Refusal(problem))
    }
    return .success(resolved)
  }

  package struct Refusal: Error, Equatable, Sendable {
    package let reason: String
    init(_ reason: String) { self.reason = reason }
  }

  private func ownershipProblem(_ metadata: stat, what: String) -> String? {
    if metadata.st_uid != userID {
      return "\(what) belongs to another user"
    }
    if metadata.st_mode & (S_IWGRP | S_IWOTH) != 0 {
      return "\(what) is writable by its group or by others"
    }
    return nil
  }

  /// Runs `script` with `environment` after checking it may run.
  package func run(_ script: URL, environment: [String: String]) -> Outcome {
    let path: String
    switch trustedPath(of: script) {
    case .success(let resolved): path = resolved
    case .failure(let refusal): return .refused(refusal.reason)
    }

    let errorURL = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-user-script-\(UUID().uuidString).stderr")
    defer { try? FileManager.default.removeItem(at: errorURL) }

    let spawned = ChildProcess.spawn(
      path,
      arguments: [],
      flags: Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT),
      processGroup: 0,
      fileActions: [
        .open(descriptor: 0, path: "/dev/null", flags: O_RDONLY, mode: 0),
        .open(descriptor: 1, path: "/dev/null", flags: O_WRONLY, mode: 0),
        .open(
          descriptor: 2, path: errorURL.path,
          flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode: 0o600),
      ],
      environment: environment.map { "\($0.key)=\($0.value)" }.sorted()
    )
    let processID: pid_t
    switch spawned {
    case .success(let pid): processID = pid
    case .failure(.prepare(let code)), .failure(.spawn(let code)):
      return .failed("could not start: \(String(cString: strerror(code)))")
    case .failure(.allocateArguments):
      return .failed("could not start: \(String(cString: strerror(ENOMEM)))")
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(executionLimit))
    var status: Int32 = 0
    while clock.now < deadline {
      let result = waitpid(processID, &status, WNOHANG)
      if result == processID {
        if kill(-processID, 0) == 0 { _ = kill(-processID, SIGKILL) }
        let code = ChildProcess.exitCode(waitStatus: status)
        guard code != 0 else { return .succeeded }
        let detail = Self.reportedError(at: errorURL)
        return .failed("exited with status \(code)" + (detail.isEmpty ? "" : ": \(detail)"))
      }
      if result == -1, errno != EINTR {
        let code = errno
        ChildProcess.killAndReap(processID, target: -processID)
        return .failed("could not be waited for: \(String(cString: strerror(code)))")
      }
      Thread.sleep(forTimeInterval: pollInterval)
    }
    ChildProcess.killAndReap(processID, target: -processID)
    return .failed(
      "did not finish within \(Int(executionLimit)) seconds and was stopped")
  }

  /// The start of what the script wrote to standard error, on one line.
  private static func reportedError(at url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: reportedErrorLength * 4)) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return text.count > reportedErrorLength
      ? String(text.prefix(reportedErrorLength)) + "…" : text
  }
}
