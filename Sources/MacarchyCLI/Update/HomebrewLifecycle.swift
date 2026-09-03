import Darwin
import Foundation
import ThemeCore

enum HomebrewUpdateOutcome: String, Sendable {
  case current
  case evidenceWriteFailed = "evidence_write_failed"
  case metadataRefreshFailed = "metadata_refresh_failed"
  case packagingPending = "packaging_pending"
  case refused
  case releaseCheckFailed = "release_check_failed"
  case tapInspectionFailed = "tap_inspection_failed"
  case updated
  case upgradeFailed = "upgrade_failed"
  case verificationFailed = "verification_failed"
  case versionMismatch = "version_mismatch"
}

struct HomebrewUpdateExecution: Sendable {
  let outcome: HomebrewUpdateOutcome
  let output: String
  let succeeded: Bool
}

struct HomebrewUpdateRunner: Sendable {
  static let brewURL = URL(filePath: "/opt/homebrew/bin/brew")
  static let formula = HomebrewTapVersionReader.formula
  static let mutationEnvironment = [
    "HOMEBREW_NO_ANALYTICS": "1",
    "HOMEBREW_NO_AUTOREMOVE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
  ]
  static let metadataRequest = ProcessRequest(
    executableURL: brewURL,
    arguments: ["update"],
    environmentOverrides: mutationEnvironment
  )
  static let upgradeRequest = ProcessRequest(
    executableURL: brewURL,
    arguments: ["upgrade", "--formula", "--no-ask", formula],
    environmentOverrides: mutationEnvironment.merging(
      ["HOMEBREW_NO_AUTO_UPDATE": "1"],
      uniquingKeysWith: { _, override in override }
    )
  )
  static let recoveryCommand =
    "HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 "
    + "HOMEBREW_NO_INSTALL_CLEANUP=1 "
    + "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 "
    + "brew reinstall --formula --no-ask \(formula)"

  let buildInformation: @Sendable () throws -> MacarchyBuildInformation
  let refreshRelease: @Sendable (URL) -> UpdateCheckExecution
  let tapVersion: @Sendable () -> HomebrewTapVersion
  let streamProcess: @Sendable (ProcessRequest) throws -> Int32
  let verifyInstallation: @Sendable (String) throws -> Void
  let writeEvidence: @Sendable (URL, HomebrewUpgradeEvidence) throws -> Void
  let now: @Sendable () -> Date

  static let live = HomebrewUpdateRunner(
    buildInformation: RuntimeEnvironment.live.buildInformation,
    refreshRelease: {
      UpdateChecker(root: $0, httpClient: .live, now: Date.init)
        .check(ifStaleOnly: false)
    },
    tapVersion: HomebrewTapVersionReader.live.read,
    streamProcess: runStreamingProcess,
    verifyInstallation: HomebrewInstallationVerifier.live.verify,
    writeEvidence: { root, evidence in
      try HomebrewUpgradeEvidenceStore(root: root).write(evidence)
    },
    now: Date.init
  )

