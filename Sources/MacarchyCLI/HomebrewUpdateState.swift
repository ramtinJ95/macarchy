import Darwin
import Foundation
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
    try writeBoundedEvidenceJSON(
      evidence,
      to: evidenceURL,
      temporaryPrefix: ".upgrade-",
      tooLargeError: HomebrewUpgradeEvidenceError.tooLarge,
      replaceError: HomebrewUpgradeEvidenceError.replaceFailed
    )
  }
}

enum HomebrewUpgradeEvidenceError: Error, CustomStringConvertible, Equatable, Sendable {
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
