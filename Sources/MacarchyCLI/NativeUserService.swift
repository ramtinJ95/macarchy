import Darwin
import Foundation
import ThemeCore

// Native launchd user-service ownership shared by skhd (ADR-0276) and yabai (ADR-0277).
// Each service supplies its identity, receipt location and error type as policy; the
// persisted change and receipt records keep their released camelCase keys (ADR-0297).

struct UserServiceRegistration: Codable, Equatable, Sendable {
  let digest: String
  let inode: UInt64
  let volumeUUID: String
  let permissions: UInt16

  var isValid: Bool {
    isSHA256Digest(digest)
      && inode > 0 && UUID(uuidString: volumeUUID)?.uuidString == volumeUUID
      && permissions <= 0o7777
  }
}

struct UserServiceState: Codable, Equatable, Sendable {
  let registration: UserServiceRegistration?
  let loaded: Bool
  let running: Bool

  var isValidPriorState: Bool {
    loaded == running && (!loaded || registration != nil)
      && (registration?.isValid ?? true)
  }
}

struct UserServiceOwnership: Codable, Equatable, Sendable {
  let original: UserServiceState
  let registration: UserServiceRegistration

  var isValid: Bool {
    original.isValidPriorState && registration.isValid
      && (original.registration == nil || original.registration == registration)
  }
}

/// Stored inside the provider's existing transaction, not in a second journal.
struct UserServiceChange: Codable, Equatable, Sendable {
  let previous: UserServiceState
  let previousOwnership: UserServiceOwnership?
  var installationAttempted = false
  var installed: UserServiceRegistration?

  var expectedRegistration: UserServiceRegistration? { installed ?? previous.registration }

  var isValid: Bool {
    previous.isValidPriorState && (previousOwnership?.isValid ?? true)
      && (previousOwnership == nil || previousOwnership?.registration == previous.registration)
      && (!installationAttempted || previous.registration == nil)
      && (installed == nil || (installationAttempted && installed?.isValid == true))
  }
}

/// What the service's own process inspector observed.
enum UserServiceProcess: Equatable, Sendable {
  case notRunning
  case running(processID: Int32?)
  /// Evidence no service decision can rest on; the message explains why.
  case indeterminate(String)
}

protocol NativeUserServicePolicy: Sendable {
  /// The Homebrew executable name, also used for log files and messages.
  static var name: String { get }
  static var label: String { get }
  /// The only native version whose service commands are supported.
  static var supportedVersion: String { get }
  /// The ownership receipt, relative to the state root.
  static var receiptPath: String { get }
  /// Whether the native stop command also disables the job (yabai 7.1.25, ADR-0278).
  static var nativeStopDisablesJob: Bool { get }
  static func lifecycleError(_ message: String) -> any Error
}

struct NativeUserService<Policy: NativeUserServicePolicy>: Sendable {
  static var label: String { Policy.label }
  static var executable: URL { URL(filePath: "/opt/homebrew/bin/\(Policy.name)") }
  let runner: ProcessRunner
  let process: @Sendable () throws -> UserServiceProcess

  init(
    runner: ProcessRunner,
    observingProcess process: @escaping @Sendable () throws -> UserServiceProcess
  ) {
    self.runner = runner
    self.process = process
  }

  private var name: String { Policy.name }

  private func receipts(_ stateRoot: URL) -> NativeUserServiceOwnershipStore<Policy> {
    NativeUserServiceOwnershipStore(stateRoot: stateRoot)
  }

  func propertyList(_ home: URL) -> URL {
    home.appending(path: "Library/LaunchAgents/\(Self.label).plist")
  }

  func prepare(home: URL, stateRoot: URL) throws -> UserServiceChange {
    let version = try run(Self.executable, ["--version"])
    guard version.terminationStatus == 0, version.output == "\(name)-v\(Policy.supportedVersion)"
    else {
      throw blocked("first-use service lifecycle requires \(name) \(Policy.supportedVersion)")
    }
    let previous = try inspect(home: home)
    let ownership = try receipts(stateRoot).read()
    if let ownership, previous.registration != ownership.registration {
      throw blocked("owned LaunchAgent has changed; refusing to replace or adopt it")
    }
    // A loaded, failed job is not equivalent to an unloaded service. Starting it
    // cannot restore its prior failure state on rollback, so leave it explicit.
    guard !previous.loaded || previous.running else {
      throw blocked(
        "the loaded \(name) service is not running; resolve its Accessibility/startup failure before applying"
      )
    }
    return UserServiceChange(previous: previous, previousOwnership: ownership)
  }

