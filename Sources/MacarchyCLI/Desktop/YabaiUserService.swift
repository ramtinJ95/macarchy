import Darwin
import Foundation
import ThemeCore

struct YabaiServiceRegistration: Codable, Equatable, Sendable {
  let digest: String
  let inode: UInt64
  let volumeUUID: String
  let permissions: UInt16

  var isValid: Bool {
    digest.hasPrefix("sha256:") && digest.count == 71
      && digest.dropFirst(7).allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
      && inode > 0 && UUID(uuidString: volumeUUID)?.uuidString == volumeUUID
      && permissions <= 0o7777
  }
}

struct YabaiServiceState: Codable, Equatable, Sendable {
  let registration: YabaiServiceRegistration?
  let loaded: Bool
  let running: Bool

  var isValidPriorState: Bool {
    loaded == running && (!loaded || registration != nil)
      && (registration?.isValid ?? true)
  }
}

struct YabaiServiceOwnership: Codable, Equatable, Sendable {
  let original: YabaiServiceState
  let registration: YabaiServiceRegistration

  var isValid: Bool {
    original.isValidPriorState && registration.isValid
      && (original.registration == nil || original.registration == registration)
  }
}

/// Stored inside the existing yabai transaction, not in a second journal.
struct YabaiServiceChange: Codable, Equatable, Sendable {
  let previous: YabaiServiceState
  let previousOwnership: YabaiServiceOwnership?
  var installationAttempted = false
  var installed: YabaiServiceRegistration?

  var expectedRegistration: YabaiServiceRegistration? { installed ?? previous.registration }

  var isValid: Bool {
    previous.isValidPriorState && (previousOwnership?.isValid ?? true)
      && (previousOwnership == nil || previousOwnership?.registration == previous.registration)
      && (!installationAttempted || previous.registration == nil)
      && (installed == nil || (installationAttempted && installed?.isValid == true))
  }
}

struct YabaiUserService: Sendable {
  static let label = "com.asmvik.yabai"
  static let executable = URL(filePath: "/opt/homebrew/bin/yabai")
  let runner: ProcessRunner
  let process: @Sendable () throws -> (processID: Int32, executablePath: String)?

  static let live = Self(runner: .live, process: YabaiLifecycleController.settledProcessEvidence)

  func propertyList(_ home: URL) -> URL {
    home.appending(path: "Library/LaunchAgents/\(Self.label).plist")
  }

  func prepare(home: URL, stateRoot: URL) throws -> YabaiServiceChange {
    let version = try run(Self.executable, ["--version"])
    guard version.terminationStatus == 0, version.output == "yabai-v7.1.25" else {
      throw blocked("first-use service lifecycle requires yabai 7.1.25")
    }
    let previous = try inspect(home: home)
    let ownership = try YabaiServiceOwnershipStore(stateRoot: stateRoot).read()
    if let ownership, previous.registration != ownership.registration {
      throw blocked("owned LaunchAgent has changed; refusing to replace or adopt it")
    }
    // A loaded, failed job is not equivalent to an unloaded service. Starting it
    // cannot restore its prior failure state on rollback, so leave it explicit.
    guard !previous.loaded || previous.running else {
      throw blocked(
        "the loaded yabai service is not running; resolve its Accessibility/startup failure before applying"
      )
    }
    return YabaiServiceChange(previous: previous, previousOwnership: ownership)
  }

