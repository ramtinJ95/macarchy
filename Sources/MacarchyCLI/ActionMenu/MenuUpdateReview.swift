import Foundation

struct MenuUpdateReview: Sendable {
  let runner: HomebrewUpdateRunner
  let inspectRelease: @Sendable () throws -> StableRelease?
  let io: GuidedSetupIO

  func approval() throws -> HomebrewUpdateApproval? {
    guard try runner.buildInformation().installation == .homebrew else {
      throw MenuUpdateReviewError(
        description: "Review & update requires a stable Homebrew installation.")
    }
    let (prefix, build) = try runner.inspectInstallation()
    guard build.installation == .homebrew, let installed = StableVersion(build.version) else {
      throw MenuUpdateReviewError(
        description:
          "Review & update requires a stable Homebrew installation.")
    }
    guard let release = try inspectRelease(), let upstream = StableVersion(release.version) else {
      throw MenuUpdateReviewError(description: "No stable release is available to review.")
    }
    let tap = runner.tapVersion()
    io.write(
      "Installed: \(build.version) (Homebrew)\nStable release: \(release.version)\n\(release.url)\n"
    )
    io.write("Locally known tap: \(tap.version ?? tap.error ?? "unavailable") (not refreshed)\n")
    guard installed <= upstream else {
      throw MenuUpdateReviewError(
        description:
          "Installed version is ahead of the stable release; refusing downgrade.")
    }
    io.write(
      "Confirmation refreshes Homebrew/tap metadata and the update-check cache, then upgrades only "
        + "\(HomebrewUpdateRunner.formula) to \(release.version) if needed and verifies the installation.\n"
        + "A changed release or inconsistent refreshed tap stops the upgrade; packaging pending is a no-op.\n"
        + "No dependent upgrades, cleanup, profile apply or provider restart. Homebrew effects have no automatic rollback.\n"
    )
    guard try io.confirm("Update to the reviewed release (or verify if current)?") else {
      return nil
    }
    return HomebrewUpdateApproval(prefix: prefix, build: build, release: release)
  }
}

struct MenuUpdateReviewError: Error, CustomStringConvertible {
  let description: String
}
