import Foundation
import ThemeCore

enum DependencyCapabilityCategory: String, CaseIterable, Encodable, Sendable {
  case platformRuntime = "platform_runtime"
  case desktopSubstrate = "desktop_substrate"
  case requiredAdapter = "required_adapter"
  case optionalAdapter = "optional_adapter"

  var title: String {
    switch self {
    case .platformRuntime:
      "Platform and hard runtime"
    case .desktopSubstrate:
      "Retained desktop substrate"
    case .requiredAdapter:
      "Required enabled adapters"
    case .optionalAdapter:
      "Optional adapters"
    }
  }

  var isRequired: Bool {
    self != .optionalAdapter
  }
}

enum DependencyCapabilityProbe: Sendable {
  case anyExecutable([URL])
  case architecture(String)
  case executable(URL)
  case exists(URL)
  case macOSMajorVersion(Int)

  var description: String {
    switch self {
    case .anyExecutable(let urls):
      urls.map(\.path).joined(separator: " or ") + " must be executable"
    case .architecture(let architecture):
      "requires \(architecture) architecture"
    case .executable(let url):
      "\(url.path) must be executable"
    case .exists(let url):
      "\(url.path) must exist"
    case .macOSMajorVersion(let version):
      "requires macOS \(version)"
    }
  }

  func isSatisfied() -> Bool {
    switch self {
    case .anyExecutable(let urls):
      return urls.contains { FileManager.default.isExecutableFile(atPath: $0.path) }
    case .architecture(let expected):
      #if arch(arm64)
        return expected == "arm64"
      #else
        return false
      #endif
    case .executable(let url):
      return FileManager.default.isExecutableFile(atPath: url.path)
    case .exists(let url):
      return FileManager.default.fileExists(atPath: url.path)
    case .macOSMajorVersion(let expected):
      return ProcessInfo.processInfo.operatingSystemVersion.majorVersion == expected
    }
  }
}

enum DependencyRemediation: Encodable, Sendable {
  enum Kind: String, Encodable, Sendable {
    case cask
    case external
    case formula
  }

  case cask(String)
  case external(String)
  case formula(String)

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .cask(let package):
      try container.encode(Kind.cask, forKey: .kind)
      try container.encode(package, forKey: .package)
    case .formula(let package):
      try container.encode(Kind.formula, forKey: .kind)
      try container.encode(package, forKey: .package)
    case .external(let instruction):
      try container.encode(Kind.external, forKey: .kind)
      try container.encode(instruction, forKey: .instruction)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case package
    case instruction
  }
}

struct DependencyCapability: Sendable {
  let id: String
  let category: DependencyCapabilityCategory
  let probes: [DependencyCapabilityProbe]
  let remediation: DependencyRemediation

  var required: Bool {
    category.isRequired
  }

  var requirement: String {
    probes.map(\.description).joined(separator: "; ")
  }

  func isAvailable() -> Bool {
    probes.allSatisfy { $0.isSatisfied() }
  }
}

struct DependencyProfile: Sendable {
  static let availableNames = ["personal"]

  let name: String
  let capabilities: [DependencyCapability]

  func selected(by portableProfile: PortableProfile) -> DependencyProfile {
    let selected = capabilities.compactMap { capability -> DependencyCapability? in
      let selectedPreset: Bool
      switch capability.id {
      case CodexAdapter.id: selectedPreset = portableProfile.environment.presets.codex
      case HerdrAdapter.id: selectedPreset = portableProfile.environment.presets.herdr
      case PiAdapter.id: selectedPreset = portableProfile.environment.presets.pi
      case SlackAdapter.id: selectedPreset = portableProfile.environment.presets.slack
      case SpicetifyAdapter.id, "spotify":
        selectedPreset = portableProfile.environment.presets.spicetify
      case TuicrAdapter.id: selectedPreset = portableProfile.environment.presets.tuicr
      default: return capability
      }
      guard selectedPreset else { return nil }
      return DependencyCapability(
        id: capability.id,
        category: .requiredAdapter,
        probes: capability.probes,
        remediation: capability.remediation
      )
    }
    return DependencyProfile(name: name, capabilities: selected)
  }

  static func named(_ name: String, homeDirectory: URL) -> DependencyProfile? {
    guard name == "personal" else { return nil }
    return personal(homeDirectory: homeDirectory)
  }

