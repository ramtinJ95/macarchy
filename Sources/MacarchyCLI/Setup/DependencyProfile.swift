import Foundation
import ThemeCore

enum DependencyCapabilityCategory: String, Encodable, Sendable {
  case platformRuntime = "platform_runtime"
  case desktopSubstrate = "desktop_substrate"
  case requiredAdapter = "required_adapter"
  case optionalAdapter = "optional_adapter"
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

  var requirement: String {
    probes.map(\.description).joined(separator: "; ")
  }

  func isAvailable() -> Bool {
    probes.allSatisfy { $0.isSatisfied() }
  }
}

struct DependencyProfile: Sendable {
  let capabilities: [DependencyCapability]

  func selectedForDesktop(_ profile: PortableProfile) -> [DependencyCapability] {
    var ids = Set(["macos-26", "arm64", "homebrew"])
    if profile.desktop.provider == .yabaiSkhd { ids.formUnion(["skhd", "yabai"]) }
    if profile.topBar == .sketchybar { ids.insert("sketchybar") }
    return selected(ids)
  }

  func selectedForEnvironment(_ profile: EnvironmentProfile) -> [DependencyCapability] {
    guard !profile.isEntirelyDisabled else { return [] }
    var ids = Set(["macos-26", "arm64"])
    if profile.terminal == .kitty { ids.insert("kitty") }
    if profile.prompt == .starship { ids.insert("starship") }
    if profile.history == .atuin { ids.insert("atuin") }
    if profile.editor == .neovim { ids.insert("neovim") }
    if profile.tools.bat { ids.insert("bat") }
    if profile.tools.btop { ids.insert("btop") }
    if profile.tools.eza { ids.insert("eza") }
    if profile.tools.yazi { ids.insert("yazi") }
    if profile.presets.codex { ids.insert(CodexAdapter.id) }
    if profile.presets.herdr { ids.insert(HerdrAdapter.id) }
    if profile.presets.pi { ids.insert(PiAdapter.id) }
    if profile.presets.slack { ids.insert(SlackAdapter.id) }
    if profile.presets.spicetify { ids.formUnion([SpicetifyAdapter.id, "spotify"]) }
    if profile.presets.tuicr { ids.insert(TuicrAdapter.id) }
    return selected(ids)
  }

  func selectedForSetup(_ profile: PortableProfile) -> [DependencyCapability] {
    let ids = Set(
      (selectedForDesktop(profile) + selectedForEnvironment(profile.environment)).map(\.id)
    )
    return selected(ids)
  }

  private func selected(_ ids: Set<String>) -> [DependencyCapability] {
    capabilities.filter { ids.contains($0.id) }
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

struct HomebrewInstallPlan: Encodable, Sendable {
  static let environment = [
    "HOMEBREW_NO_AUTOREMOVE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_INSTALL_UPGRADE": "1",
  ]

  let formulae: [String]
  let casks: [String]
  let external: [ExternalDependencyRemediation]

  init(capabilities: [SetupCapability]) {
    var formulae = [String]()
    var casks = [String]()
    var external = [ExternalDependencyRemediation]()
    for capability in capabilities where capability.status == .missing {
      switch capability.remediation {
      case .formula(let package):
        formulae.append(package)
      case .cask(let package):
        casks.append(package)
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
  let status: Status
  let requirement: String
  let remediation: DependencyRemediation
}
