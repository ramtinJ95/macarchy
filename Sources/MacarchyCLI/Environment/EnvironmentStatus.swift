import Foundation
import ThemeCore

struct EnvironmentPrerequisiteStatus: Encodable, Equatable, Sendable {
  let id: String
  let status: String
  let requirement: String
  let remediation: String
}

struct EnvironmentPrerequisiteInspector: Sendable {
  let inspect: @Sendable (EnvironmentProfile, URL) -> [EnvironmentPrerequisiteStatus]
  let inspectSpicetifyRuntime: @Sendable (URL) -> [EnvironmentPrerequisiteStatus]

  init(
    _ inspect: @escaping @Sendable (EnvironmentProfile, URL) -> [EnvironmentPrerequisiteStatus],
    spicetifyRuntime:
      @escaping @Sendable (URL) -> [EnvironmentPrerequisiteStatus] = { _ in [] }
  ) {
    self.inspect = inspect
    inspectSpicetifyRuntime = spicetifyRuntime
  }

  static let assumed = Self { _, _ in [] }

  static let live = Self(
    { profile, homeDirectory in
      var results = DependencyProfile.personal(homeDirectory: homeDirectory)
        .selectedForEnvironment(profile)
        .map {
          EnvironmentPrerequisiteStatus(
            id: $0.id,
            status: $0.isAvailable() ? "present" : "missing",
            requirement: $0.requirement,
            remediation: $0.remediation.instruction
          )
        }
      if profile.presets.pi {
        refine(
          &results, id: PiAdapter.id,
          present: { "Pi \($0) satisfies the required version >= \(PiAdapter.minimumVersion)" },
          missing: {
            "Pi must report a parseable version >= \(PiAdapter.minimumVersion): \($0)"
          },
          version: {
            try PiAdapter.supportedVersion(
              executableURL: PiAdapter.liveExecutableURL, processRunner: .live)
          }
        )
      }
      if profile.presets.codex {
        refine(
          &results, id: CodexAdapter.id,
          present: {
            "Codex \($0) satisfies the required version >= \(CodexAdapter.minimumVersion)"
          },
          missing: {
            "Codex must report 'codex-cli X.Y.Z' >= \(CodexAdapter.minimumVersion): \($0)"
          },
          version: {
            try CodexAdapter.supportedVersion(
              executableURL: CodexAdapter.liveExecutableURL, processRunner: .live)
          }
        )
      }
      if profile.presets.herdr {
        if ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"] != nil {
          if let index = results.firstIndex(where: { $0.id == HerdrAdapter.id }),
            results[index].status == "present"
          {
            results[index] = EnvironmentPrerequisiteStatus(
              id: HerdrAdapter.id,
              status: "missing",
              requirement:
                "Herdr must use canonical ~/.config/herdr/config.toml; HERDR_CONFIG_PATH is unsupported and uninspectable",
              remediation: "Unset HERDR_CONFIG_PATH and run the command again."
            )
          }
        } else {
          refine(
            &results, id: HerdrAdapter.id,
            present: {
              "Herdr \($0) satisfies the required version >= \(HerdrAdapter.minimumVersion)"
            },
            missing: {
              "Herdr must report 'herdr X.Y.Z' >= \(HerdrAdapter.minimumVersion): \($0)"
            },
            version: {
              try HerdrAdapter.supportedVersion(
                executableURL: HerdrAdapter.executableURL(homeDirectory: homeDirectory),
                processRunner: .live)
            }
          )
        }
      }
      if profile.presets.spicetify {
        results = validateSpicetifyRuntime(results)
        results += spicetifyPreparation(homeDirectory: homeDirectory)
      }
      if profile.presets.slack {
        refine(
          &results, id: SlackAdapter.id,
          present: {
            "Slack \($0) satisfies the required version >= \(SlackAdapter.minimumVersion)"
          },
          missing: {
            "Slack must have bundle version >= \(SlackAdapter.minimumVersion): \($0)"
          },
          version: { try EnvironmentSlackPreset().supportedVersion() }
        )
      }
      if profile.shell == .zsh {
        let zsh = URL(filePath: "/bin/zsh")
        results.append(
          EnvironmentPrerequisiteStatus(
            id: "zsh",
            status: FileManager.default.isExecutableFile(atPath: zsh.path) ? "present" : "missing",
            requirement: "/bin/zsh must be executable",
            remediation: "Run Macarchy on a supported macOS installation."
          )
        )
      }
      if profile.editor == .neovim {
        let git = URL(filePath: "/usr/bin/git")
        results.append(
          EnvironmentPrerequisiteStatus(
            id: "git",
            status: FileManager.default.isExecutableFile(atPath: git.path) ? "present" : "missing",
            requirement: "/usr/bin/git must be executable for pinned Neovim plugins",
            remediation: "Install the supported macOS Command Line Tools."
          )
        )
      }
      return results.sorted { $0.id < $1.id }
    },
    spicetifyRuntime: { homeDirectory in
      let selected = Set([SpicetifyAdapter.id, "spotify"])
      let results = DependencyProfile.personal(homeDirectory: homeDirectory).capabilities
        .filter { selected.contains($0.id) }
        .map {
          EnvironmentPrerequisiteStatus(
            id: $0.id,
            status: $0.isAvailable() ? "present" : "missing",
            requirement: $0.requirement,
            remediation: $0.remediation.instruction
          )
        }
      return
        (validateSpicetifyRuntime(results)
        + spicetifyPreparation(homeDirectory: homeDirectory)).sorted { $0.id < $1.id }
    })

  private static func validateSpicetifyRuntime(
    _ statuses: [EnvironmentPrerequisiteStatus]
  ) -> [EnvironmentPrerequisiteStatus] {
    var results = statuses
    refine(
      &results, id: SpicetifyAdapter.id,
      present: {
        "Spicetify \($0) satisfies the required version >= \(SpicetifyAdapter.minimumVersion)"
      },
      missing: {
        "Spicetify must report a parseable X.Y.Z >= \(SpicetifyAdapter.minimumVersion): \($0)"
      },
      version: { try SpicetifyAdapter.supportedCommandVersion() }
    )
    refine(
      &results, id: "spotify",
      present: { "Spotify has parseable bundle version \($0)" },
      missing: { "Spotify must have a parseable bundle version: \($0)" },
      version: { try SpicetifyAdapter.spotifyBundleVersion() }
    )
    return results
  }

  /// Replaces a present prerequisite's status with the outcome of its version probe.
  private static func refine<Version>(
    _ results: inout [EnvironmentPrerequisiteStatus],
    id: String,
    present: (Version) -> String,
    missing: (any Error) -> String,
    version: () throws -> Version
  ) {
    guard let index = results.firstIndex(where: { $0.id == id }),
      results[index].status == "present"
    else { return }
    let requirement: String
    let status: String
    do {
      requirement = present(try version())
      status = "present"
    } catch {
      requirement = missing(error)
      status = "missing"
    }
    results[index] = EnvironmentPrerequisiteStatus(
      id: id, status: status, requirement: requirement, remediation: results[index].remediation)
  }

  static func spicetifyPreparation(homeDirectory: URL) -> [EnvironmentPrerequisiteStatus] {
    do {
      try SpicetifyAdapter.requireRefreshPreparation(
        configurationDirectoryURL: homeDirectory.appending(
          path: ConsumerHomePath.spicetifyDirectory))
      return [
        EnvironmentPrerequisiteStatus(
          id: "spicetify_preparation", status: "present",
          requirement: "Spotify has the unpacked writable xpui required by no-restart refresh.",
          remediation: "Runtime refresh must still succeed; this inspection makes no writes.")
      ]
    } catch {
      return [
        EnvironmentPrerequisiteStatus(
          id: "spicetify_preparation", status: "missing",
          requirement: String(describing: error),
          remediation:
            "Initialize or repair Spicetify manually, or set presets.spicetify = false. Macarchy never runs backup, apply, or restore."
        )
      ]
    }
  }
}