  static func personal(homeDirectory: URL) -> DependencyProfile {
    func executable(_ path: String) -> [DependencyCapabilityProbe] {
      [.executable(URL(filePath: path))]
    }

    func externallyTrustedFormula(_ package: String) -> DependencyRemediation {
      .external(
        "Run: brew trust --formula \(package) && "
          + "HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "
          + "HOMEBREW_NO_INSTALL_UPGRADE=1 brew install --formula \(package)"
      )
    }

    func consumerCapability(
      _ consumerID: ConsumerID,
      dependencyID: String? = nil,
      probes: [DependencyCapabilityProbe],
      remediation: DependencyRemediation
    ) -> DependencyCapability {
      let entry = ConsumerCatalog.shared.entry(for: consumerID)
      let capabilityID = dependencyID ?? consumerID.rawValue
      guard
        let registration = entry?.dependencies.first(where: { $0.id == capabilityID })
      else {
        preconditionFailure(
          "Consumer '\(consumerID.rawValue)' does not declare dependency '\(capabilityID)'"
        )
      }
      let category: DependencyCapabilityCategory =
        switch registration.role {
        case .desktopSubstrate:
          .desktopSubstrate
        case .requiredAdapter:
          .requiredAdapter
        case .optionalAdapter:
          .optionalAdapter
        }
      return DependencyCapability(
        id: registration.id,
        category: category,
        probes: probes,
        remediation: remediation
      )
    }

    let profile = DependencyProfile(
      name: "personal",
      capabilities: [
        DependencyCapability(
          id: "macos-26",
          category: .platformRuntime,
          probes: [
            .macOSMajorVersion(26),
            .executable(URL(filePath: "/usr/bin/osascript")),
          ],
          remediation: .external("Run Macarchy on macOS 26.")
        ),
        DependencyCapability(
          id: "arm64",
          category: .platformRuntime,
          probes: [.architecture("arm64")],
          remediation: .external("Run Macarchy on Apple Silicon.")
        ),
        DependencyCapability(
          id: "homebrew",
          category: .platformRuntime,
          probes: executable("/opt/homebrew/bin/brew"),
          remediation: .external("Install Homebrew from https://brew.sh.")
        ),
        consumerCapability(
          .kitty,
          probes: [.exists(URL(filePath: "/Applications/kitty.app"))],
          remediation: .cask("kitty")
        ),
        consumerCapability(
          .sketchyBar,
          probes: executable("/opt/homebrew/bin/sketchybar"),
          remediation: externallyTrustedFormula("felixkratz/formulae/sketchybar")
        ),
        DependencyCapability(
          id: "skhd",
          category: .desktopSubstrate,
          probes: executable("/opt/homebrew/bin/skhd"),
          remediation: externallyTrustedFormula("asmvik/formulae/skhd")
        ),
        DependencyCapability(
          id: "yabai",
          category: .desktopSubstrate,
          probes: executable("/opt/homebrew/bin/yabai"),
          remediation: externallyTrustedFormula("asmvik/formulae/yabai")
        ),
        consumerCapability(
          .atuin,
          probes: [
            .anyExecutable(
              externalThenHomebrewExecutableURLs(
                homeDirectory: homeDirectory,
                externalRelativePath: ".atuin/bin/atuin",
                homebrewExecutableName: "atuin"
              )
            )
          ],
          remediation: .formula("atuin")
        ),
        consumerCapability(
          .bat,
          probes: executable("/opt/homebrew/bin/bat"),
          remediation: .formula("bat")
        ),
        consumerCapability(
          .btop,
          probes: executable("/opt/homebrew/bin/btop"),
          remediation: .formula("btop")
        ),
        consumerCapability(
          .codex,
          probes: executable("/opt/homebrew/bin/codex"),
          remediation: .cask("codex")
        ),
        consumerCapability(
          .eza,
          probes: executable("/opt/homebrew/bin/eza"),
          remediation: .formula("eza")
        ),
        consumerCapability(
          .herdr,
          probes: [
            .anyExecutable(
              externalThenHomebrewExecutableURLs(
                homeDirectory: homeDirectory,
                externalRelativePath: ".local/bin/herdr",
                homebrewExecutableName: "herdr"
              )
            )
          ],
          remediation: .formula("herdr")
        ),
        consumerCapability(
          .neovim,
          probes: executable("/opt/homebrew/bin/nvim"),
          remediation: .formula("neovim")
        ),
        consumerCapability(
          .pi,
          probes: executable("/opt/homebrew/bin/pi"),
          remediation: .external(
            "Run: npm install --global @earendil-works/pi-coding-agent"
          )
        ),
        consumerCapability(
          .slack,
          probes: [.exists(URL(filePath: "/Applications/Slack.app"))],
          remediation: .cask("slack")
        ),
        consumerCapability(
          .starship,
          probes: executable("/opt/homebrew/bin/starship"),
          remediation: .formula("starship")
        ),
        consumerCapability(
          .tuicr,
          probes: executable("/opt/homebrew/bin/tuicr"),
          remediation: .formula("tuicr")
        ),
        consumerCapability(
          .yazi,
          probes: [
            .executable(URL(filePath: "/opt/homebrew/bin/yazi")),
            .executable(URL(filePath: "/opt/homebrew/bin/ya")),
          ],
          remediation: .formula("yazi")
        ),
        consumerCapability(
          .spicetify,
          probes: executable("/opt/homebrew/bin/spicetify"),
          remediation: .formula("spicetify-cli")
        ),
        consumerCapability(
          .spicetify,
          dependencyID: "spotify",
          probes: [.exists(URL(filePath: "/Applications/Spotify.app"))],
          remediation: .cask("spotify")
        ),
      ]
    )
    do {
      try ConsumerIntegrationConsistency.validateDependencyCapabilities(profile.capabilities)
    } catch {
      preconditionFailure("Invalid consumer dependency catalog integration: \(error)")
    }
    return profile
  }
}

