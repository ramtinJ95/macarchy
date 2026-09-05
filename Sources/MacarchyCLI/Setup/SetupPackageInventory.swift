import Foundation
import ThemeCore

/// Desired declarations, provider requirements and installation records are not an
/// applied package ledger. Nothing in this report authorizes package mutation.
struct SetupPackageInventory: Encodable, Sendable {
  struct Requirement: Encodable, Sendable {
    let capabilityID: String
    let selectionField: String?
    let layer: String
    let sourcePath: String?
    let runtime: SetupCapability.Status
    let runtimeRequirement: String
    let remediation: DependencyRemediation
  }

  struct Package: Encodable, Sendable {
    let identity: HomebrewPackageIdentity
    let standardDeclaration: StandardDeclaration?
    let requirements: [Requirement]
    let homebrewStatus: String
    let externallySatisfiedCapabilities: [String]
    let adoption = "not_applied"
  }

  struct StandardDeclaration: Encodable, Sendable {
    let source = "standard_baseline"
    let layer = "built_in"
    let intent = "package_only"
    let remediation: DependencyRemediation
  }

  /// Only additional stock declarations belong here. Provider packages continue
  /// to come from DependencyProfile so disabling a role removes its requirement.
  private static let standardDeclarations: [HomebrewPackageIdentity: StandardDeclaration] = {
    let formulae = [
      "azure-cli", "cmake", "fd", "fzf", "gh", "git", "go", "helm", "herdr", "hugo",
      "ifstat", "jq", "kind", "kubernetes-cli", "lazydocker", "lazygit", "lua", "mosh",
      "node", "ollama", "pkgconf", "poppler", "resvg", "ripgrep", "rustup", "sevenzip",
      "stow", "switchaudio-osx", "tmux", "tree-sitter", "tree-sitter-cli", "unar", "uv",
      "wget", "zig", "zoxide",
    ]
    let casks = [
      "anki", "cursor", "docker", "flameshot", "font-blex-mono-nerd-font",
      "font-meslo-lg-nerd-font", "font-sketchybar-app-font", "font-symbols-only-nerd-font",
      "google-chrome", "slack", "spotify", "tailscale", "zen", "zoom",
    ]
    let terraform = "hashicorp/tap/terraform"
    return Dictionary(
      uniqueKeysWithValues:
        formulae.map {
          (
            HomebrewPackageIdentity(kind: .formula, name: $0),
            StandardDeclaration(remediation: .formula($0))
          )
        }
        + casks.map {
          (
            HomebrewPackageIdentity(kind: .cask, name: $0),
            StandardDeclaration(remediation: .cask($0))
          )
        } + [
          (
            HomebrewPackageIdentity(kind: .formula, name: terraform),
            StandardDeclaration(remediation: .externallyTrustedFormula(terraform))
          )
        ])
  }()

  let observation: HomebrewPackageObservation
  let proposed: [Package]
  let nonHomebrewRequirements: [Requirement]
  let outsideProposedRequirements: [HomebrewInstalledPackage]
  let unresolvedInstallations: [HomebrewInstalledPackage]
  let scope = "standard_baseline_and_provider_requirements"
  let authority = "observation_only_no_package_adoption"
  let provisioning = "preview_only_existing_apply_unchanged"

  init(
    capabilities: [SetupCapability], fieldOrigins: [String: String],
    layers: [SetupProfileLayerReport], observation: HomebrewPackageObservation
  ) {
    self.observation = observation
    var groups = [HomebrewPackageIdentity: [Requirement]]()
    var nonHomebrew = [Requirement]()
    for capability in capabilities.sorted(by: { $0.id < $1.id }) {
      let field = Self.selectionField(for: capability.id)
      let layer = field.flatMap { fieldOrigins[$0] } ?? "built_in"
      let requirement = Requirement(
        capabilityID: capability.id, selectionField: field, layer: layer,
        sourcePath: layers.first { $0.kind == layer }?.path,
        runtime: capability.status, runtimeRequirement: capability.requirement,
        remediation: capability.remediation
      )
      if let identity = capability.remediation.homebrewPackage {
        groups[identity, default: []].append(requirement)
      } else {
        nonHomebrew.append(requirement)
      }
    }
    let identities = Set(groups.keys).union(Self.standardDeclarations.keys)
    proposed = identities.sorted { $0.key < $1.key }.map { identity in
      let requirements = groups[identity] ?? []
      let matches = observation.packages.filter { $0.identity == identity }
      let sameToken = observation.packages.filter {
        $0.kind == identity.kind && $0.token == identity.token
      }
      let status: String
      if matches.count == 1 {
        status = "installed"
      } else if matches.count > 1 {
        status = "ambiguous"
      } else if !observation.issues.isEmpty || sameToken.contains(where: { $0.identity == nil }) {
        status = "unknown"
      } else if !sameToken.isEmpty {
        status = "different_recorded_identity"
      } else {
        status = "missing"
      }
      return Package(
        identity: identity, standardDeclaration: Self.standardDeclarations[identity],
        requirements: requirements, homebrewStatus: status,
        externallySatisfiedCapabilities: status == "missing"
          ? requirements.filter { $0.runtime == .present }.map(\.capabilityID) : []
      )
    }
    nonHomebrewRequirements = nonHomebrew
    outsideProposedRequirements = observation.packages.filter {
      guard let identity = $0.identity else { return false }
      return !identities.contains(identity)
    }.sorted { $0.identity!.key < $1.identity!.key }
    unresolvedInstallations = observation.packages.filter { $0.identity == nil }
      .sorted { "\($0.kind.rawValue):\($0.token)" < "\($1.kind.rawValue):\($1.token)" }
  }