extension EnvironmentProfile {
  var isEntirelyDisabled: Bool {
    terminal == .disabled && shell == .disabled && prompt == .disabled && history == .disabled
      && focusRing == .disabled && scripts.run.isEmpty && !macOSLook.accent && !macOSLook.iconStyle
      && editor == .disabled
      && !EnvironmentDailyTool.allCases.contains { $0.isEnabled(in: tools) }
      && !EnvironmentPreset.allCases.contains { $0.isEnabled(in: presets) }
  }

  var selectedThemeAdapterIDs: [String] {
    var ids: [String] = []
    if terminal == .kitty { ids.append("kitty") }
    if focusRing == .borders { ids.append(BordersAdapter.id) }
    if focusRing == .lean { ids.append(BordersAdapter.leanID) }
    if !scripts.run.isEmpty { ids.append(UserScriptsAdapter.id) }
    if macOSLook.iconStyle { ids.append(MacOSIconStyleAdapter.id) }
    if macOSLook.accent { ids.append(MacOSAccentAdapter.id) }
    if prompt == .starship { ids.append("starship") }
    if history == .atuin { ids.append("atuin") }
    if editor == .neovim { ids.append("neovim") }
    // Tool adapters stay alphabetical, ahead of the presets' adapters.
    let toolIDs: [String] = EnvironmentDailyTool.allCases
      .filter { $0.isEnabled(in: tools) }
      .map(\.adapterID)
    ids += toolIDs.sorted()
    ids += EnvironmentPreset.allCases.compactMap { $0.isEnabled(in: presets) ? $0.adapterID : nil }
    return ids
  }
}