struct SetupCommandRunner: Sendable {
  let resolveProfile: @Sendable (String, URL) -> DependencyProfile?
  let capabilityIsAvailable: @Sendable (DependencyCapability) -> Bool
  let processRunner: ProcessRunner
  let writePreMutationPlan: @Sendable (String) throws -> Void
  let setupIntegrations: @Sendable (URL, Bool) throws -> [SetupIntegrationResult]
  let setupKeybindings: @Sendable (URL, Bool, URL, Bool, String?) throws -> SetupIntegrationResult?

  init(
    resolveProfile: @escaping @Sendable (String, URL) -> DependencyProfile?,
    capabilityIsAvailable: @escaping @Sendable (DependencyCapability) -> Bool,
    processRunner: ProcessRunner,
    writePreMutationPlan: @escaping @Sendable (String) throws -> Void,
    setupIntegrations: @escaping @Sendable (URL, Bool) throws -> [SetupIntegrationResult],
    setupKeybindings:
      @escaping @Sendable (URL, Bool, URL, Bool, String?) throws -> SetupIntegrationResult? = {
        _, _, _, _, _ in nil
      }
  ) {
    self.resolveProfile = resolveProfile
    self.capabilityIsAvailable = capabilityIsAvailable
    self.processRunner = processRunner
    self.writePreMutationPlan = writePreMutationPlan
    self.setupIntegrations = setupIntegrations
    self.setupKeybindings = setupKeybindings
  }

  static let live = SetupCommandRunner(
    resolveProfile: DependencyProfile.named,
    capabilityIsAvailable: { $0.isAvailable() },
    processRunner: .live,
    writePreMutationPlan: { output in
      try FileHandle.standardError.write(contentsOf: Data("\(output)\n".utf8))
    },
    setupIntegrations: { homeDirectory, dryRun in
      try SetupOwnershipManager().setup(
        homeDirectory: homeDirectory,
        dryRun: dryRun,
        excluding: [.codex, .herdr, .pi, .tuicr]
      )
    },
    setupKeybindings: { profileURL, profileRequired, homeDirectory, dryRun, adopt in
      try KeybindingsApplyCommandRunner.live.setupIntegration(
        resourcesRoot: RuntimeEnvironment.live.builtInKeybindingsURL,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: homeDirectory.appending(
          path: ".config/macarchy",
          directoryHint: .isDirectory
        ),
        homeDirectory: homeDirectory,
        adopt: adopt,
        dryRun: dryRun
      )
    }
  )

