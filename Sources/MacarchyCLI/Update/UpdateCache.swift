import Darwin
import Foundation
import ThemeCore

struct StableVersion: Comparable, Equatable, Sendable {
  let major: Int
  let minor: Int
  let patch: Int

  init?(_ value: String) {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }
    var numbers = [Int]()
    for component in components {
      guard !component.isEmpty,
        component.allSatisfy(\.isNumber),
        component == "0" || component.first != "0",
        let number = Int(component)
      else {
        return nil
      }
      numbers.append(number)
    }
    major = numbers[0]
    minor = numbers[1]
    patch = numbers[2]
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

struct StableRelease: Codable, Equatable, Sendable {
  let version: String
  let tag: String
  let url: String
}

struct UpdateCheckAttempt: Codable, Equatable, Sendable {
  enum Outcome: String, Codable, Sendable {
    case success
    case failure
  }

  let checkedAt: Date
  let outcome: Outcome
  let error: String?
}

struct UpdateCheckSuccess: Codable, Equatable, Sendable {
  static let maximumValidatorSize = 1024

  let checkedAt: Date
  let release: StableRelease?
  let etag: String?
  let lastModified: String?
}

struct UpdateCacheDocument: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let lastAttempt: UpdateCheckAttempt
  let lastSuccess: UpdateCheckSuccess?

  init(lastAttempt: UpdateCheckAttempt, lastSuccess: UpdateCheckSuccess?) {
    schemaVersion = Self.currentSchemaVersion
    self.lastAttempt = lastAttempt
    self.lastSuccess = lastSuccess
  }
}

enum UpdateCacheRead: Equatable, Sendable {
  case missing
  case available(UpdateCacheDocument)
  case invalid(String)
}

struct UpdateCacheStore: Sendable {
  let root: URL

  var cacheURL: URL {
    root.appending(path: "state/update/check.json")
  }

  func read() -> UpdateCacheRead {
    guard FileManager.default.fileExists(atPath: cacheURL.path) else {
      return .missing
    }
    do {
      let file = try BoundedRegularFile.read(at: cacheURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let document = try decoder.decode(UpdateCacheDocument.self, from: file.data)
      guard document.schemaVersion == UpdateCacheDocument.currentSchemaVersion else {
        return .invalid(
          "unsupported schema version \(document.schemaVersion); expected "
            + "\(UpdateCacheDocument.currentSchemaVersion)"
        )
      }
      switch document.lastAttempt.outcome {
      case .success:
        guard document.lastAttempt.error == nil,
          let lastSuccess = document.lastSuccess,
          lastSuccess.checkedAt == document.lastAttempt.checkedAt
        else {
          return .invalid("successful attempt evidence is inconsistent")
        }
      case .failure:
        guard let error = document.lastAttempt.error, !error.isEmpty else {
          return .invalid("failed attempt has no error evidence")
        }
        guard document.lastSuccess?.checkedAt ?? .distantPast <= document.lastAttempt.checkedAt
        else {
          return .invalid("last success is later than the latest attempt")
        }
      }
      if let release = document.lastSuccess?.release {
        guard StableVersion(release.version) != nil, release.tag == "v\(release.version)",
          let url = URL(string: release.url), url.scheme == "https", url.host == "github.com"
        else {
          return .invalid("cached release metadata is invalid")
        }
      }
      let validators = [
        document.lastSuccess?.etag,
        document.lastSuccess?.lastModified,
      ].compactMap { $0 }
      guard validators.allSatisfy({ $0.utf8.count <= UpdateCheckSuccess.maximumValidatorSize })
      else {
        return .invalid("cached conditional validator exceeds the 1 KiB limit")
      }
      return .available(document)
    } catch {
      return .invalid(String(describing: error))
    }
  }

  func write(_ document: UpdateCacheDocument) throws {
    try writeBoundedEvidenceJSON(
      document,
      to: cacheURL,
      temporaryPrefix: ".check-",
      tooLargeError: UpdateCacheError.tooLarge,
      replaceError: UpdateCacheError.replaceFailed
    )
  }
}

enum UpdateCacheError: Error, CustomStringConvertible, Equatable, Sendable {
  case replaceFailed(Int32)
  case tooLarge

  var description: String {
    switch self {
    case .replaceFailed(let code):
      "Could not replace update cache (errno \(code)): \(String(cString: strerror(code)))"
    case .tooLarge:
      "Update cache exceeds the 1 MiB limit"
    }
  }
}

func boundedUpdateEvidence(_ value: String) -> String {
  let normalized = value.unicodeScalars.map {
    CharacterSet.controlCharacters.contains($0) ? " " : String($0)
  }.joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let maximumBytes = 512
  if normalized.utf8.count <= maximumBytes { return normalized }

  let prefixLimit = maximumBytes - 3
  let scalars = normalized.unicodeScalars
  var end = scalars.startIndex
  var byteCount = 0
  while end != scalars.endIndex {
    let scalarBytes = String(scalars[end]).utf8.count
    if byteCount + scalarBytes > prefixLimit { break }
    byteCount += scalarBytes
    end = scalars.index(after: end)
  }
  return String(scalars[..<end]) + "..."
}