  func inspect(home: URL) throws -> UserServiceState {
    let registration = try registration(home: home)
    let job = try loadedJob()
    let observed = try process()
    if case .indeterminate(let message) = observed { throw blocked(message) }
    if let job {
      guard registration != nil,
        job.split(whereSeparator: \.isNewline).contains(where: {
          $0.trimmingCharacters(in: .whitespaces) == "path = \(propertyList(home).path)"
        })
      else { throw blocked("loaded \(name) job does not match its supported LaunchAgent") }
      if case .running(let pid?) = observed {
        guard
          job.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "pid = \(pid)"
          })
        else { throw blocked("\(name) process and loaded service disagree") }
      }
    } else if observed != .notRunning {
      throw blocked(
        "\(name) is running outside its supported user service; no service mutation is safe")
    }
    try requireEnabled()
    return UserServiceState(
      registration: registration, loaded: job != nil, running: observed != .notRunning)
  }

  /// Caller writes installationAttempted before this operation and installed
  /// evidence after it, both in the provider's existing durable transaction.
  func install(home: URL) throws -> UserServiceRegistration {
    guard try registration(home: home) == nil, try loadedJob() == nil,
      try process() == .notRunning
    else { throw blocked("service appeared since approval; refusing installation") }
    try requireEnabled()
    try mutate("--install-service")
    guard let installed = try registration(home: home) else {
      throw blocked("native install did not create the \(name) LaunchAgent")
    }
    return installed
  }

  func start(home: URL, expected: UserServiceRegistration) throws {
    try requireRegistration(expected, home: home)
    try requireEnabled()
    try mutate("--start-service")
  }

  func stop(home: URL, expected: UserServiceRegistration) throws {
    try requireRegistration(expected, home: home)
    if try loadedJob() != nil { try mutate("--stop-service") }
    for _ in 0..<20 {
      let observed = try process()
      if observed == .notRunning, try loadedJob() == nil {
        if Policy.nativeStopDisablesJob { try restoreEnabledAfterNativeStop(home, expected) }
        return
      }
      if case .indeterminate(let message) = observed { throw blocked(message) }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw blocked("\(name) did not stop; service restoration remains pending")
  }

  /// Every admitted prior state was enabled. Restore that state while the authenticated
  /// registration and rollback journal still exist; enable does not bootstrap/start the
  /// job. A failure must retain recovery evidence.
  private func restoreEnabledAfterNativeStop(
    _ home: URL, _ expected: UserServiceRegistration
  ) throws {
    try requireRegistration(expected, home: home)
    if try isDisabled() {
      let result = try run(
        URL(filePath: "/bin/launchctl"), ["enable", "gui/\(getuid())/\(Self.label)"])
      guard result.terminationStatus == 0 else {
        throw blocked("cannot restore \(name)'s enabled state after native stop: \(result.output)")
      }
    }
    try requireEnabled()
  }

  func uninstall(home: URL, expected: UserServiceRegistration) throws {
    if try registration(home: home) == nil {
      guard try loadedJob() == nil, try process() == .notRunning else {
        throw blocked("absent LaunchAgent still has runtime state")
      }
      return  // Recovery after native uninstall, before receipt removal.
    }
    try stop(home: home, expected: expected)
    try requireRegistration(expected, home: home)
    try mutate("--uninstall-service")
    guard try registration(home: home) == nil else {
      throw blocked("native uninstall did not remove the owned \(name) LaunchAgent")
    }
  }

  func validateRecovery(_ change: UserServiceChange, home: URL) throws {
    guard change.isValid else { throw blocked("invalid \(name) service transaction evidence") }
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

  func rollback(_ change: UserServiceChange, home: URL, stateRoot: URL) throws {
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
      guard try loadedJob() == nil, try process() == .notRunning else {
        throw blocked("cannot restore the absent service while unclaimed runtime state exists")
      }
    }
    try receipts(stateRoot).write(change.previousOwnership)
  }

  func commit(_ change: UserServiceChange, home: URL, stateRoot: URL) throws {
    guard let registration = change.expectedRegistration else {
      throw blocked("cannot commit service ownership without a registration")
    }
    try requireRegistration(registration, home: home)
    let ownership =
      change.previousOwnership
      ?? UserServiceOwnership(original: change.previous, registration: registration)
    try receipts(stateRoot).write(ownership)
  }

  func restoreOriginal(_ ownership: UserServiceOwnership, home: URL) throws {
    if ownership.original.running {
      try start(home: home, expected: ownership.registration)
    } else {
      try stop(home: home, expected: ownership.registration)
    }
  }

  func finalizeTeardown(_ ownership: UserServiceOwnership, home: URL, stateRoot: URL) throws {
    if ownership.original.registration == nil {
      try uninstall(home: home, expected: ownership.registration)
    } else {
      try requireRegistration(ownership.registration, home: home)
    }
    try receipts(stateRoot).write(nil)
  }

  func registration(home: URL) throws -> UserServiceRegistration? {
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
      plist["StandardOutPath"] as? String == "/tmp/\(name)_\(NSUserName()).out.log",
      plist["StandardErrorPath"] as? String == "/tmp/\(name)_\(NSUserName()).err.log",
      plist["ProcessType"] as? String == "Interactive", plist["Nice"] as? Int == -20
    else {
      throw blocked(
        "custom or unsupported \(name) LaunchAgent is protected; it will not be overwritten or adopted"
      )
    }
    return UserServiceRegistration(
      digest: sha256Digest(data), inode: UInt64(info.st_ino),
      volumeUUID: try RetainedOriginalIdentity.volumeUUID(at: file, matching: info),
      permissions: info.st_mode & 0o7777)
  }

  private func requireRegistration(_ expected: UserServiceRegistration, home: URL) throws {
    guard try registration(home: home) == expected else {
      throw blocked("\(name) LaunchAgent changed; refusing service mutation")
    }
  }

  private func loadedJob() throws -> String? {
    let result = try run(
      URL(filePath: "/bin/launchctl"), ["print", "gui/\(getuid())/\(Self.label)"])
    guard result.terminationStatus == 0 || result.terminationStatus == 113 else {
      throw blocked("cannot inspect \(name) launchd state: \(result.output)")
    }
    return result.terminationStatus == 0 ? result.output : nil
  }

  private func requireEnabled() throws {
    if try isDisabled() {
      throw blocked("\(name) was explicitly disabled; setup will not enable it silently")
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
      throw blocked("\(name) \(argument) failed: \(result.output)")
    }
  }

  private func run(_ executable: URL, _ arguments: [String]) throws -> ProcessResult {
    try runner.run(ProcessRequest(executableURL: executable, arguments: arguments, timeout: 10))
  }

  private func blocked(_ message: String) -> any Error {
    Policy.lifecycleError(message)
  }
}

struct NativeUserServiceOwnershipStore<Policy: NativeUserServicePolicy>: Sendable {
  let stateRoot: URL
  private var file: URL { stateRoot.appending(path: Policy.receiptPath) }

  func read() throws -> UserServiceOwnership? {
    do {
      let data = try BoundedRegularFile.read(at: file, maximumSize: 16_384).data
      let ownership = try JSONDecoder().decode(UserServiceOwnership.self, from: data)
      guard ownership.isValid else {
        throw Policy.lifecycleError("invalid \(Policy.name) service ownership evidence")
      }
      return ownership
    } catch BoundedRegularFileError.system(_, ENOENT) { return nil }
  }

  func write(_ ownership: UserServiceOwnership?) throws {
    if let ownership {
      let descriptor = try PinnedFilesystem.openDirectory(at: file.deletingLastPathComponent())
      defer { Darwin.close(descriptor) }
      try PinnedStateFile.write(
        ownership, parentDescriptor: descriptor, name: file.lastPathComponent, url: file)
    } else {
      guard unlink(file.path) == 0 || errno == ENOENT else {
        throw Policy.lifecycleError("cannot remove \(Policy.name) service ownership receipt")
      }
    }
  }
}