extension ThemeConsumerPaths {
  func managedEnvironmentPaths(
    stateRoot: URL, homeDirectory: URL, ownership: EnvironmentOwnership? = nil
  ) -> ThemeConsumerPaths {
    var paths = self
    paths.kittyConfigurationURL = homeDirectory.appending(path: ConsumerHomePath.kittyConfiguration)
    paths.shellConfigurationURL = homeDirectory.appending(path: ConsumerHomePath.shellConfiguration)
    paths.ezaConfigurationDirectoryURL = homeDirectory.appending(
      path: ConsumerHomePath.ezaDirectory)
    paths.batConfigurationDirectoryURL = homeDirectory.appending(
      path: ConsumerHomePath.batDirectory)
    paths.btopConfigurationDirectoryURL = homeDirectory.appending(
      path: ConsumerHomePath.btopDirectory)
    paths.yaziConfigurationDirectoryURL = homeDirectory.appending(
      path: ConsumerHomePath.yaziDirectory)
    paths.atuinConfigurationDirectoryURL = homeDirectory.appending(
      path: ConsumerHomePath.atuinDirectory, directoryHint: .isDirectory)
    paths.neovimConfigurationDirectoryURL = homeDirectory.appending(
      path: ConsumerHomePath.neovimDirectory)
    paths.starshipConfigurationURL = homeDirectory.appending(
      path: ConsumerHomePath.starshipConfiguration)
    paths.starshipBehaviorURL = EnvironmentNativeFileMigration.starshipBehaviorURL(
      homeDirectory: homeDirectory, stateRoot: stateRoot, ownership: ownership)
    return paths
  }
}

struct EnvironmentVerification: Encodable, Equatable, Sendable {
  let id: String
  let status: String
  let message: String
}

struct EnvironmentSessionVerifier: Sendable {
  let verify: @Sendable (EnvironmentProfile, URL) -> [EnvironmentVerification]
  let verifyRestored: @Sendable (EnvironmentProfile, URL) -> [EnvironmentVerification]

