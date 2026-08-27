import Foundation

struct UpdateCommandRunner: Sendable {
  let buildInformation: @Sendable () throws -> MacarchyBuildInformation
  let tapVersion: @Sendable () -> HomebrewTapVersion
  let readCache: @Sendable (URL) -> UpdateCacheRead
  let check: @Sendable (URL, Bool) -> UpdateCheckExecution
  let now: @Sendable () -> Date

  static let live = UpdateCommandRunner(
    buildInformation: RuntimeEnvironment.live.buildInformation,
    tapVersion: HomebrewTapVersionReader.live.read,
    readCache: { UpdateCacheStore(root: $0).read() },
    check: { root, staleOnly in
      UpdateChecker(root: root, httpClient: .live, now: Date.init)
        .check(ifStaleOnly: staleOnly)
    },
    now: Date.init
  )

  func execute(
    stateRoot: URL,
    refresh: Bool,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let cacheRead: UpdateCacheRead
    let checkSucceeded: Bool
    if refresh {
      let execution = check(stateRoot, false)
      cacheRead = .available(execution.cache)
      checkSucceeded = execution.succeeded
    } else {
      cacheRead = readCache(stateRoot)
      checkSucceeded = true
    }
    let report = UpdateStatusReport(
      operation: refresh ? .check : .status,
      build: try buildInformation(),
      cacheRead: cacheRead,
      tap: tapVersion(),
      now: now()
    )
    return (try report.render(json: json), !refresh || checkSucceeded)
  }
}

private struct UpdateStatusReport {
  enum Operation: String, Encodable {
    case status = "update_status"
    case check = "update_check"
  }

  enum Outcome: String, Encodable {
    case cacheInvalid = "cache_invalid"
    case checkFailed = "check_failed"
    case comparisonUnavailable = "comparison_unavailable"
    case current
    case noStableRelease = "no_stable_release"
    case notChecked = "not_checked"
    case updateAvailable = "update_available"
  }

  enum UpstreamStatus: String, Encodable {
    case available
    case cacheInvalid = "cache_invalid"
    case checkFailed = "check_failed"
    case noStableRelease = "no_stable_release"
    case notChecked = "not_checked"
  }

  enum PackagingStatus: String, Encodable {
    case ahead
    case current
    case pending
    case unknown
  }