  func inspect(home: URL) throws -> YabaiServiceState {
    let registration = try registration(home: home)
    let job = try loadedJob()
    let observed = try process()
    if let job {
      guard registration != nil,
        job.split(whereSeparator: \.isNewline).contains(where: {
          $0.trimmingCharacters(in: .whitespaces) == "path = \(propertyList(home).path)"
        })
      else { throw blocked("loaded yabai job does not match its supported LaunchAgent") }
      if let pid = observed?.processID {
        guard
          job.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "pid = \(pid)"
          })
        else { throw blocked("yabai process and loaded service disagree") }
      }
    } else if observed != nil {
      throw blocked(
        "yabai is running outside its supported user service; no service mutation is safe")
    }
    try requireEnabled()
    return YabaiServiceState(
      registration: registration, loaded: job != nil, running: observed != nil)
  }

  /// Caller writes installationAttempted before this operation and installed
  /// evidence after it, both in the provider's existing durable transaction.
  func install(home: URL) throws -> YabaiServiceRegistration {
    guard try registration(home: home) == nil, try loadedJob() == nil,
      try process() == nil
    else { throw blocked("service appeared since approval; refusing installation") }
    try requireEnabled()
    try mutate("--install-service")
    guard let installed = try registration(home: home) else {
      throw blocked("native install did not create the yabai LaunchAgent")
    }
    return installed
  }

  func start(home: URL, expected: YabaiServiceRegistration) throws {
    try requireRegistration(expected, home: home)
    try requireEnabled()
    try mutate("--start-service")
  }

  func stop(home: URL, expected: YabaiServiceRegistration) throws {
    try requireRegistration(expected, home: home)
    if try loadedJob() != nil { try mutate("--stop-service") }
    for _ in 0..<20 {
      if try process() == nil, try loadedJob() == nil {
        // Unlike skhd, yabai 7.1.25's native stop also disables the job.
        // Every admitted prior state was enabled. Restore that state while the
        // authenticated registration and rollback journal still exist; enable
        // does not bootstrap/start it. A failure must retain recovery evidence.
        try requireRegistration(expected, home: home)
        if try isDisabled() {
          let result = try run(
            URL(filePath: "/bin/launchctl"), ["enable", "gui/\(getuid())/\(Self.label)"])
          guard result.terminationStatus == 0 else {
            throw blocked(
              "cannot restore yabai's enabled state after native stop: \(result.output)")
          }
        }
        try requireEnabled()
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw blocked("yabai did not stop; service restoration remains pending")
  }

  func uninstall(home: URL, expected: YabaiServiceRegistration) throws {
    if try registration(home: home) == nil {
      guard try loadedJob() == nil, try process() == nil else {
        throw blocked("absent LaunchAgent still has runtime state")
      }
      return  // Recovery after native uninstall, before receipt removal.
    }
    try stop(home: home, expected: expected)
    try requireRegistration(expected, home: home)
    try mutate("--uninstall-service")
    guard try registration(home: home) == nil else {
      throw blocked("native uninstall did not remove the owned yabai LaunchAgent")
    }
  }

  func validateRecovery(_ change: YabaiServiceChange, home: URL) throws {
    guard change.isValid else { throw blocked("invalid yabai service transaction evidence") }
    let actual = try registration(home: home)
    if change.installationAttempted, change.installed == nil, actual != nil {
      throw blocked(
        "installation was interrupted before ownership evidence was saved; inspect the unclaimed LaunchAgent manually; it will not be adopted or deleted"
      )
    }
    if let expected = change.expectedRegistration {
      guard actual == expected || (change.installed != nil && actual == nil) else {
        throw blocked("LaunchAgent drift blocks service recovery")
      }
    } else if actual != nil {
      throw blocked("an unclaimed LaunchAgent appeared during the transaction")
    }
  }

  func rollback(_ change: YabaiServiceChange, home: URL, stateRoot: URL) throws {
    try validateRecovery(change, home: home)
    if let installed = change.installed {
      try uninstall(home: home, expected: installed)
    } else if let registration = change.previous.registration {
      if change.previous.running {
        try start(home: home, expected: registration)
        // The caller performs the generation-correlated restart and verification.
      } else {
        try stop(home: home, expected: registration)
      }
    } else {
      guard try loadedJob() == nil, try process() == nil else {
        throw blocked("cannot restore the absent service while unclaimed runtime state exists")
      }
    }
    try YabaiServiceOwnershipStore(stateRoot: stateRoot).write(change.previousOwnership)
  }

  func commit(_ change: YabaiServiceChange, home: URL, stateRoot: URL) throws {
    guard let registration = change.expectedRegistration else {
      throw blocked("cannot commit service ownership without a registration")
    }
    try requireRegistration(registration, home: home)
    let ownership =
      change.previousOwnership
      ?? YabaiServiceOwnership(original: change.previous, registration: registration)
    try YabaiServiceOwnershipStore(stateRoot: stateRoot).write(ownership)
  }

  func restoreOriginal(_ ownership: YabaiServiceOwnership, home: URL) throws {
    if ownership.original.running {
      try start(home: home, expected: ownership.registration)
    } else {
      try stop(home: home, expected: ownership.registration)
    }
  }

  func finalizeTeardown(_ ownership: YabaiServiceOwnership, home: URL, stateRoot: URL) throws {
    if ownership.original.registration == nil {
      try uninstall(home: home, expected: ownership.registration)
    } else {
      try requireRegistration(ownership.registration, home: home)
    }
    try YabaiServiceOwnershipStore(stateRoot: stateRoot).write(nil)
  }

  func registration(home: URL) throws -> YabaiServiceRegistration? {
    let file = propertyList(home)
    // Do not follow a redirected LaunchAgents directory into somebody else's state.
    for directory in [home.appending(path: "Library"), file.deletingLastPathComponent()] {
      var info = stat()
      if lstat(directory.path, &info) != 0 {
        guard errno == ENOENT else { throw blocked("cannot inspect \(directory.path)") }
        return nil
      }
      guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
        throw blocked("LaunchAgent parent is not an ordinary user-owned directory")
      }
    }
    var info = stat()
    if lstat(file.path, &info) != 0 {
      guard errno == ENOENT else { throw blocked("cannot inspect \(file.path)") }
      return nil
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
      throw blocked("LaunchAgent must be an ordinary, singly linked user-owned file")
    }
    let data = try BoundedRegularFile.read(at: file, maximumSize: 65_536).data
    guard
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      Set(plist.keys) == [
        "Label", "ProgramArguments", "EnvironmentVariables", "RunAtLoad",
        "KeepAlive", "StandardOutPath", "StandardErrorPath", "ProcessType", "Nice",
      ],
      plist["Label"] as? String == Self.label,
      let arguments = plist["ProgramArguments"] as? [String], arguments.count == 1,
      [Self.executable.path, Self.executable.resolvingSymlinksInPath().path].contains(arguments[0]),
      let environment = plist["EnvironmentVariables"] as? [String: String],
      Set(environment.keys) == ["PATH"], environment["PATH"]?.isEmpty == false,
      plist["RunAtLoad"] as? Bool == true,
      plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false, "Crashed": true],
      plist["StandardOutPath"] as? String == "/tmp/yabai_\(NSUserName()).out.log",
      plist["StandardErrorPath"] as? String == "/tmp/yabai_\(NSUserName()).err.log",
      plist["ProcessType"] as? String == "Interactive", plist["Nice"] as? Int == -20
    else {
      throw blocked(
        "custom or unsupported yabai LaunchAgent is protected; it will not be overwritten or adopted"
      )
    }
    return YabaiServiceRegistration(
      digest: sha256Digest(data), inode: UInt64(info.st_ino),
      volumeUUID: try RetainedOriginalIdentity.volumeUUID(at: file, matching: info),
      permissions: info.st_mode & 0o7777)
  }

  private func requireRegistration(_ expected: YabaiServiceRegistration, home: URL) throws {
    guard try registration(home: home) == expected else {
      throw blocked("yabai LaunchAgent changed; refusing service mutation")
    }
  }

  private func loadedJob() throws -> String? {
    let result = try run(
      URL(filePath: "/bin/launchctl"), ["print", "gui/\(getuid())/\(Self.label)"])
    guard result.terminationStatus == 0 || result.terminationStatus == 113 else {
      throw blocked("cannot inspect yabai launchd state: \(result.output)")
    }
    return result.terminationStatus == 0 ? result.output : nil
  }

  private func requireEnabled() throws {
    if try isDisabled() {
      throw blocked("yabai was explicitly disabled; setup will not enable it silently")
    }
  }

  private func isDisabled() throws -> Bool {
    let result = try run(URL(filePath: "/bin/launchctl"), ["print-disabled", "gui/\(getuid())"])
    guard result.terminationStatus == 0 else {
      throw blocked("cannot inspect disabled user services: \(result.output)")
    }
    return result.output.split(whereSeparator: \.isNewline).contains(where: {
      $0.trimmingCharacters(in: .whitespaces) == "\"\(Self.label)\" => disabled"
    })
  }

  private func mutate(_ argument: String) throws {
    let result = try run(Self.executable, [argument])
    guard result.terminationStatus == 0 else {
      throw blocked("yabai \(argument) failed: \(result.output)")
    }
  }

  private func run(_ executable: URL, _ arguments: [String]) throws -> ProcessResult {
    try runner.run(ProcessRequest(executableURL: executable, arguments: arguments, timeout: 10))
  }

  private func blocked(_ message: String) -> YabaiDesktopError {
    .lifecycle(message)
  }
}

struct YabaiServiceOwnershipStore: Sendable {
  let stateRoot: URL
  private var file: URL { stateRoot.appending(path: "desktop/yabai/service.json") }

  func read() throws -> YabaiServiceOwnership? {
    do {
      let data = try BoundedRegularFile.read(at: file, maximumSize: 16_384).data
      let ownership = try JSONDecoder().decode(YabaiServiceOwnership.self, from: data)
      guard ownership.isValid else {
        throw YabaiDesktopError.lifecycle("invalid yabai service ownership evidence")
      }
      return ownership
    } catch BoundedRegularFileError.system(_, ENOENT) { return nil }
  }

  func write(_ ownership: YabaiServiceOwnership?) throws {
    if let ownership {
      let descriptor = try PinnedFilesystem.openDirectory(at: file.deletingLastPathComponent())
      defer { Darwin.close(descriptor) }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try PinnedFilesystem.replaceRegularFileAtomically(
        parentDescriptor: descriptor, name: file.lastPathComponent, url: file,
        data: try encoder.encode(ownership), mode: 0o600)
    } else {
      guard unlink(file.path) == 0 || errno == ENOENT else {
        throw YabaiDesktopError.lifecycle("cannot remove yabai service ownership receipt")
      }
    }
  }
}