  func execute(stateRoot: URL) throws -> HomebrewUpdateExecution {
    let build = try buildInformation()
    guard build.installation == .homebrew,
      let installed = StableVersion(build.version)
    else {
      return failure(
        .refused,
        build: build,
        message:
          "Updates are available only for stable Homebrew installations. Install with "
          + "'brew install \(Self.formula)'; existing user state under ~/.config/macarchy is preserved."
      )
    }

    let metadataStatus: Int32
    do {
      metadataStatus = try streamProcess(Self.metadataRequest)
    } catch {
      return failure(
        .metadataRefreshFailed,
        build: build,
        message: "Could not launch Homebrew metadata refresh: \(error)"
      )
    }
    guard metadataStatus == 0 else {
      return failure(
        .metadataRefreshFailed,
        build: build,
        message: "Homebrew metadata refresh exited with status \(metadataStatus)."
      )
    }

    let releaseCheck = refreshRelease(stateRoot)
    guard releaseCheck.succeeded,
      let release = releaseCheck.cache.lastSuccess?.release,
      let upstream = StableVersion(release.version)
    else {
      let detail =
        releaseCheck.cache.lastAttempt.error
        ?? "GitHub has no stable Macarchy release to compare."
      return failure(.releaseCheckFailed, build: build, message: detail)
    }

    let tap = tapVersion()
    guard let tapValue = tap.version, let tapVersion = StableVersion(tapValue) else {
      return failure(
        .tapInspectionFailed,
        build: build,
        upstream: release.version,
        message: tap.error ?? "The refreshed Homebrew tap version is unavailable."
      )
    }
    guard installed <= upstream else {
      return failure(
        .versionMismatch,
        build: build,
        upstream: release.version,
        tap: tapValue,
        message: "The installed version is ahead of GitHub's latest stable release; no upgrade ran."
      )
    }
    if upstream > tapVersion {
      return result(
        .packagingPending,
        build: build,
        upstream: release.version,
        tap: tapValue,
        succeeded: true,
        message:
          "The stable release is newer than the refreshed tap. Packaging is pending; no upgrade ran."
      )
    }
    guard upstream == tapVersion else {
      return failure(
        .versionMismatch,
        build: build,
        upstream: release.version,
        tap: tapValue,
        message: "The refreshed tap is ahead of GitHub's latest stable release; no upgrade ran."
      )
    }
    if installed == tapVersion {
      do {
        try verifyInstallation(tapValue)
      } catch {
        return verificationFailure(
          build: build,
          upstream: release.version,
          tap: tapValue,
          error: error
        )
      }
      return result(
        .current,
        build: build,
        upstream: release.version,
        tap: tapValue,
        succeeded: true,
        message: "Macarchy \(build.version) is current."
      )
    }
    let attemptedAt = now()
    do {
      try writeEvidence(
        stateRoot,
        evidence(
          attemptedAt: attemptedAt,
          build: build,
          targetVersion: tapValue,
          outcome: .started
        )
      )
    } catch {
      return failure(
        .evidenceWriteFailed,
        build: build,
        upstream: release.version,
        tap: tapValue,
        message: "Cannot preserve pre-upgrade evidence; no upgrade ran: \(error)"
      )
    }

    let upgradeStatus: Int32
    do {
      upgradeStatus = try streamProcess(Self.upgradeRequest)
    } catch {
      var message = "Could not launch the scoped Homebrew upgrade: \(error)"
      message += failureEvidenceError(
        stateRoot: stateRoot,
        attemptedAt: attemptedAt,
        build: build,
        targetVersion: tapValue,
        outcome: .upgradeFailed,
        error: message
      )
      return failure(
        .upgradeFailed,
        build: build,
        upstream: release.version,
        tap: tapValue,
        message: message
      )
    }
    guard upgradeStatus == 0 else {
      var message = "Homebrew upgrade exited with status \(upgradeStatus)."
      message += failureEvidenceError(
        stateRoot: stateRoot,
        attemptedAt: attemptedAt,
        build: build,
        targetVersion: tapValue,
        outcome: .upgradeFailed,
        error: message
      )
      return failure(
        .upgradeFailed,
        build: build,
        upstream: release.version,
        tap: tapValue,
        message: message
      )
    }

    do {
      try verifyInstallation(tapValue)
    } catch {
      let verificationError = boundedUpdateEvidence(String(describing: error))
      let evidenceError = failureEvidenceError(
        stateRoot: stateRoot,
        attemptedAt: attemptedAt,
        build: build,
        targetVersion: tapValue,
        outcome: .verificationFailed,
        error: verificationError
      )
      return verificationFailure(
        build: build,
        upstream: release.version,
        tap: tapValue,
        error: error,
        evidenceError: evidenceError
      )
    }

    do {
      try writeEvidence(
        stateRoot,
        evidence(
          attemptedAt: attemptedAt,
          build: build,
          targetVersion: tapValue,
          outcome: .succeeded
        )
      )
    } catch {
      return failure(
        .evidenceWriteFailed,
        build: build,
        upstream: release.version,
        tap: tapValue,
        message:
          "Macarchy \(tapValue) was installed and verified, but success evidence could not be "
          + "persisted: \(error)"
      )
    }

    return result(
      .updated,
      build: build,
      upstream: release.version,
      tap: tapValue,
      succeeded: true,
      message:
        "Updated Macarchy from \(build.version) to \(tapValue) and verified release resources."
    )
  }

  private func failure(
    _ outcome: HomebrewUpdateOutcome,
    build: MacarchyBuildInformation,
    upstream: String? = nil,
    tap: String? = nil,
    message: String
  ) -> HomebrewUpdateExecution {
    result(
      outcome,
      build: build,
      upstream: upstream,
      tap: tap,
      succeeded: false,
      message: message
    )
  }

