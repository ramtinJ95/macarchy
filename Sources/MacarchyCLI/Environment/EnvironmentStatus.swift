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

  static let assumed = Self { _, _ in [] }

  static let live = Self { profile, homeDirectory in
    guard !profile.isEntirelyDisabled else { return [] }
    let selected = Set(
      ["macos-26", "arm64"]
        + (profile.terminal == .kitty ? ["kitty"] : [])
        + (profile.prompt == .starship ? ["starship"] : [])
        + (profile.history == .atuin ? ["atuin"] : [])
        + (profile.editor == .neovim ? ["neovim"] : [])
        + (profile.presets.codex ? ["codex"] : [])
        + (profile.presets.herdr ? ["herdr"] : [])
        + (profile.presets.pi ? ["pi"] : [])
        + (profile.presets.tuicr ? ["tuicr"] : [])
        + (profile.tools.bat ? ["bat"] : [])
        + (profile.tools.eza ? ["eza"] : [])
        + (profile.tools.btop ? ["btop"] : [])
        + (profile.tools.yazi ? ["yazi"] : [])
    )
    var results = DependencyProfile.personal(homeDirectory: homeDirectory).capabilities
      .filter { selected.contains($0.id) }
      .map {
        EnvironmentPrerequisiteStatus(
          id: $0.id,
          status: $0.isAvailable() ? "present" : "missing",
          requirement: $0.requirement,
          remediation: remediation($0.remediation)
        )
      }
    if profile.presets.pi,
      let index = results.firstIndex(where: { $0.id == PiAdapter.id }),
      results[index].status == "present"
    {
      let executable = PiAdapter.liveExecutableURL
      do {
        let version = try PiAdapter(
          root: homeDirectory.appending(path: ".config/macarchy"),
          configurationDirectoryURL: homeDirectory.appending(path: ".pi/agent"),
          executableURL: executable,
          controlIsAvailable: { true },
          processRunner: .live
        ).supportedVersion()
        results[index] = EnvironmentPrerequisiteStatus(
          id: PiAdapter.id,
          status: "present",
          requirement:
            "Pi \(version) satisfies the required version >= \(PiAdapter.minimumVersion)",
          remediation: results[index].remediation
        )
      } catch {
        results[index] = EnvironmentPrerequisiteStatus(
          id: PiAdapter.id,
          status: "missing",
          requirement:
            "Pi must report a parseable version >= \(PiAdapter.minimumVersion): \(error)",
          remediation: results[index].remediation
        )
      }
    }
    if profile.presets.codex,
      let index = results.firstIndex(where: { $0.id == CodexAdapter.id }),
      results[index].status == "present"
    {
      let executable = CodexAdapter.liveExecutableURL
      do {
        let version = try CodexAdapter(
          root: homeDirectory.appending(path: ".config/macarchy"),
          configurationDirectoryURL: homeDirectory.appending(path: ".codex"),
          executableURL: executable,
          controlIsAvailable: { true },
          processRunner: .live
        ).supportedVersion()
        results[index] = EnvironmentPrerequisiteStatus(
          id: CodexAdapter.id,
          status: "present",
          requirement:
            "Codex \(version) satisfies the required version >= \(CodexAdapter.minimumVersion)",
          remediation: results[index].remediation
        )
      } catch {
        results[index] = EnvironmentPrerequisiteStatus(
          id: CodexAdapter.id,
          status: "missing",
          requirement:
            "Codex must report 'codex-cli X.Y.Z' >= \(CodexAdapter.minimumVersion): \(error)",
          remediation: results[index].remediation
        )
      }
    }
    if profile.presets.herdr,
      let index = results.firstIndex(where: { $0.id == HerdrAdapter.id }),
      results[index].status == "present"
    {
      if ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"] != nil {
        results[index] = EnvironmentPrerequisiteStatus(
          id: HerdrAdapter.id,
          status: "missing",
          requirement:
            "Herdr must use canonical ~/.config/herdr/config.toml; HERDR_CONFIG_PATH is unsupported and uninspectable",
          remediation: "Unset HERDR_CONFIG_PATH and run the command again."
        )
      } else {
        do {
          let version = try HerdrAdapter(
            root: homeDirectory.appending(path: ".config/macarchy"),
            configurationURL: homeDirectory.appending(path: ".config/herdr/config.toml"),
            executableURL: HerdrAdapter.executableURL(homeDirectory: homeDirectory),
            controlIsAvailable: { true },
            processRunner: .live
          ).supportedVersion()
          results[index] = EnvironmentPrerequisiteStatus(
            id: HerdrAdapter.id,
            status: "present",
            requirement:
              "Herdr \(version) satisfies the required version >= \(HerdrAdapter.minimumVersion)",
            remediation: results[index].remediation
          )
        } catch {
          results[index] = EnvironmentPrerequisiteStatus(
            id: HerdrAdapter.id,
            status: "missing",
            requirement:
              "Herdr must report 'herdr X.Y.Z' >= \(HerdrAdapter.minimumVersion): \(error)",
            remediation: results[index].remediation
          )
        }
      }
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
  }

  private static func remediation(_ remediation: DependencyRemediation) -> String {
    switch remediation {
    case .cask(let package):
      "Install Homebrew cask \(package)."
    case .formula(let package):
      "Install Homebrew formula \(package)."
    case .external(let instruction):
      instruction
    }
  }
}