  func execute(
    profileName: String,
    homeDirectory: URL,
    installDependencies: Bool,
    dryRun: Bool,
    keybindingProfileURL: URL? = nil,
    keybindingProfileRequired: Bool = false,
    adoptKeybindings: String? = nil,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    guard let dependencyProfile = resolveProfile(profileName, homeDirectory) else {
      let report = SetupReport.unknownProfile(
        profileName,
        installDependencies: installDependencies,
        dryRun: dryRun
      )
      return (try report.render(json: json), false)
    }

    let portableProfile = try PortableProfileLoader().load(
      at: keybindingProfileURL
        ?? homeDirectory.appending(path: ".config/macarchy/profile.toml"),
      required: keybindingProfileRequired
    )
    let profile = dependencyProfile.selected(by: portableProfile)

    return try apply(
      SetupPreparation(
        profile: profile,
        homeDirectory: homeDirectory,
        installDependencies: installDependencies,
        dryRun: dryRun,
        keybindingProfileURL:
          keybindingProfileURL
          ?? homeDirectory.appending(path: ".config/macarchy/profile.toml"),
        keybindingProfileRequired: keybindingProfileRequired,
        adoptKeybindings: adoptKeybindings,
        capabilities: inspect(profile)
      ),
      json: json
    )
  }

  private func apply(
    _ preparation: SetupPreparation,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    var capabilities = preparation.capabilities
    let installPlan = HomebrewInstallPlan(capabilities: capabilities)
    var commandResults = [HomebrewCommandResult]()
    var failure: SetupInstallationFailure?
    var mutationAttempted = false

    if preparation.installDependencies, !preparation.dryRun {
      let missingPrerequisites = capabilities.filter {
        $0.category == .platformRuntime && $0.status == .missing
      }.map(\.id)
      if !missingPrerequisites.isEmpty {
        failure = .blocked(missingPrerequisites)
      } else if !installPlan.requests.isEmpty {
        try writePreMutationPlan(
          try installPlan.preMutationOutput(
            profileName: preparation.profile.name,
            json: json
          )
        )
        for request in installPlan.requests {
          mutationAttempted = true
          let result: HomebrewCommandResult
          do {
            result = HomebrewCommandResult(
              request: request,
              result: try processRunner.run(request)
            )
          } catch {
            result = HomebrewCommandResult(request: request, launchError: error)
          }
          commandResults.append(result)
          guard result.succeeded else {
            failure = .command(result)
            break
          }
        }

        capabilities = inspect(preparation.profile)
        if failure == nil {
          let unresolved = capabilities.filter {
            installPlan.homebrewCapabilityIDs.contains($0.id) && $0.status == .missing
          }.map(\.id)
          if !unresolved.isEmpty {
            failure = .verification(unresolved)
          }
        }
      }
    }

    let keybindingPreview = try setupKeybindings(
      preparation.keybindingProfileURL,
      preparation.keybindingProfileRequired,
      preparation.homeDirectory,
      true,
      preparation.adoptKeybindings
    )

    var integrations: [SetupIntegrationResult]
    do {
      integrations = try setupIntegrations(preparation.homeDirectory, preparation.dryRun)
    } catch {
      integrations = SetupOwnershipManager.failureResults(
        error,
        homeDirectory: preparation.homeDirectory
      )
    }
    if preparation.dryRun {
      if let keybindingPreview { integrations.append(keybindingPreview) }
    } else if integrations.allSatisfy(\.succeeded), failure == nil,
      keybindingPreview?.succeeded != false
    {
      if let keybindings = try setupKeybindings(
        preparation.keybindingProfileURL,
        preparation.keybindingProfileRequired,
        preparation.homeDirectory,
        false,
        preparation.adoptKeybindings
      ) {
        integrations.append(keybindings)
      }
    } else if let keybindingPreview {
      integrations.append(keybindingPreview)
    }
    mutationAttempted = mutationAttempted || integrations.contains(where: \.mutationAttempted)

    let report = SetupReport.profile(
      preparation.profile.name,
      installDependencies: preparation.installDependencies,
      dryRun: preparation.dryRun,
      capabilities: capabilities,
      installPlan: installPlan,
      commandResults: commandResults,
      mutationAttempted: mutationAttempted,
      installationFailure: failure,
      integrations: integrations
    )
    return (try report.render(json: json), report.succeeded)
  }

