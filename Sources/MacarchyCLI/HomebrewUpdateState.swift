import Darwin
import Foundation
import Synchronization
import ThemeCore

struct HomebrewUpgradeEvidence: Encodable, Sendable {
  enum Outcome: String, Encodable, Sendable {
    case started
    case succeeded
    case upgradeFailed = "upgrade_failed"
    case verificationFailed = "verification_failed"
  }

  let schemaVersion = 1
  let attemptedAt: Date
  let installedVersion: String
  let targetVersion: String
  let outcome: Outcome
  let error: String?
}

struct HomebrewUpgradeEvidenceStore: Sendable {
  let root: URL

  var evidenceURL: URL {
    root.appending(path: "state/update/upgrade.json")
  }

  func write(_ evidence: HomebrewUpgradeEvidence) throws {
    let directory = evidenceURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(evidence)
    guard data.count <= BoundedRegularFile.maximumSize else {
      throw HomebrewUpgradeEvidenceError.tooLarge
    }

    let temporary = directory.appending(path: ".upgrade-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: temporary.path
    )
    if rename(temporary.path, evidenceURL.path) != 0 {
      throw HomebrewUpgradeEvidenceError.replaceFailed(errno)
    }
  }
}

enum HomebrewUpgradeEvidenceError: Error, CustomStringConvertible, Sendable {
  case replaceFailed(Int32)
  case tooLarge

  var description: String {
    switch self {
    case .replaceFailed(let code):
      "Could not replace Homebrew upgrade evidence (errno \(code)): "
        + String(cString: strerror(code))
    case .tooLarge:
      "Homebrew upgrade evidence exceeds the 1 MiB limit"
    }
  }
}

struct HomebrewUpdateLock: Sendable {
  private static let processMutex = Mutex<Void>(())
  private let root: URL

  init(root: URL) {
    self.root = root.standardizedFileURL
  }

  func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
    try Self.processMutex.withLock { _ in
      let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: runDirectory,
        withIntermediateDirectories: true
      )
      let lockURL = runDirectory.appending(path: "homebrew-update.lock")
      let descriptor = lockURL.path.withCString {
        Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      }
      guard descriptor >= 0 else {
        throw HomebrewUpdateLockError.system("open", errno)
      }
      defer { Darwin.close(descriptor) }
      while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
        if errno == EINTR { continue }
        throw HomebrewUpdateLockError.system("acquire", errno)
      }
      return try operation()
    }
  }
}

enum HomebrewUpdateLockError: Error, CustomStringConvertible, Sendable {
  case system(String, Int32)

  var description: String {
    switch self {
    case .system(let operation, let code):
      "Cannot \(operation) Homebrew update lock (errno \(code)): "
        + String(cString: strerror(code))
    }
  }
}