  private func verificationFailure(
    build: MacarchyBuildInformation,
    upstream: String,
    tap: String,
    error: Error,
    evidenceError: String = ""
  ) -> HomebrewUpdateExecution {
    failure(
      .verificationFailed,
      build: build,
      upstream: upstream,
      tap: tap,
      message:
        "The installed release failed verification: \(error)" + evidenceError + "\n"
        + "Recovery (reinstall only; no rollback is claimed):\n"
        + "  \(Self.recoveryCommand)\n"
        + "  /opt/homebrew/bin/macarchy update"
    )
  }

  private func result(
    _ outcome: HomebrewUpdateOutcome,
    build: MacarchyBuildInformation,
    upstream: String?,
    tap: String?,
    succeeded: Bool,
    message: String
  ) -> HomebrewUpdateExecution {
    var lines = [
      "Macarchy update:",
      "- Installed: \(build.version) (\(build.installation.rawValue))",
    ]
    if let upstream { lines.append("- Upstream stable: \(upstream)") }
    if let tap { lines.append("- Refreshed Homebrew tap: \(tap)") }
    lines.append("- Outcome: \(outcome.rawValue)")
    lines.append(message)
    return HomebrewUpdateExecution(
      outcome: outcome,
      output: lines.joined(separator: "\n"),
      succeeded: succeeded
    )
  }

  private func evidence(
    attemptedAt: Date,
    build: MacarchyBuildInformation,
    targetVersion: String,
    outcome: HomebrewUpgradeEvidence.Outcome,
    error: String? = nil
  ) -> HomebrewUpgradeEvidence {
    HomebrewUpgradeEvidence(
      attemptedAt: attemptedAt,
      installedVersion: build.version,
      targetVersion: targetVersion,
      outcome: outcome,
      error: error.map(boundedUpdateEvidence)
    )
  }

  private func failureEvidenceError(
    stateRoot: URL,
    attemptedAt: Date,
    build: MacarchyBuildInformation,
    targetVersion: String,
    outcome: HomebrewUpgradeEvidence.Outcome,
    error: String
  ) -> String {
    do {
      try writeEvidence(
        stateRoot,
        evidence(
          attemptedAt: attemptedAt,
          build: build,
          targetVersion: targetVersion,
          outcome: outcome,
          error: error
        )
      )
      return ""
    } catch {
      return " Upgrade evidence could not be persisted: \(error)"
    }
  }
}

private func runStreamingProcess(_ request: ProcessRequest) throws -> Int32 {
  let process = Process()
  process.executableURL = request.executableURL
  process.arguments = request.arguments
  process.environment = ProcessInfo.processInfo.environment.merging(
    request.environmentOverrides,
    uniquingKeysWith: { _, override in override }
  )
  process.standardInput = FileHandle.standardInput
  process.standardOutput = FileHandle.standardOutput
  process.standardError = FileHandle.standardError
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus
}

struct HomebrewInstallationVerifier: Sendable {
  static let prefixRequest = ProcessRequest(
    executableURL: HomebrewUpdateRunner.brewURL,
    arguments: ["--prefix", HomebrewUpdateRunner.formula],
    timeout: 10,
    environmentOverrides: [
      "HOMEBREW_NO_ANALYTICS": "1",
      "HOMEBREW_NO_AUTO_UPDATE": "1",
    ]
  )

  let processRunner: ProcessRunner

  static let live = HomebrewInstallationVerifier(processRunner: .live)

