import Foundation

/// Which installations background surfaces check for updates, how often the top-bar indicator
/// checks, and which cached release it offers.
enum UpdateCheckPolicy {
  /// Setting this environment variable to `1` disables automatic update checks.
  static let disableVariable = "MACARCHY_DISABLE_UPDATE_CHECKS"
  static let indicatorCheckInterval: TimeInterval = 6 * 60 * 60
  /// Failures are usually transient, such as being offline right after wake.
  static let indicatorFailedRetryInterval: TimeInterval = 15 * 60

  static var automaticChecksEnabled: Bool {
    ProcessInfo.processInfo.environment[disableVariable] != "1"
  }

  /// The installed version to compare; update checks require a stable Homebrew installation.
  static func checkableVersion(_ build: MacarchyBuildInformation) -> StableVersion? {
    build.installation == .homebrew ? StableVersion(build.version) : nil
  }

  /// The last successfully checked release, when it is newer than `installed`.
  static func newerRelease(in cache: UpdateCacheRead, than installed: StableVersion) -> String? {
    guard case .available(let document) = cache, let release = document.lastSuccess?.release,
      let upstream = StableVersion(release.version), upstream > installed
    else { return nil }
    return release.version
  }
}