  init(
    _ verify: @escaping @Sendable (EnvironmentProfile, URL) -> [EnvironmentVerification],
    verifyRestored: (@Sendable (EnvironmentProfile, URL) -> [EnvironmentVerification])? = nil
  ) {
    self.verify = verify
    self.verifyRestored = verifyRestored ?? verify
  }

  static let assumed = Self { profile, _ in
    profile.shell == .zsh
      ? [
        EnvironmentVerification(
          id: "zsh_fresh_session",
          status: "verified",
          message: "Fresh zsh session verification was supplied by the caller."
        )
      ] : []
  }

  static let live = Self(
    { profile, homeDirectory in
      verifyFreshSession(
        profile, homeDirectory,
        requireManagedMarker: profile.zsh.configurationURL
          != homeDirectory.appending(path: ConsumerHomePath.shellConfiguration))
    },
    verifyRestored: { profile, homeDirectory in
      verifyFreshSession(profile, homeDirectory, requireManagedMarker: false)
    }
  )

  static func verifyFreshSession(
    _ profile: EnvironmentProfile,
    _ homeDirectory: URL,
    requireManagedMarker: Bool,
    processRunner: ProcessRunner = .live
  ) -> [EnvironmentVerification] {
    guard profile.shell == .zsh else { return [] }
    do {
      let command =
        requireManagedMarker
        ? "startup_status=$?; test $startup_status -eq 0 && test \"$MACARCHY_MANAGED_SESSION\" = 1"
        : "startup_status=$?; test $startup_status -eq 0"
      let result = try processRunner.run(
        ProcessRequest(
          executableURL: URL(filePath: "/bin/zsh"),
          // Foundation launches a separate process group. An interactive zsh
          // with MONITOR enabled stops itself trying to acquire the caller's
          // terminal. Verify login/interactive startup, not terminal ownership.
          arguments: ["-l", "-i", "+m", "-c", command],
          timeout: 5,
          environmentOverrides: [
            "HOME": homeDirectory.path,
            "MACARCHY_MANAGED_SESSION": "0",
            "ZDOTDIR": homeDirectory.path,
            // Do not let the invoking terminal supply missing managed startup paths.
            "PATH": requireManagedMarker
              ? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
              : ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
          ]
        )
      )
      return [
        EnvironmentVerification(
          id: "zsh_fresh_session",
          status: result.terminationStatus == 0 ? "verified" : "failed",
          message: result.terminationStatus == 0
            ? (requireManagedMarker
              ? "A fresh login shell loaded the managed entry point. User configuration and trusted hook semantics remain unverifiable."
              : "A fresh login shell completed native startup. Personal behavior and private runtime includes are not verified.")
            : (result.output.isEmpty
              ? "The fresh login shell rejected the managed session." : result.output)
        )
      ]
    } catch {
      return [
        EnvironmentVerification(
          id: "zsh_fresh_session",
          status: "failed",
          message: String(describing: error)
        )
      ]
    }
  }
}