extension EnvironmentProfile {
  var isEntirelyDisabled: Bool {
    terminal == .disabled && shell == .disabled && prompt == .disabled && history == .disabled
      && editor == .disabled
      && !tools.bat && !tools.eza && !tools.btop && !tools.yazi
      && !presets.codex && !presets.pi && !presets.tuicr
      && !presets.herdr
  }

  var selectedThemeAdapterIDs: [String] {
    (terminal == .kitty ? ["kitty"] : [])
      + (prompt == .starship ? ["starship"] : [])
      + (history == .atuin ? ["atuin"] : [])
      + (editor == .neovim ? ["neovim"] : [])
      + (tools.bat ? ["bat"] : [])
      + (tools.btop ? ["btop"] : [])
      + (tools.eza ? ["eza"] : [])
      + (tools.yazi ? ["yazi"] : [])
      + (presets.codex ? ["codex"] : [])
      + (presets.herdr ? ["herdr"] : [])
      + (presets.pi ? ["pi"] : [])
      + (presets.tuicr ? ["tuicr"] : [])
  }
}

extension ThemeConsumerPaths {
  func managedEnvironmentPaths(stateRoot: URL, homeDirectory: URL) -> ThemeConsumerPaths {
    ThemeConsumerPaths(
      kittyConfigurationURL: homeDirectory.appending(path: ".config/kitty/kitty.conf"),
      sketchyBarConfigurationURL: sketchyBarConfigurationURL,
      shellConfigurationURL: homeDirectory.appending(path: ".zshrc").resolvingSymlinksInPath(),
      ezaConfigurationDirectoryURL: homeDirectory.appending(path: ".config/eza"),
      batConfigurationDirectoryURL: homeDirectory.appending(path: ".config/bat"),
      batCacheDirectoryURL: batCacheDirectoryURL,
      btopConfigurationDirectoryURL: homeDirectory.appending(path: ".config/btop"),
      yaziConfigurationDirectoryURL: homeDirectory.appending(path: ".config/yazi"),
      atuinConfigurationDirectoryURL: homeDirectory.appending(
        path: ".config/atuin",
        directoryHint: .isDirectory
      ),
      neovimConfigurationDirectoryURL: homeDirectory.appending(path: ".config/nvim"),
      starshipConfigurationURL: homeDirectory.appending(path: ".config/starship.toml"),
      starshipBehaviorURL: stateRoot.appending(
        path: "environment/current/starship/behavior.toml"
      ),
      piConfigurationDirectoryURL: piConfigurationDirectoryURL,
      herdrConfigurationURL: herdrConfigurationURL,
      tuicrConfigurationDirectoryURL: tuicrConfigurationDirectoryURL,
      codexConfigurationDirectoryURL: codexConfigurationDirectoryURL,
      spicetifyConfigurationDirectoryURL: spicetifyConfigurationDirectoryURL
    )
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
      verifyFreshSession(profile, homeDirectory, requireManagedMarker: true)
    },
    verifyRestored: { profile, homeDirectory in
      verifyFreshSession(profile, homeDirectory, requireManagedMarker: false)
    }
  )

  private static func verifyFreshSession(
    _ profile: EnvironmentProfile,
    _ homeDirectory: URL,
    requireManagedMarker: Bool
  ) -> [EnvironmentVerification] {
    guard profile.shell == .zsh else { return [] }
    do {
      let command =
        requireManagedMarker
        ? "startup_status=$?; test $startup_status -eq 0 && test \"$MACARCHY_MANAGED_SESSION\" = 1"
        : "startup_status=$?; test $startup_status -eq 0"
      let result = try ProcessRunner.live.run(
        ProcessRequest(
          executableURL: URL(filePath: "/bin/zsh"),
          arguments: ["-lic", command],
          timeout: 5,
          environmentOverrides: [
            "HOME": homeDirectory.path,
            "MACARCHY_MANAGED_SESSION": "0",
            "ZDOTDIR": homeDirectory.path,
          ]
        )
      )
      return [
        EnvironmentVerification(
          id: "zsh_fresh_session",
          status: result.terminationStatus == 0 ? "verified" : "failed",
          message: result.terminationStatus == 0
            ? "A fresh login shell loaded the managed session. Trusted hook semantics remain unverifiable."
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

struct EnvironmentLifecycleReport: Encodable {
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

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
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
      lines.append("- \(entry.id) [\(entry.status)]: \(entry.path) — \(entry.message)")
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

struct EnvironmentGenerationReport: Encodable {
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

struct EnvironmentStatusCommandRunner: Sendable {
  let prerequisites: EnvironmentPrerequisiteInspector
  let theme: DesktopThemeController?
  let verifier: EnvironmentSessionVerifier

  static let live = Self(prerequisites: .live, theme: .live, verifier: .live)

  init(
    prerequisites: EnvironmentPrerequisiteInspector,
    theme: DesktopThemeController?,
    verifier: EnvironmentSessionVerifier = .assumed
  ) {
    self.prerequisites = prerequisites
    self.theme = theme
    self.verifier = verifier
  }

  func execute(
    operation: String = "environment_status",
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    includeVerification: Bool = false,
    observedTheme: [DesktopThemeAdapterStatus]? = nil,
    observedVerification: [EnvironmentVerification]? = nil,
    successfulOutcome: String? = nil,
    mutated: Bool = false,
    successMessage: String? = nil,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let profile: PortableProfile
    let composition: EnvironmentComposition
    do {
      profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
      composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot,
        profile: profile,
        stateRoot: stateRoot
      )
    } catch {
      let report = failure(
        operation: operation, profile: profileURL, message: String(describing: error))
      return (try report.render(json: json), false)
    }

    let generation = EnvironmentGenerationStore(stateRoot: stateRoot).inspect(expected: composition)
    let provider = EnvironmentProviderInspector().inspect(
      composition: composition,
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    let prerequisiteState = prerequisites.inspect(profile.environment, homeDirectory)
    let transactionStatus: String
    do {
      transactionStatus =
        try EnvironmentStateStore(stateRoot: stateRoot).readTransaction() == nil
        ? "clear" : "recovery_required"
    } catch {
      transactionStatus = "invalid"
    }

    var themeState = observedTheme ?? []
    var themeFailure: String?
    if observedTheme == nil,
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
            homeDirectory: homeDirectory
          )
        )
      } catch {
        themeFailure = String(describing: error)
      }
    }
    let verification =
      observedVerification
      ?? (includeVerification && !provider.isBlocked
        ? verifier.verify(profile.environment, homeDirectory) : [])
    let missing = prerequisiteState.contains { $0.status == "missing" }
    let providerReady =
      !provider.isBlocked
      && provider.entries.allSatisfy { ["managed", "external"].contains($0.status) }
    let generationReady =
      profile.environment.isEntirelyDisabled
      ? generation.status == .absent
      : generation.status == .current
    let themeReady =
      themeFailure == nil
      && themeState.allSatisfy {
        $0.status == "ready" || $0.status == "applied" || $0.status == "restart_required"
      }
    let verificationReady = verification.allSatisfy { $0.status == "verified" }
    let converged =
      !missing && providerReady && generationReady && themeReady
      && verificationReady && transactionStatus == "clear"
    let outcome =
      converged
      ? (successfulOutcome ?? "converged")
      : transactionStatus == "clear" ? "drifted" : "blocked"
    let report = EnvironmentLifecycleReport(
      operation: operation,
      outcome: outcome,
      mutated: mutated,
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
          ? (successMessage ?? "The managed daily tool environment is converged.")
          : "The managed daily tool environment requires attention.")
    )
    return (try report.render(json: json), report.succeeded)
  }

  static func providers(_ profile: EnvironmentProfile) -> [String: String] {
    [
      "terminal": profile.terminal.rawValue,
      "shell": profile.shell.rawValue,
      "prompt": profile.prompt.rawValue,
      "history": profile.history.rawValue,
      "editor": profile.editor.rawValue,
      "bat": profile.tools.bat ? "enabled" : "disabled",
      "btop": profile.tools.btop ? "enabled" : "disabled",
      "eza": profile.tools.eza ? "enabled" : "disabled",
      "yazi": profile.tools.yazi ? "enabled" : "disabled",
      "codex": profile.presets.codex ? "enabled" : "disabled",
      "herdr": profile.presets.herdr ? "enabled" : "disabled",
      "pi": profile.presets.pi ? "enabled" : "disabled",
      "tuicr": profile.presets.tuicr ? "enabled" : "disabled",
    ]
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

struct EnvironmentDoctorCommandRunner: Sendable {
  let status: EnvironmentStatusCommandRunner

  static let live = Self(
    status: EnvironmentStatusCommandRunner(
      prerequisites: .live,
      theme: .live,
      verifier: .live
    )
  )

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    try status.execute(
      operation: "environment_doctor",
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      consumerPaths: consumerPaths,
      includeVerification: true,
      json: json
    )
  }
}