  private func inspect(_ profile: DependencyProfile) -> [SetupCapability] {
    profile.capabilities.map { capability in
      SetupCapability(
        id: capability.id,
        category: capability.category,
        required: capability.required,
        status: capabilityIsAvailable(capability) ? .present : .missing,
        requirement: capability.requirement,
        remediation: capability.remediation
      )
    }
  }
}

private struct SetupPreparation {
  let profile: DependencyProfile
  let homeDirectory: URL
  let installDependencies: Bool
  let dryRun: Bool
  let keybindingProfileURL: URL
  let keybindingProfileRequired: Bool
  let adoptKeybindings: String?
  let capabilities: [SetupCapability]
}

struct HomebrewInstallPlan: Encodable, Sendable {
  static let environment = [
    "HOMEBREW_NO_AUTOREMOVE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_INSTALL_UPGRADE": "1",
  ]

  let formulae: [String]
  let casks: [String]
  let external: [ExternalDependencyRemediation]
  let homebrewCapabilityIDs: Set<String>

  init(capabilities: [SetupCapability]) {
    var formulae = [String]()
    var casks = [String]()
    var external = [ExternalDependencyRemediation]()
    var homebrewCapabilityIDs = Set<String>()
    for capability in capabilities where capability.status == .missing {
      switch capability.remediation {
      case .formula(let package):
        formulae.append(package)
        homebrewCapabilityIDs.insert(capability.id)
      case .cask(let package):
        casks.append(package)
        homebrewCapabilityIDs.insert(capability.id)
      case .external(let instruction):
        external.append(
          ExternalDependencyRemediation(
            capabilityID: capability.id,
            instruction: instruction
          )
        )
      }
    }
    self.formulae = formulae
    self.casks = casks
    self.external = external
    self.homebrewCapabilityIDs = homebrewCapabilityIDs
  }

  var requests: [ProcessRequest] {
    var requests = [ProcessRequest]()
    if !formulae.isEmpty {
      requests.append(
        ProcessRequest(
          executableURL: URL(filePath: "/opt/homebrew/bin/brew"),
          arguments: ["install", "--formula", "--no-ask"] + formulae,
          environmentOverrides: Self.environment
        )
      )
    }
    if !casks.isEmpty {
      requests.append(
        ProcessRequest(
          executableURL: URL(filePath: "/opt/homebrew/bin/brew"),
          arguments: ["install", "--cask", "--no-ask"] + casks,
          environmentOverrides: Self.environment
        )
      )
    }
    return requests
  }

  var humanOutput: String {
    var lines = ["Dependency installation plan:"]
    lines.append("- Formulae: \(formulae.isEmpty ? "none" : formulae.joined(separator: ", "))")
    lines.append("- Casks: \(casks.isEmpty ? "none" : casks.joined(separator: ", "))")
    if external.isEmpty {
      lines.append("- External remediation: none")
    } else {
      lines.append("- External remediation:")
      lines.append(
        contentsOf: external.map {
          "  - \($0.capabilityID): \($0.instruction)"
        }
      )
    }
    return lines.joined(separator: "\n")
  }

  func preMutationOutput(profileName: String, json: Bool) throws -> String {
    if json {
      return try renderJSON(
        SetupPreMutationPlanJSON(profile: profileName, plan: self)
      )
    }
    return humanOutput
  }

  enum CodingKeys: String, CodingKey {
    case formulae
    case casks
    case external
  }
}

struct ExternalDependencyRemediation: Encodable, Sendable {
  let capabilityID: String
  let instruction: String
}

struct SetupCapability: Encodable, Sendable {
  enum Status: String, Encodable, Sendable {
    case present
    case missing
  }

  let id: String
  let category: DependencyCapabilityCategory
  let required: Bool
  let status: Status
  let requirement: String
  let remediation: DependencyRemediation
}

struct HomebrewCommandResult: Encodable, Sendable {
  enum Outcome: String, Encodable, Sendable {
    case exited
    case launchFailed = "launch_failed"
  }

  let executable: String
  let arguments: [String]
  let outcome: Outcome
  let terminationStatus: Int32?
  let output: String?
  let error: String?

  init(request: ProcessRequest, result: ProcessResult) {
    executable = request.executableURL.path
    arguments = request.arguments
    outcome = .exited
    terminationStatus = result.terminationStatus
    output = result.output.isEmpty ? nil : result.output
    error = nil
  }