  let operation: Operation
  let build: MacarchyBuildInformation
  let cacheRead: UpdateCacheRead
  let tap: HomebrewTapVersion
  let now: Date

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }

    var lines = ["Macarchy \(operation == .check ? "update check" : "update status"):"]
    lines.append("- Installed: \(build.version) (\(build.installation.rawValue))")
    switch upstream {
    case .notChecked:
      lines.append("- Upstream stable: not checked")
    case .cacheInvalid(let error):
      lines.append("- Upstream stable: cache invalid (\(error))")
    case .noStableRelease(let checkedAt, let stale, let failedAttempt):
      var detail =
        "- Upstream stable: none (checked \(iso8601String(checkedAt))\(stale ? ", stale" : ""))"
      if let failedAttempt {
        detail += failedAttemptDescription(failedAttempt)
      }
      lines.append(detail)
    case .available(let release, let checkedAt, let stale, let failedAttempt):
      var detail =
        "- Upstream stable: \(release.version) (\(release.url)), "
        + "checked \(iso8601String(checkedAt))\(stale ? ", stale" : "")"
      if let failedAttempt {
        detail += failedAttemptDescription(failedAttempt)
      }
      lines.append(detail)
    case .checkFailed(let attempt):
      lines.append(
        "- Upstream stable: unavailable (check \(iso8601String(attempt.checkedAt)) failed: "
          + "\(attempt.error ?? "unknown error"))"
      )
    }
    if let version = tap.version {
      lines.append("- Local Homebrew tap: \(version)")
    } else {
      lines.append("- Local Homebrew tap: unavailable (\(tap.error ?? "unknown error"))")
    }
    lines.append("- Packaging: \(packaging.rawValue)")
    if let updateAvailable {
      lines.append("- Update available: \(updateAvailable ? "yes" : "no")")
    } else {
      lines.append("- Update available: unknown")
    }
    lines.append(
      operation == .status
        ? "No network request made."
        : outcome == .checkFailed ? "Update check failed." : "Update cache refreshed."
    )
    return lines.joined(separator: "\n")
  }

  private var jsonReport: UpdateStatusJSONReport {
    let upstreamJSON: UpdateUpstreamJSON
    switch upstream {
    case .notChecked:
      upstreamJSON = UpdateUpstreamJSON(status: .notChecked)
    case .cacheInvalid(let error):
      upstreamJSON = UpdateUpstreamJSON(status: .cacheInvalid, error: error)
    case .noStableRelease(let checkedAt, let stale, let failedAttempt):
      upstreamJSON = UpdateUpstreamJSON(
        status: failedAttempt == nil ? .noStableRelease : .checkFailed,
        checkedAt: iso8601String(checkedAt),
        attemptedAt: failedAttempt.map { iso8601String($0.checkedAt) },
        stale: stale,
        error: failedAttempt?.error
      )
    case .available(let release, let checkedAt, let stale, let failedAttempt):
      upstreamJSON = UpdateUpstreamJSON(
        status: failedAttempt == nil ? .available : .checkFailed,
        version: release.version,
        tag: release.tag,
        url: release.url,
        checkedAt: iso8601String(checkedAt),
        attemptedAt: failedAttempt.map { iso8601String($0.checkedAt) },
        stale: stale,
        error: failedAttempt?.error
      )
    case .checkFailed(let attempt):
      upstreamJSON = UpdateUpstreamJSON(
        status: .checkFailed,
        attemptedAt: iso8601String(attempt.checkedAt),
        error: attempt.error
      )
    }
    return UpdateStatusJSONReport(
      operation: operation,
      outcome: outcome,
      installed: UpdateInstalledJSON(
        version: build.version,
        installation: build.installation
      ),
      upstream: upstreamJSON,
      tap: tap,
      packaging: packaging,
      updateAvailable: updateAvailable
    )
  }

  private enum Upstream {
    case notChecked
    case cacheInvalid(String)
    case noStableRelease(Date, stale: Bool, failedAttempt: UpdateCheckAttempt?)
    case available(StableRelease, Date, stale: Bool, failedAttempt: UpdateCheckAttempt?)
    case checkFailed(UpdateCheckAttempt)
  }

  private var upstream: Upstream {
    switch cacheRead {
    case .missing:
      return .notChecked
    case .invalid(let error):
      return .cacheInvalid(boundedUpdateEvidence(error))
    case .available(let cache):
      let failedAttempt =
        cache.lastAttempt.outcome == .failure ? cache.lastAttempt : nil
      guard let success = cache.lastSuccess else {
        return failedAttempt.map(Upstream.checkFailed)
          ?? .cacheInvalid("successful attempt has no success evidence")
      }
      guard let release = success.release else {
        return .noStableRelease(
          success.checkedAt,
          stale: isStale(success.checkedAt),
          failedAttempt: failedAttempt
        )
      }
      return .available(
        release,
        success.checkedAt,
        stale: isStale(success.checkedAt),
        failedAttempt: failedAttempt
      )
    }
  }

  private func isStale(_ checkedAt: Date) -> Bool {
    let age = now.timeIntervalSince(checkedAt)
    return age >= UpdateChecker.freshnessInterval
  }

  private func failedAttemptDescription(_ attempt: UpdateCheckAttempt) -> String {
    "; latest check \(iso8601String(attempt.checkedAt)) failed: "
      + "\(attempt.error ?? "unknown error")"
  }

  private var updateAvailable: Bool? {
    guard case .available(let release, _, _, _) = upstream,
      let installed = StableVersion(build.version),
      let available = StableVersion(release.version)
    else {
      return nil
    }
    return available > installed
  }

  private var packaging: PackagingStatus {
    guard case .available(let release, _, _, _) = upstream,
      let upstreamVersion = StableVersion(release.version),
      let tapValue = tap.version,
      let tapVersion = StableVersion(tapValue)
    else {
      return .unknown
    }
    if tapVersion < upstreamVersion { return .pending }
    if tapVersion > upstreamVersion { return .ahead }
    return .current
  }

  private var outcome: Outcome {
    switch upstream {
    case .notChecked:
      return .notChecked
    case .cacheInvalid:
      return .cacheInvalid
    case .checkFailed:
      return .checkFailed
    case .noStableRelease(_, _, failedAttempt: .some),
      .available(_, _, _, failedAttempt: .some):
      return .checkFailed
    case .noStableRelease:
      return .noStableRelease
    case .available:
      guard let updateAvailable else { return .comparisonUnavailable }
      return updateAvailable ? .updateAvailable : .current
    }
  }
}

private struct UpdateStatusJSONReport: Encodable {
  let schemaVersion = 1
  let operation: UpdateStatusReport.Operation
  let outcome: UpdateStatusReport.Outcome
  let installed: UpdateInstalledJSON
  let upstream: UpdateUpstreamJSON
  let tap: HomebrewTapVersion
  let packaging: UpdateStatusReport.PackagingStatus
  let updateAvailable: Bool?
}

private struct UpdateInstalledJSON: Encodable {
  let version: String
  let installation: InstallationOwnership
}

private struct UpdateUpstreamJSON: Encodable {
  let status: UpdateStatusReport.UpstreamStatus
  var version: String? = nil
  var tag: String? = nil
  var url: String? = nil
  var checkedAt: String? = nil
  var attemptedAt: String? = nil
  var stale: Bool? = nil
  var error: String? = nil
}

private func iso8601String(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}
