import Darwin
import Foundation
import ThemeCore

struct SkhdServiceRegistration: Codable, Equatable, Sendable {
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

struct SkhdServiceState: Codable, Equatable, Sendable {
  let registration: SkhdServiceRegistration?
  let loaded: Bool
  let running: Bool

  var isValidPriorState: Bool {
    loaded == running && (!loaded || registration != nil)
      && (registration?.isValid ?? true)
  }
}

struct SkhdServiceOwnership: Codable, Equatable, Sendable {
  let original: SkhdServiceState
  let registration: SkhdServiceRegistration

  var isValid: Bool {
    original.isValidPriorState && registration.isValid
      && (original.registration == nil || original.registration == registration)
  }
}

/// Stored inside the existing keybinding transaction, not in a second journal.
struct SkhdServiceChange: Codable, Equatable, Sendable {
  let previous: SkhdServiceState
  let previousOwnership: SkhdServiceOwnership?
  var installationAttempted = false
  var installed: SkhdServiceRegistration?

  var expectedRegistration: SkhdServiceRegistration? { installed ?? previous.registration }

  var isValid: Bool {
    previous.isValidPriorState && (previousOwnership?.isValid ?? true)
      && (previousOwnership == nil || previousOwnership?.registration == previous.registration)
      && (!installationAttempted || previous.registration == nil)
      && (installed == nil || (installationAttempted && installed?.isValid == true))
  }
}

struct SkhdUserService: Sendable {
  static let label = "com.koekeishiya.skhd"
  static let executable = URL(filePath: "/opt/homebrew/bin/skhd")
  let runner: ProcessRunner
  let process: KeybindingProcessInspector

  static let live = Self(runner: .live, process: .live)

  func propertyList(_ home: URL) -> URL {
    home.appending(path: "Library/LaunchAgents/\(Self.label).plist")
  }

  func prepare(home: URL, stateRoot: URL) throws -> SkhdServiceChange {
    let version = try run(Self.executable, ["--version"])
    guard version.terminationStatus == 0, version.output == "skhd-v0.3.9" else {
      throw blocked("first-use service lifecycle requires skhd 0.3.9")
    }
    let previous = try inspect(home: home)
    let ownership = try SkhdServiceOwnershipStore(stateRoot: stateRoot).read()
    if let ownership, previous.registration != ownership.registration {
      throw blocked("owned LaunchAgent has changed; refusing to replace or adopt it")
    }
    // A loaded, failed job is not equivalent to an unloaded service. Starting it
    // cannot restore its prior failure state on rollback, so leave it explicit.
    guard !previous.loaded || previous.running else {
      throw blocked(
        "the loaded skhd service is not running; resolve its Accessibility/startup failure before applying"
      )
    }
    return SkhdServiceChange(previous: previous, previousOwnership: ownership)
  }