struct EnvironmentLifecycleReport: CommandReport, Sendable {
  let schemaVersion = 1
  let operation: String
  let outcome: String
  let mutated: Bool
  let profile: String?
  let providers: [String: String]
  let generation: EnvironmentGenerationReport
  let transactionStatus: String
  let adoptionEvidenceDigest: String?
  let prerequisites: [EnvironmentPrerequisiteStatus]
  let entries: [EnvironmentEntryInspection]
  let theme: [DesktopThemeAdapterStatus]
  let verification: [EnvironmentVerification]
  let message: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, mutated, profile, providers, generation
    case transactionStatus = "transaction_status"
    case adoptionEvidenceDigest = "adoption_evidence_digest"
    case prerequisites, entries, theme, verification, message
  }

  var succeeded: Bool {
    ["converged", "applied", "no_change", "ready", "restored", "absent"].contains(outcome)
  }

  func execution(json: Bool) throws -> CommandExecution {
    (try render(json: json), succeeded)
  }

  func renderText() throws -> String {
    var lines = [
      "Macarchy \(operation.replacingOccurrences(of: "_", with: " ")) [\(outcome)]:",
      "- \(message)",
      "- generation: \(generation.status)"
        + (generation.generationID.map { " (\($0))" } ?? ""),
      "- transaction: \(transactionStatus)",
    ]
    if let adoptionEvidenceDigest {
      lines.append("- adoption evidence: \(adoptionEvidenceDigest)")
    }
    for prerequisite in prerequisites {
      lines.append(
        "- prerequisite \(prerequisite.id): \(prerequisite.status) — \(prerequisite.requirement)"
      )
    }
    for entry in entries {
      lines.append("- \(entry.id) [\(entry.status.rawValue)]: \(entry.path) — \(entry.message)")
    }
    for adapter in theme {
      lines.append(
        "- theme \(adapter.adapterID) [\(adapter.status)]"
          + (adapter.message.map { ": \($0)" } ?? "")
      )
    }
    for check in verification {
      lines.append("- \(check.id) [\(check.status)]: \(check.message)")
    }
    return lines.joined(separator: "\n")
  }
}

struct EnvironmentGenerationReport: Encodable, Sendable {
  let status: String
  let generationID: String?
  let inputDigest: String?
  let renderedDigest: String?
  let message: String

  enum CodingKeys: String, CodingKey {
    case status, message
    case generationID = "generation_id"
    case inputDigest = "input_digest"
    case renderedDigest = "rendered_digest"
  }

  init(_ inspection: EnvironmentGenerationInspection) {
    status = inspection.status.rawValue
    generationID = inspection.generationID
    inputDigest = inspection.inputDigest
    renderedDigest = inspection.renderedDigest
    message = inspection.message
  }

  init(status: String, message: String) {
    self.status = status
    generationID = nil
    inputDigest = nil
    renderedDigest = nil
    self.message = message
  }
}

/// What an apply already observed, and how its converged result is reported.
struct EnvironmentApplyObservation: Sendable {
  var theme: [DesktopThemeAdapterStatus]? = nil
  var verification: [EnvironmentVerification]? = nil
  let outcome: String
  let mutated: Bool
  let message: String
  var pendingCommit = false
}

struct EnvironmentStatusCommandRunner: Sendable {
  let prerequisites: EnvironmentPrerequisiteInspector
  let theme: DesktopThemeController?
  let verifier: EnvironmentSessionVerifier
  let bordersRuntime: EnvironmentBordersRuntime
  let alacrittyVersion: @Sendable () throws -> [Int]
  let ghosttyVersion: @Sendable () throws -> [Int]
  let vscodeDiscover: @Sendable (VSCodeEditor) throws -> VSCodeEditor.Installation
  let vscodeRunner: ProcessRunner
  let zedVersion: @Sendable () throws -> [Int]

  static let live = Self(prerequisites: .live, theme: .live, verifier: .live)