  init(request: ProcessRequest, launchError: Error) {
    executable = request.executableURL.path
    arguments = request.arguments
    outcome = .launchFailed
    terminationStatus = nil
    output = nil
    error = String(describing: launchError)
  }

  var succeeded: Bool {
    outcome == .exited && terminationStatus == 0
  }

  var failureDescription: String {
    switch outcome {
    case .launchFailed:
      return
        "Could not launch \(executable) \(arguments.joined(separator: " ")): \(error ?? "unknown error")"
    case .exited:
      let status = terminationStatus.map(String.init) ?? "unknown"
      return output ?? "Homebrew exited with status \(status)"
    }
  }
}

struct SetupInstallationFailure: Encodable, Sendable {
  enum Kind: String, Encodable, Sendable {
    case blockedPrerequisites = "blocked_prerequisites"
    case commandFailed = "command_failed"
    case verificationFailed = "verification_failed"
  }

  let kind: Kind
  let message: String
  let capabilityIDs: [String]?

  enum CodingKeys: String, CodingKey {
    case kind
    case message
    case capabilityIDs = "capability_ids"
  }

  static func blocked(_ capabilityIDs: [String]) -> SetupInstallationFailure {
    SetupInstallationFailure(
      kind: .blockedPrerequisites,
      message: "Dependency installation requires all platform/runtime capabilities.",
      capabilityIDs: capabilityIDs
    )
  }

  static func command(_ result: HomebrewCommandResult) -> SetupInstallationFailure {
    SetupInstallationFailure(
      kind: .commandFailed,
      message: result.failureDescription,
      capabilityIDs: nil
    )
  }

  static func verification(_ capabilityIDs: [String]) -> SetupInstallationFailure {
    SetupInstallationFailure(
      kind: .verificationFailed,
      message: "Homebrew completed, but planned capabilities remain missing.",
      capabilityIDs: capabilityIDs
    )
  }
}

private enum SetupReport {
  enum Outcome: String, Encodable {
    case dependencyInstallationBlocked = "dependency_installation_blocked"
    case dependencyInstallationFailed = "dependency_installation_failed"
    case dependencyInstallationVerificationFailed =
      "dependency_installation_verification_failed"
    case integrationFailed = "integration_failed"
    case missingRequiredCapabilities = "missing_required_capabilities"
    case ready
    case unknownProfile = "unknown_profile"
  }

  case profile(
    String,
    installDependencies: Bool,
    dryRun: Bool,
    capabilities: [SetupCapability],
    installPlan: HomebrewInstallPlan,
    commandResults: [HomebrewCommandResult],
    mutationAttempted: Bool,
    installationFailure: SetupInstallationFailure?,
    integrations: [SetupIntegrationResult]
  )
  case unknownProfile(String, installDependencies: Bool, dryRun: Bool)

  var succeeded: Bool {
    switch self {
    case .profile(
      _, _, _, let capabilities, _, _, _, let installationFailure, let integrations
    ):
      return installationFailure == nil
        && !capabilities.contains { $0.required && $0.status == .missing }
        && integrations.allSatisfy(\.succeeded)
    case .unknownProfile:
      return false
    }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }

    switch self {
    case .profile(
      let name,
      let installDependencies,
      let dryRun,
      let capabilities,
      let installPlan,
      let commandResults,
      let mutationAttempted,
      let installationFailure,
      let integrations
    ):
      var lines = ["Macarchy setup profile '\(name)'\(dryRun ? " (dry run)" : ""):"]
      for category in DependencyCapabilityCategory.allCases {
        lines.append("\(category.title):")
        lines.append(
          contentsOf: capabilities.filter { $0.category == category }.map { capability in
            "- \(capability.id) [\(capability.status.rawValue)]: \(capability.requirement)"
          }
        )
      }
      lines.append(installPlan.humanOutput)

      if let installationFailure {
        lines.append(
          "Dependency installation \(installationFailure.kind.rawValue): \(installationFailure.message)"
        )
        if let capabilityIDs = installationFailure.capabilityIDs {
          lines.append("- Capabilities: \(capabilityIDs.joined(separator: ", "))")
        }
      } else if !installDependencies {
        lines.append("Dependency installation was not requested.")
      } else if dryRun {
        lines.append("Dependency installation was not run (dry run).")
      } else if commandResults.isEmpty {
        lines.append(
          installPlan.external.isEmpty
            ? "No dependency installation was needed."
            : "Only external remediation remains; Homebrew was not run."
        )
      } else {
        lines.append("Homebrew installation commands completed and were verified.")
      }

      lines.append("Integrations:")
      lines.append(
        contentsOf: integrations.map {
          "- \($0.id) [\($0.status.rawValue)]: \($0.message)"
        }
      )

      let summary = SetupSummary(capabilities: capabilities)
      lines.append(
        "Summary: \(summary.presentCount) present, \(summary.missingRequiredCount) missing "
          + "required, \(summary.missingOptionalCount) missing optional."
      )
      lines.append(mutationAttempted ? "Setup mutation attempted." : "No changes made.")
      return lines.joined(separator: "\n")
    case .unknownProfile(let name, _, _):
      return [
        "Unknown dependency profile '\(name)'.",
        "Available profiles: \(DependencyProfile.availableNames.joined(separator: ", ")).",
        "No changes made.",
      ].joined(separator: "\n")
    }
  }

  private var jsonReport: SetupJSONReport {
    switch self {
    case .profile(
      let name,
      let installDependencies,
      let dryRun,
      let capabilities,
      let installPlan,
      let commandResults,
      let mutationAttempted,
      let installationFailure,
      let integrations
    ):
      return SetupJSONReport(
        outcome: outcome(
          capabilities: capabilities,
          installationFailure: installationFailure,
          integrations: integrations
        ),
        profile: name,
        dryRun: dryRun,
        mutationAttempted: mutationAttempted,
        capabilities: capabilities,
        summary: SetupSummary(capabilities: capabilities),
        dependencyInstallation: SetupInstallationReport(
          requested: installDependencies,
          plan: installPlan,
          commands: commandResults,
          failure: installationFailure
        ),
        integrations: integrations
      )
    case .unknownProfile(let name, let installDependencies, let dryRun):
      return SetupJSONReport(
        outcome: .unknownProfile,
        profile: name,
        dryRun: dryRun,
        mutationAttempted: false,
        availableProfiles: DependencyProfile.availableNames,
        dependencyInstallation: SetupInstallationReport(
          requested: installDependencies,
          plan: HomebrewInstallPlan(capabilities: []),
          commands: [],
          failure: nil
        ),
        error: "Unknown dependency profile"
      )
    }
  }

  private func outcome(
    capabilities: [SetupCapability],
    installationFailure: SetupInstallationFailure?,
    integrations: [SetupIntegrationResult]
  ) -> Outcome {
    switch installationFailure?.kind {
    case .blockedPrerequisites:
      return .dependencyInstallationBlocked
    case .commandFailed:
      return .dependencyInstallationFailed
    case .verificationFailed:
      return .dependencyInstallationVerificationFailed
    case nil:
      if capabilities.contains(where: { $0.required && $0.status == .missing }) {
        return .missingRequiredCapabilities
      }
      return integrations.allSatisfy(\.succeeded) ? .ready : .integrationFailed
    }
  }
}

private struct SetupSummary: Encodable {
  let presentCount: Int
  let missingRequiredCount: Int
  let missingOptionalCount: Int

  init(capabilities: [SetupCapability]) {
    presentCount = capabilities.count { $0.status == .present }
    missingRequiredCount = capabilities.count { $0.required && $0.status == .missing }
    missingOptionalCount = capabilities.count { !$0.required && $0.status == .missing }
  }
}

private struct SetupInstallationReport: Encodable {
  let requested: Bool
  let plan: HomebrewInstallPlan
  let commands: [HomebrewCommandResult]
  let failure: SetupInstallationFailure?
}

private struct SetupJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "setup"
  let outcome: SetupReport.Outcome
  let profile: String
  let dryRun: Bool
  let mutationAttempted: Bool
  var capabilities: [SetupCapability]? = nil
  var summary: SetupSummary? = nil
  var availableProfiles: [String]? = nil
  var dependencyInstallation: SetupInstallationReport
  var integrations: [SetupIntegrationResult]? = nil
  var error: String? = nil
}

private struct SetupPreMutationPlanJSON: Encodable {
  let schemaVersion = 1
  let operation = "setup_dependency_installation_plan"
  let profile: String
  let plan: HomebrewInstallPlan
}