  var humanOutput: String {
    var lines = [
      "Package inventory [\(observation.status); standard baseline and provider requirements]:",
      "- Preview only; no package adoption applied. Apply does not yet provision the standard baseline.",
      "- Existing provider dependency installation is unchanged; installer compatibility is not verified here.",
      "- Package-only declarations do not enable behavior/theme presets or prove runtime readiness.",
      "- Packages do not authorize permissions, accounts, services/helpers, model/toolchain downloads or shell hooks.",
      "- Identities come from installation records; aliases/tap renames are not resolved.",
      "- Runtime availability is separate; it does not identify which installation supplies an executable.",
    ]
    for package in proposed {
      lines.append("- \(package.identity.key) [\(package.homebrewStatus); not adopted]")
      if let declaration = package.standardDeclaration {
        lines.append(
          "  - standard_baseline from \(declaration.layer): package only; runtime not assessed")
        if case .external(let instruction, _) = declaration.remediation {
          lines.append("    Manual/trust boundary (trust not inspected): \(instruction)")
        }
      }
      for requirement in package.requirements {
        lines.append(
          "  - \(requirement.capabilityID): runtime \(requirement.runtime.rawValue); "
            + "\(requirement.selectionField ?? "platform") from \(requirement.layer)"
            + (requirement.sourcePath.map { " (\($0))" } ?? "")
        )
        if case .external(let instruction, _) = requirement.remediation {
          lines.append("    Manual/trust boundary: \(instruction)")
        }
      }
      if !package.externallySatisfiedCapabilities.isEmpty {
        lines.append(
          "  - Runtime satisfied outside a recorded Homebrew installation: "
            + package.externallySatisfiedCapabilities.joined(separator: ", "))
      }
    }
    for requirement in nonHomebrewRequirements {
      if case .external(let instruction, _) = requirement.remediation {
        lines.append(
          "- \(requirement.capabilityID) [non-Homebrew; runtime \(requirement.runtime.rawValue)]: \(instruction)"
        )
      }
    }
    lines.append(
      "- Outside proposed requirements (unmanaged by this package slice): "
        + (outsideProposedRequirements.isEmpty
          ? "none"
          : outsideProposedRequirements.compactMap { $0.identity?.key }.joined(separator: ", ")))
    for package in unresolvedInstallations {
      lines.append(
        "- Unresolved \(package.kind.rawValue):\(package.token): \(package.issue ?? "unknown identity")"
      )
    }
    lines += observation.issues.map { "- Inventory unavailable: \($0)" }
    return lines.joined(separator: "\n")
  }

  /// These are the selection fields used by DependencyProfile, not a second
  /// package catalog. Package identity always comes from typed remediation.
  private static func selectionField(for capabilityID: String) -> String? {
    switch capabilityID {
    case "skhd", "yabai": "desktop.provider"
    case "sketchybar": "top_bar.provider"
    case "kitty": "terminal.provider"
    case "starship": "prompt.provider"
    case "atuin": "history.provider"
    case "neovim": "editor.provider"
    case "bat", "eza", "btop", "yazi": "tools.\(capabilityID)"
    case "codex", "herdr", "pi", "slack", "spicetify", "tuicr": "presets.\(capabilityID)"
    case "spotify": "presets.spicetify"
    default: nil
    }
  }
}
