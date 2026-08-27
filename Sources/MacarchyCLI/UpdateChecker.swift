import Darwin
import Foundation
import Synchronization

struct UpdateCheckExecution: Sendable {
  let cache: UpdateCacheDocument
  let refreshed: Bool
  let succeeded: Bool
}

struct UpdateChecker: Sendable {
  static let freshnessInterval: TimeInterval = 24 * 60 * 60
  static let latestReleaseURL = URL(
    string: "https://api.github.com/repos/ramtinJ95/macarchy/releases/latest"
  )!

  let cacheStore: UpdateCacheStore
  let httpClient: UpdateHTTPClient
  let now: @Sendable () -> Date
  let lock: UpdateCheckLock

  init(
    root: URL,
    httpClient: UpdateHTTPClient,
    now: @escaping @Sendable () -> Date
  ) {
    cacheStore = UpdateCacheStore(root: root)
    self.httpClient = httpClient
    self.now = now
    lock = UpdateCheckLock(root: root)
  }

  func check(ifStaleOnly: Bool) -> UpdateCheckExecution {
    do {
      return try lock.withLock {
        let existing = cacheStore.read()
        if ifStaleOnly, case .available(let cache) = existing,
          Self.isFresh(cache, at: now())
        {
          return UpdateCheckExecution(cache: cache, refreshed: false, succeeded: true)
        }
        return refresh(previous: existing)
      }
    } catch {
      let failure = failedCache(
        previous: cacheStore.read(),
        checkedAt: now(),
        error: "Could not coordinate update check: \(error)"
      )
      return UpdateCheckExecution(cache: failure, refreshed: false, succeeded: false)
    }
  }

  static func isFresh(_ cache: UpdateCacheDocument, at date: Date) -> Bool {
    let age = date.timeIntervalSince(cache.lastAttempt.checkedAt)
    return age < freshnessInterval
  }

  private func refresh(previous: UpdateCacheRead) -> UpdateCheckExecution {
    let observedAt = now()
    let lastSuccess: UpdateCheckSuccess?
    if case .available(let cache) = previous {
      lastSuccess = cache.lastSuccess
    } else {
      lastSuccess = nil
    }
    let checkedAt = max(observedAt, lastSuccess?.checkedAt ?? observedAt)
    let request = UpdateHTTPRequest(
      url: Self.latestReleaseURL,
      headers: requestHeaders(lastSuccess: lastSuccess)
    )

    do {
      let response = try httpClient.send(request)
      guard response.body.count <= UpdateHTTPClient.maximumResponseSize else {
        throw UpdateCheckError.responseTooLarge
      }
      let success = try success(
        response: response,
        checkedAt: checkedAt,
        previous: lastSuccess
      )
      let cache = UpdateCacheDocument(
        lastAttempt: UpdateCheckAttempt(
          checkedAt: checkedAt,
          outcome: .success,
          error: nil
        ),
        lastSuccess: success
      )
      do {
        try cacheStore.write(cache)
        return UpdateCheckExecution(cache: cache, refreshed: true, succeeded: true)
      } catch {
        return persistFailure(
          previous: previous,
          checkedAt: checkedAt,
          error: "GitHub check succeeded, but its cache could not be written: \(error)"
        )
      }
    } catch {
      return persistFailure(
        previous: previous,
        checkedAt: checkedAt,
        error: String(describing: error)
      )
    }
  }

  private func persistFailure(
    previous: UpdateCacheRead,
    checkedAt: Date,
    error: String
  ) -> UpdateCheckExecution {
    let failure = failedCache(previous: previous, checkedAt: checkedAt, error: error)
    do {
      try cacheStore.write(failure)
      return UpdateCheckExecution(cache: failure, refreshed: true, succeeded: false)
    } catch {
      return UpdateCheckExecution(
        cache: failedCache(
          previous: previous,
          checkedAt: checkedAt,
          error: "\(failure.lastAttempt.error ?? "Update check failed"); "
            + "failure evidence could not be cached: \(error)"
        ),
        refreshed: true,
        succeeded: false
      )
    }
  }

  private func requestHeaders(lastSuccess: UpdateCheckSuccess?) -> [String: String] {
    var headers = [
      "Accept": "application/vnd.github+json",
      "User-Agent": "Macarchy/\(RuntimeEnvironment.sourceVersion)",
      "X-GitHub-Api-Version": "2022-11-28",
    ]
    if let etag = lastSuccess?.etag {
      headers["If-None-Match"] = etag
    }
    if let lastModified = lastSuccess?.lastModified {
      headers["If-Modified-Since"] = lastModified
    }
    return headers
  }