  init(
    prerequisites: EnvironmentPrerequisiteInspector,
    theme: DesktopThemeController?,
    verifier: EnvironmentSessionVerifier = .assumed,
    bordersRuntime: EnvironmentBordersRuntime = .live,
    alacrittyVersion: @escaping @Sendable () throws -> [Int] = AlacrittyAdapter.installedVersion,
    ghosttyVersion: @escaping @Sendable () throws -> [Int] = GhosttyAdapter.installedVersion,
    vscodeDiscover: @escaping @Sendable (VSCodeEditor) throws -> VSCodeEditor.Installation = {
      try $0.discover()
    },
    vscodeRunner: ProcessRunner = .live,
    zedVersion: @escaping @Sendable () throws -> [Int] = ZedAdapter.installedVersion
  ) {
    self.prerequisites = prerequisites
    self.theme = theme
    self.verifier = verifier
    self.bordersRuntime = bordersRuntime
    self.alacrittyVersion = alacrittyVersion
    self.ghosttyVersion = ghosttyVersion
    self.vscodeDiscover = vscodeDiscover
    self.vscodeRunner = vscodeRunner
    self.zedVersion = zedVersion
  }

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    json: Bool,
    profile: PortableProfile? = nil
  ) throws -> CommandExecution {
    try statusReport(
      resourcesRoot: resourcesRoot, profileURL: profileURL, profileRequired: profileRequired,
      stateRoot: stateRoot, homeDirectory: homeDirectory, consumerPaths: consumerPaths,
      profile: profile
    ).execution(json: json)
  }

  func statusReport(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    profile: PortableProfile? = nil
  ) -> EnvironmentLifecycleReport {
    run(
      operation: "environment_status", resourcesRoot: resourcesRoot, profileURL: profileURL,
      profileRequired: profileRequired, stateRoot: stateRoot, homeDirectory: homeDirectory,
      consumerPaths: consumerPaths, includeVerification: false, applied: nil, profile: profile)
  }

  /// Status plus session verification.
  func executeDoctor(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    json: Bool,
    profile: PortableProfile? = nil
  ) throws -> CommandExecution {
    try doctorReport(
      resourcesRoot: resourcesRoot, profileURL: profileURL, profileRequired: profileRequired,
      stateRoot: stateRoot, homeDirectory: homeDirectory, consumerPaths: consumerPaths,
      profile: profile
    ).execution(json: json)
  }

  /// Status plus session verification.
  func doctorReport(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    profile: PortableProfile? = nil
  ) -> EnvironmentLifecycleReport {
    run(
      operation: "environment_doctor", resourcesRoot: resourcesRoot, profileURL: profileURL,
      profileRequired: profileRequired, stateRoot: stateRoot, homeDirectory: homeDirectory,
      consumerPaths: consumerPaths, includeVerification: true, applied: nil, profile: profile)
  }

  /// Reports apply's result through the status path, reusing what apply already observed.
  func reportAfterApply(
    _ applied: EnvironmentApplyObservation,
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    profile: PortableProfile
  ) -> EnvironmentLifecycleReport {
    run(
      operation: "environment_apply", resourcesRoot: resourcesRoot, profileURL: profileURL,
      profileRequired: profileRequired, stateRoot: stateRoot, homeDirectory: homeDirectory,
      consumerPaths: consumerPaths, includeVerification: true, applied: applied,
      profile: profile)
  }

  private func run(
    operation: String,
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    includeVerification: Bool,
    applied: EnvironmentApplyObservation?,
    profile suppliedProfile: PortableProfile?
  ) -> EnvironmentLifecycleReport {
    let profile: PortableProfile
    let composition: EnvironmentComposition
    do {
      profile =
        try suppliedProfile
        ?? PortableProfileLoader().load(at: profileURL, required: profileRequired)
      composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot,
        profile: profile,
        stateRoot: stateRoot
      )
    } catch {
      return failure(
        operation: operation, profile: profileURL, message: String(describing: error))
    }

    let generation = EnvironmentGenerationStore(stateRoot: stateRoot).inspect(expected: composition)
    let provider = EnvironmentProviderInspector(
      alacrittyVersion: alacrittyVersion, ghosttyVersion: ghosttyVersion,
      vscodeDiscover: vscodeDiscover, vscodeRunner: vscodeRunner,
      zedVersion: zedVersion
    )
    .inspectIncludingBordersRuntime(
      composition: composition,
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      runtime: bordersRuntime
    )
    let prerequisiteState = prerequisites.inspect(profile.environment, homeDirectory)
    let transactionStatus: String
    do {
      if try EnvironmentStateStore(stateRoot: stateRoot).readTransaction() == nil {
        transactionStatus = "clear"
      } else {
        transactionStatus = applied?.pendingCommit == true ? "pending_commit" : "recovery_required"
      }
    } catch {
      transactionStatus = "invalid"
    }

    var themeState = applied?.theme ?? []
    var themeFailure: String?
    if applied?.theme == nil,
      !profile.environment.selectedThemeAdapterIDs.isEmpty,
      generation.status == .current,
      !provider.isBlocked,
      let theme
    {
      do {
        themeState = try theme.inspect(
          profile.environment.selectedThemeAdapterIDs,
          stateRoot,
          consumerPaths.managedEnvironmentPaths(
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            ownership: provider.ownership
          )
        )
      } catch {
        themeFailure = String(describing: error)
      }
    }
    var verification =
      applied?.verification
      ?? (includeVerification && !provider.isBlocked
        ? verifier.verify(profile.environment, homeDirectory) : [])
    do {
      if try EnvironmentStateStore(stateRoot: stateRoot).hasUnverifiedSpicetifyRecovery() {
        verification.append(
          EnvironmentVerification(
            id: "spicetify_runtime_restoration",
            status: profile.environment.presets.spicetify ? "unverified" : "manual_required",
            message: EnvironmentStateStore.spicetifyRecoveryMessage))
      }
    } catch {
      return failure(
        operation: operation, profile: profileURL, message: String(describing: error))
    }
    let missing = prerequisiteState.contains { $0.status == "missing" }
    let providerReady =
      !provider.isBlocked
      && provider.entries.allSatisfy { [.managed, .external].contains($0.status) }
    let generationReady =
      profile.environment.isEntirelyDisabled
      ? generation.status == .absent
      : generation.status == .current
    let themeReady =
      themeFailure == nil
      && themeState.allSatisfy(isAcceptedEnvironmentThemeStatus)
    let verificationReady = verification.allSatisfy {
      $0.status == "verified" || $0.status == "manual_required"
    }
    let converged =
      !missing && providerReady && generationReady && themeReady
      && verificationReady
      && (transactionStatus == "clear" || transactionStatus == "pending_commit")
    let outcome =
      converged
      ? (applied?.outcome ?? "converged")
      : transactionStatus == "clear" ? "drifted" : "blocked"
    return EnvironmentLifecycleReport(
      operation: operation,
      outcome: outcome,
      mutated: applied?.mutated ?? false,
      profile: profileURL.path,
      providers: Self.providers(profile.environment),
      generation: EnvironmentGenerationReport(generation),
      transactionStatus: transactionStatus,
      adoptionEvidenceDigest: provider.adoptionEvidenceDigest,
      prerequisites: prerequisiteState,
      entries: provider.entries,
      theme: themeState,
      verification: verification,
      message: themeFailure ?? provider.blockedMessage
        ?? (converged
          ? (applied?.message ?? "The managed daily tool environment is converged.")
          : "The managed daily tool environment requires attention.")
    )
  }

  static func providers(_ profile: EnvironmentProfile) -> [String: String] {
    var providers = profile.roleProviders
    for (id, selection) in profile.dailyToolPresentation { providers[id] = selection }
    for (id, selection) in profile.presetPresentation { providers[id] = selection }
    return providers
  }

  private func failure(operation: String, profile: URL, message: String)
    -> EnvironmentLifecycleReport
  {
    EnvironmentLifecycleReport(
      operation: operation,
      outcome: "blocked",
      mutated: false,
      profile: profile.path,
      providers: [:],
      generation: EnvironmentGenerationReport(status: "unavailable", message: message),
      transactionStatus: "unknown",
      adoptionEvidenceDigest: nil,
      prerequisites: [],
      entries: [],
      theme: [],
      verification: [],
      message: message
    )
  }
}

extension EnvironmentProfile {
  /// The provider selected for each environment role, keyed by the role's report name.
  var roleProviders: [String: String] {
    [
      "focus_ring": focusRing.rawValue,
      "terminal": terminal.rawValue,
      "shell": shell.rawValue,
      "prompt": prompt.rawValue,
      "history": history.rawValue,
      "editor": editor.rawValue,
    ]
  }
}