  func inspect(home: URL) throws -> SkhdServiceState {
    let registration = try registration(home: home)
    let job = try loadedJob()
    let observed = process.inspect()
    guard observed.status == .running || observed.status == .notRunning else {
      throw blocked(observed.message)
    }
    if let job {
      guard registration != nil,
        job.split(whereSeparator: \.isNewline).contains(where: {
          $0.trimmingCharacters(in: .whitespaces) == "path = \(propertyList(home).path)"
        })
      else { throw blocked("loaded skhd job does not match its supported LaunchAgent") }
      if let pid = observed.processID, observed.status == .running {
        guard
          job.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "pid = \(pid)"
          })
        else { throw blocked("skhd process and loaded service disagree") }
      }
    } else if observed.status == .running {
      throw blocked(
        "skhd is running outside its supported user service; no service mutation is safe")
    }
    try requireEnabled()
    return SkhdServiceState(
      registration: registration, loaded: job != nil, running: observed.status == .running)
  }

  /// Caller writes installationAttempted before this operation and installed
  /// evidence after it, both in the provider's existing durable transaction.
  func install(home: URL) throws -> SkhdServiceRegistration {
    guard try registration(home: home) == nil, try loadedJob() == nil,
      process.inspect().status == .notRunning
    else { throw blocked("service appeared since approval; refusing installation") }
    try requireEnabled()
    try mutate("--install-service")
    guard let installed = try registration(home: home) else {
      throw blocked("native install did not create the skhd LaunchAgent")
    }
    return installed
  }

  func start(home: URL, expected: SkhdServiceRegistration) throws {
    try requireRegistration(expected, home: home)
    try requireEnabled()
    try mutate("--start-service")
  }

  func stop(home: URL, expected: SkhdServiceRegistration) throws {
    try requireRegistration(expected, home: home)
    if try loadedJob() != nil { try mutate("--stop-service") }
    for _ in 0..<20 {
      let observed = process.inspect()
      if observed.status == .notRunning, try loadedJob() == nil { return }
      if observed.status == .unsupported || observed.status == .unavailable {
        throw blocked(observed.message)
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw blocked("skhd did not stop; service restoration remains pending")
  }

  func uninstall(home: URL, expected: SkhdServiceRegistration) throws {
    if try registration(home: home) == nil {
      guard try loadedJob() == nil, process.inspect().status == .notRunning else {
        throw blocked("absent LaunchAgent still has runtime state")
      }
      return  // Recovery after native uninstall, before receipt removal.
    }
    try stop(home: home, expected: expected)
    try requireRegistration(expected, home: home)
    try mutate("--uninstall-service")
    guard try registration(home: home) == nil else {
      throw blocked("native uninstall did not remove the owned skhd LaunchAgent")
    }
  }

  func validateRecovery(_ change: SkhdServiceChange, home: URL) throws {
    guard change.isValid else { throw blocked("invalid skhd service transaction evidence") }
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

  func rollback(_ change: SkhdServiceChange, home: URL, stateRoot: URL) throws {
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
      guard try loadedJob() == nil, process.inspect().status == .notRunning else {
        throw blocked("cannot restore the absent service while unclaimed runtime state exists")
      }
    }
    try SkhdServiceOwnershipStore(stateRoot: stateRoot).write(change.previousOwnership)
  }

  func commit(_ change: SkhdServiceChange, home: URL, stateRoot: URL) throws {
    guard let registration = change.expectedRegistration else {
      throw blocked("cannot commit service ownership without a registration")
    }
    try requireRegistration(registration, home: home)
    let ownership =
      change.previousOwnership
      ?? SkhdServiceOwnership(original: change.previous, registration: registration)
    try SkhdServiceOwnershipStore(stateRoot: stateRoot).write(ownership)
  }

  func restoreOriginal(_ ownership: SkhdServiceOwnership, home: URL) throws {
    if ownership.original.running {
      try start(home: home, expected: ownership.registration)
    } else {
      try stop(home: home, expected: ownership.registration)
    }
  }

  func finalizeTeardown(_ ownership: SkhdServiceOwnership, home: URL, stateRoot: URL) throws {
    if ownership.original.registration == nil {
      try uninstall(home: home, expected: ownership.registration)
    } else {
      try requireRegistration(ownership.registration, home: home)
    }
    try SkhdServiceOwnershipStore(stateRoot: stateRoot).write(nil)
  }

  func registration(home: URL) throws -> SkhdServiceRegistration? {
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
      plist["StandardOutPath"] as? String == "/tmp/skhd_\(NSUserName()).out.log",
      plist["StandardErrorPath"] as? String == "/tmp/skhd_\(NSUserName()).err.log",
      plist["ProcessType"] as? String == "Interactive", plist["Nice"] as? Int == -20
    else {
      throw blocked(
        "custom or unsupported skhd LaunchAgent is protected; it will not be overwritten or adopted"
      )
    }
    return SkhdServiceRegistration(
      digest: sha256Digest(data), inode: UInt64(info.st_ino),
      volumeUUID: try RetainedOriginalIdentity.volumeUUID(at: file, matching: info),
      permissions: info.st_mode & 0o7777)
  }

  private func requireRegistration(_ expected: SkhdServiceRegistration, home: URL) throws {
    guard try registration(home: home) == expected else {
      throw blocked("skhd LaunchAgent changed; refusing service mutation")
    }
  }

  private func loadedJob() throws -> String? {
    let result = try run(
      URL(filePath: "/bin/launchctl"), ["print", "gui/\(getuid())/\(Self.label)"])
    guard result.terminationStatus == 0 || result.terminationStatus == 113 else {
      throw blocked("cannot inspect skhd launchd state: \(result.output)")
    }
    return result.terminationStatus == 0 ? result.output : nil
  }

  private func requireEnabled() throws {
    let result = try run(URL(filePath: "/bin/launchctl"), ["print-disabled", "gui/\(getuid())"])
    guard result.terminationStatus == 0 else {
      throw blocked("cannot inspect disabled user services: \(result.output)")
    }
    if result.output.split(whereSeparator: \.isNewline).contains(where: {
      $0.trimmingCharacters(in: .whitespaces) == "\"\(Self.label)\" => disabled"
    }) {
      throw blocked("skhd was explicitly disabled; setup will not enable it silently")
    }
  }

  private func mutate(_ argument: String) throws {
    let result = try run(Self.executable, [argument])
    guard result.terminationStatus == 0 else {
      throw blocked("skhd \(argument) failed: \(result.output)")
    }
  }

  private func run(_ executable: URL, _ arguments: [String]) throws -> ProcessResult {
    try runner.run(ProcessRequest(executableURL: executable, arguments: arguments, timeout: 10))
  }

  private func blocked(_ message: String) -> KeybindingsApplyError {
    .lifecycle(message)
  }
}

struct SkhdServiceOwnershipStore: Sendable {
  let stateRoot: URL
  private var file: URL { stateRoot.appending(path: "keybindings/service.json") }

  func read() throws -> SkhdServiceOwnership? {
    do {
      let data = try BoundedRegularFile.read(at: file, maximumSize: 16_384).data
      let ownership = try JSONDecoder().decode(SkhdServiceOwnership.self, from: data)
      guard ownership.isValid else {
        throw KeybindingsApplyError.lifecycle("invalid skhd service ownership evidence")
      }
      return ownership
    } catch BoundedRegularFileError.system(_, ENOENT) { return nil }
  }

  func write(_ ownership: SkhdServiceOwnership?) throws {
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
        throw KeybindingsApplyError.lifecycle("cannot remove skhd service ownership receipt")
      }
    }
  }
}