  private func success(
    response: UpdateHTTPResponse,
    checkedAt: Date,
    previous: UpdateCheckSuccess?
  ) throws -> UpdateCheckSuccess {
    switch response.statusCode {
    case 200:
      let document: GitHubLatestRelease
      do {
        document = try JSONDecoder().decode(GitHubLatestRelease.self, from: response.body)
      } catch {
        throw UpdateCheckError.invalidRelease("GitHub release response could not be decoded")
      }
      guard !document.draft, !document.prerelease else {
        throw UpdateCheckError.invalidRelease("GitHub latest release was not stable")
      }
      guard document.tagName.first == "v" else {
        throw UpdateCheckError.invalidRelease(
          "GitHub release tag '\(document.tagName)' is not vMAJOR.MINOR.PATCH"
        )
      }
      let version = String(document.tagName.dropFirst())
      guard StableVersion(version) != nil, document.tagName == "v\(version)" else {
        throw UpdateCheckError.invalidRelease(
          "GitHub release tag '\(document.tagName)' is not vMAJOR.MINOR.PATCH"
        )
      }
      guard let releaseURL = URL(string: document.htmlURL),
        releaseURL.scheme == "https",
        releaseURL.host == "github.com"
      else {
        throw UpdateCheckError.invalidRelease("GitHub release URL is invalid")
      }
      return UpdateCheckSuccess(
        checkedAt: checkedAt,
        release: StableRelease(version: version, tag: document.tagName, url: document.htmlURL),
        etag: try validator("ETag", in: response),
        lastModified: try validator("Last-Modified", in: response)
      )
    case 304:
      guard let previous else {
        throw UpdateCheckError.notModifiedWithoutCache
      }
      return UpdateCheckSuccess(
        checkedAt: checkedAt,
        release: previous.release,
        etag: try validator("ETag", in: response) ?? previous.etag,
        lastModified: try validator("Last-Modified", in: response) ?? previous.lastModified
      )
    case 404:
      return UpdateCheckSuccess(
        checkedAt: checkedAt,
        release: nil,
        etag: try validator("ETag", in: response),
        lastModified: try validator("Last-Modified", in: response)
      )
    default:
      throw UpdateCheckError.httpStatus(response.statusCode)
    }
  }

  private func validator(
    _ name: String,
    in response: UpdateHTTPResponse
  ) throws -> String? {
    guard let value = response.header(name) else { return nil }
    guard value.utf8.count <= UpdateCheckSuccess.maximumValidatorSize else {
      throw UpdateCheckError.invalidValidator(name)
    }
    return value
  }

  private func failedCache(
    previous: UpdateCacheRead,
    checkedAt: Date,
    error: String
  ) -> UpdateCacheDocument {
    let lastSuccess: UpdateCheckSuccess?
    if case .available(let cache) = previous {
      lastSuccess = cache.lastSuccess
    } else {
      lastSuccess = nil
    }
    return UpdateCacheDocument(
      lastAttempt: UpdateCheckAttempt(
        checkedAt: checkedAt,
        outcome: .failure,
        error: boundedUpdateEvidence(error)
      ),
      lastSuccess: lastSuccess
    )
  }
}

private struct GitHubLatestRelease: Decodable {
  let tagName: String
  let htmlURL: String
  let draft: Bool
  let prerelease: Bool

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case draft
    case prerelease
  }
}

enum UpdateCheckError: Error, CustomStringConvertible, Equatable, Sendable {
  case httpStatus(Int)
  case invalidRelease(String)
  case invalidValidator(String)
  case notModifiedWithoutCache
  case responseTooLarge

  var description: String {
    switch self {
    case .httpStatus(let status):
      "GitHub latest release request returned HTTP \(status)"
    case .invalidRelease(let reason):
      reason
    case .invalidValidator(let name):
      "GitHub \(name) validator exceeded the 1 KiB limit"
    case .notModifiedWithoutCache:
      "GitHub returned 304 without a valid cached release check"
    case .responseTooLarge:
      "GitHub release response exceeded the 256 KiB limit"
    }
  }
}

struct UpdateCheckLock: Sendable {
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
      let lockURL = runDirectory.appending(path: "update-check.lock")
      let descriptor = lockURL.path.withCString {
        Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      }
      guard descriptor >= 0 else {
        throw UpdateCheckLockError.system("open", errno)
      }
      defer { Darwin.close(descriptor) }
      while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
        if errno == EINTR { continue }
        throw UpdateCheckLockError.system("acquire", errno)
      }
      return try operation()
    }
  }
}

enum UpdateCheckLockError: Error, CustomStringConvertible, Equatable, Sendable {
  case system(String, Int32)

  var description: String {
    switch self {
    case .system(let operation, let code):
      "Cannot \(operation) update-check lock (errno \(code)): \(String(cString: strerror(code)))"
    }
  }
}
