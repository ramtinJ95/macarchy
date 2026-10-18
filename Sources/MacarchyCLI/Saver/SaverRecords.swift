import CryptoKit
import Darwin
import Foundation
import ThemeCore

struct SaverError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// A display the saver covers: a Kitty output name, or Kitty's default display when Kitty
/// reports no names.
enum SaverDisplay: Hashable, Sendable {
  case main
  case output(String)

  init(outputName: String?) {
    self = outputName.map { SaverDisplay.output($0) } ?? .main
  }

  var outputName: String? {
    guard case .output(let name) = self else { return nil }
    return name
  }

  /// A file name that cannot collide or escape the records directory, whatever the output name.
  var recordName: String {
    guard case .output(let name) = self else { return "main.json" }
    let digest = SHA256.hash(data: Data(name.utf8)).prefix(8)
    return "output-\(digest.map { String(format: "%02x", $0) }.joined()).json"
  }

  var label: String {
    switch self {
    case .main: "the main display"
    case .output(let name): name
    }
  }
}

/// A process in a saver session. It is the recorded process only while its PID still has the
/// recorded start time and executable.
struct SaverProcess: Codable, Equatable, Sendable {
  let pid: Int32
  /// Start identity in microseconds (`processStartTime`).
  let started: UInt64
  let executablePath: String

  /// The live identity of `pid`, or nil when the kernel cannot resolve it.
  static func observe(_ pid: Int32) -> Self? {
    guard let started = processStartTime(pid), let path = processExecutablePath(pid) else {
      return nil
    }
    return Self(pid: pid, started: started, executablePath: path)
  }

  /// Whether the executable is named macarchy, as every runner's is. Its file is checked only
  /// when the runner registers: an upgrade that later removes it leaves the session Macarchy's.
  var runsMacarchy: Bool { URL(filePath: executablePath).lastPathComponent == "macarchy" }
}

/// One `macarchy saver start`. Each panel's runner gets the token as provenance, not as a secret,
/// and registers only while it names the current launch, so a panel that opens after its start
/// gave up or after a stop never plays.
struct SaverLaunch: Codable, Equatable, Sendable {
  let token: String
  /// When the start began waiting for its runners to register.
  let created: Date

  /// 128 random bits.
  static func randomToken() -> String {
    let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func isToken(_ text: String) -> Bool {
    text.utf8.count == 32
      && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }
}

/// What a runner registers for its display: itself and the panel Kitty that hosts it.
struct SaverRunnerRecord: Codable, Equatable, Sendable {
  /// nil for Kitty's default display.
  let output: String?
  /// The token of the launch that opened this panel.
  let launch: String
  let runner: SaverProcess
  let panel: SaverProcess

  var display: SaverDisplay { SaverDisplay(outputName: output) }

  /// Only a macarchy runner in a Kitty panel is ever recorded, so a stop can never signal another
  /// program.
  var isValid: Bool {
    runner.pid > 1 && panel.pid > 1 && runner.pid != panel.pid && runner.started > 0
      && panel.started > 0 && panel.executablePath == SaverKitty.executable && runner.runsMacarchy
      && SaverLaunch.isToken(launch)
  }
}

struct SaverRecordEntry: Equatable, Sendable {
  let name: String
  /// nil when the file is not a valid record.
  let record: SaverRunnerRecord?
}

/// One record per display in `<state root>/run/saver/`. Only that display's runner writes it,
/// so concurrent runners never share a file.
struct SaverRecords {
  private static let lock = ProcessScopedFileLock<SaverError>(
    filename: "saver.lock",
    cannotCreateRunDirectory: { url, error in SaverError("cannot create \(url.path): \(error)") },
    operationError: { operation, code in
      SaverError("cannot \(operation) the screensaver lock (errno \(code))")
    })

  let stateRoot: URL

  var directory: URL { stateRoot.appending(path: "run/saver", directoryHint: .isDirectory) }

  /// The panels' `KITTY_CACHE_DIRECTORY`, apart from the user's own Kitty cache.
  var kittyCache: URL { directory.appending(path: "kitty-cache", directoryHint: .isDirectory) }

  /// The launch a start is waiting on. It sits beside the lock that guards it, outside the
  /// directory of display records.
  var launch: RunStateRecord<SaverLaunch> {
    RunStateRecord("saver-launch.json", stateRoot: stateRoot) { SaverLaunch.isToken($0.token) }
  }

  /// Serializes launches, registrations and stops.
  func withLock<Output>(_ body: () throws -> Output) throws -> Output {
    try Self.lock.withLock(root: stateRoot, body)
  }

  func record(_ display: SaverDisplay) -> RunStateRecord<SaverRunnerRecord> {
    record(named: display.recordName)
  }

  /// Records `session` for its display while its launch is the current one and the display has
  /// no record yet. Otherwise returns false and writes nothing. Each runner registers itself, so
  /// this is where its own executable must still be a regular file.
  func register(_ session: SaverRunnerRecord) throws -> Bool {
    var metadata = stat()
    let executable = session.runner.executablePath
    guard lstat(executable, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      throw SaverError("this runner's executable \(executable) is not a regular file")
    }
    return try withLock { () throws -> Bool in
      guard try launch.read()?.token == session.launch else { return false }
      try create()
      let record = self.record(session.display)
      guard try record.read() == nil else { return false }
      try record.write(session)
      return true
    }
  }

  /// Removes `session`'s display record while it still names `session`'s runner. This runs
  /// without the lock, which a stop holds while it waits for this runner to exit. The record
  /// cannot change in between: registration never replaces a record, and a stop removes one only
  /// once its runner is gone.
  func unregister(_ session: SaverRunnerRecord) throws {
    let record = self.record(session.display)
    guard try record.read()?.runner == session.runner else { return }
    try record.remove()
  }

  func create() throws {
    try FileManager.default.createDirectory(
      at: kittyCache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  func entries() throws -> [SaverRecordEntry] {
    guard let descriptor = try PinnedFilesystem.openDirectoryIfPresent(at: directory) else {
      return []
    }
    defer { Darwin.close(descriptor) }
    let listing = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor, url: directory, limit: 256)
    guard !listing.truncated else {
      throw SaverError("\(directory.path) has more than 256 entries; remove the stale ones")
    }
    return try listing.entries.filter { $0.hasSuffix(".json") }.map { name in
      SaverRecordEntry(name: name, record: try record(named: name).read())
    }
  }

  func remove(_ name: String) throws {
    try record(named: name).remove()
  }

  private func record(named name: String) -> RunStateRecord<SaverRunnerRecord> {
    RunStateRecord(name, directory: directory) { $0.isValid }
  }
}

/// SIGTERM to a process whose identity was just verified; one that already exited is not an
/// error.
func terminateSaverProcess(_ pid: Int32) throws {
  guard kill(pid, SIGTERM) != 0 else { return }
  let code = errno
  guard code == ESRCH else {
    throw SaverError("cannot signal process \(pid) (errno \(code))")
  }
}