  func verify(expectedVersion: String) throws {
    let result = try processRunner.run(Self.prefixRequest)
    guard result.terminationStatus == 0 else {
      throw HomebrewVerificationError(
        reason: result.output.isEmpty
          ? "Homebrew prefix lookup exited with status \(result.terminationStatus)"
          : result.output
      )
    }
    guard result.output.first == "/", !result.output.contains("\n") else {
      throw HomebrewVerificationError(reason: "Homebrew returned an invalid formula prefix")
    }

    let prefix = URL(filePath: result.output, directoryHint: .isDirectory)
    let executable = prefix.appending(path: "bin/macarchy")
    guard isExecutableRegularFile(executable) else {
      throw HomebrewVerificationError(reason: "installed executable is not an executable file")
    }

    let versionResult: ProcessResult
    do {
      versionResult = try processRunner.run(
        ProcessRequest(
          executableURL: executable,
          arguments: ["version", "--json"],
          timeout: 10,
          environmentOverrides: [
            "MACARCHY_DISABLE_UPDATE_CHECKS": "1"
          ]
        )
      )
    } catch {
      throw HomebrewVerificationError(reason: "installed executable could not run: \(error)")
    }
    guard versionResult.terminationStatus == 0 else {
      throw HomebrewVerificationError(
        reason:
          versionResult.output.isEmpty
          ? "installed executable exited with status \(versionResult.terminationStatus)"
          : versionResult.output
      )
    }
    guard versionResult.output.utf8.count <= BoundedRegularFile.maximumSize else {
      throw HomebrewVerificationError(reason: "installed version output exceeded 1 MiB")
    }
    let version: InstalledVersionReport
    do {
      version = try JSONDecoder().decode(
        InstalledVersionReport.self,
        from: Data(versionResult.output.utf8)
      )
    } catch {
      throw HomebrewVerificationError(reason: "installed version output is invalid")
    }
    guard version.schemaVersion == 1,
      version.version == expectedVersion,
      version.installation == InstallationOwnership.homebrew.rawValue,
      version.platform == "macos-arm64"
    else {
      throw HomebrewVerificationError(
        reason: "installed version output does not match \(expectedVersion) on Homebrew arm64"
      )
    }

    let repository = ThemeRepository(
      builtInRoot: prefix.appending(path: "share/macarchy/themes", directoryHint: .isDirectory)
    )
    let packageIDs = try repository.packages().map(\.id)
    guard packageIDs == ["catppuccin-mocha", "kanagawa-wave", "tokyo-night"] else {
      throw HomebrewVerificationError(reason: "installed built-in themes are incomplete")
    }
    for relativePath in [
      "share/macarchy/environment/kitty/defaults.conf",
      "share/macarchy/environment/zsh/defaults.zsh",
      "share/macarchy/environment/starship/behavior.toml",
      "share/macarchy/environment/atuin/config.toml",
      "share/macarchy/environment/bat/config",
      "share/macarchy/environment/eza/defaults.zsh",
      "share/macarchy/environment/btop/btop.conf",
      "share/macarchy/environment/yazi/yazi.toml",
      "share/macarchy/environment/yazi/theme.toml",
      "share/macarchy/environment/yazi/defaults.zsh",
      "share/macarchy/environment/neovim/default/init.lua",
      "share/macarchy/environment/neovim/default/lazy-lock.json",
      "share/macarchy/environment/neovim/default/lazyvim.json",
      "share/macarchy/environment/neovim/default/lua/config/autocmds.lua",
      "share/macarchy/environment/neovim/default/lua/config/keymaps.lua",
      "share/macarchy/environment/neovim/default/lua/config/lazy.lua",
      "share/macarchy/environment/neovim/default/lua/config/options.lua",
      "share/macarchy/environment/neovim/theme/colors/macarchy-imported.lua",
      "share/macarchy/environment/neovim/theme/lua/config/macarchy-theme.lua",
      "share/macarchy/environment/neovim/theme/lua/macarchy/current.lua",
      "share/macarchy/environment/neovim/theme/lua/plugins/colorscheme.lua",
      "share/doc/macarchy/CHANGELOG.md",
      "share/doc/macarchy/LICENSE",
      "share/doc/macarchy/theme-json.md",
    ] {
      do {
        _ = try BoundedRegularFile.read(at: prefix.appending(path: relativePath))
      } catch {
        throw HomebrewVerificationError(
          reason: "installed resource \(relativePath) is invalid: \(error)"
        )
      }
    }
  }
}

private struct InstalledVersionReport: Decodable {
  let schemaVersion: Int
  let version: String
  let platform: String
  let installation: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case version
    case platform
    case installation
  }
}

private func isExecutableRegularFile(_ url: URL) -> Bool {
  var information = stat()
  return url.path.withCString { lstat($0, &information) } == 0
    && information.st_mode & S_IFMT == S_IFREG
    && url.path.withCString { access($0, X_OK) } == 0
}

struct HomebrewVerificationError: Error, CustomStringConvertible {
  let reason: String

  var description: String {
    "Homebrew installation verification failed: \(reason)"
  }
}
