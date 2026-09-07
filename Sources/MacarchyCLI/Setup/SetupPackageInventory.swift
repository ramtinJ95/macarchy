import Foundation
import ThemeCore

/// Desired declarations, provider requirements and installation records are not an
/// applied package ledger. Adoption is read from its separate persisted evidence;
/// nothing in this report authorizes Homebrew mutation.
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
    let personalDeclarations: [SetupPackageAdoptionLedger.Declaration]
    let requirements: [Requirement]
    let homebrewStatus: String
    let externallySatisfiedCapabilities: [String]
    let adoption: String

    var declarations: [SetupPackageAdoptionLedger.Declaration] {
      let standard: [SetupPackageAdoptionLedger.Declaration] =
        standardDeclaration.map {
          [.init(source: $0.source, layer: $0.layer, sourcePath: nil, selectionField: nil)]
        } ?? []
      return standard
        + personalDeclarations
        + requirements.map {
          .init(
            source: $0.capabilityID, layer: $0.layer, sourcePath: $0.sourcePath,
            selectionField: $0.selectionField
          )
        }
    }
  }

  struct StandardDeclaration: Encodable, Sendable {
    let source = "standard_baseline"
    let layer = "built_in"
    let intent = "package_only"
    let remediation: DependencyRemediation
  }

  let observation: HomebrewPackageObservation
  let proposed: [Package]
  let nonHomebrewRequirements: [Requirement]
  let outsideProposedRequirements: [HomebrewInstalledPackage]
  let unresolvedInstallations: [HomebrewInstalledPackage]
  struct RetainedAdoption: Encodable, Sendable {
    let entry: SetupPackageAdoptionLedger.Entry
    let status: String
  }
  let retainedAdoptionsOutsideProposed: [RetainedAdoption]
  let adoptionIssue: String?
  let baseline: PackageBaseline
  let exclusions: [SetupPackageDeclarations.Exclusion]
  let taps: [SetupPackageDeclarations.Tap]
  let effectiveBrewfile: String
  var installation: SetupPackageInstallationAttempt.Summary? = nil
  var installationIssue: String? = nil
  let scope = "declared_packages_and_provider_requirements"
  let authority = "read_only_inventory_no_homebrew_mutation"
  let provisioning = "setup_apply_installs_missing_declarations_without_automatic_adoption"

  init(
    capabilities: [SetupCapability], fieldOrigins: [String: String],
    layers: [SetupProfileLayerReport], observation: HomebrewPackageObservation,
    adoptionState: SetupPackageAdoptionState = .available(nil),
    declarations: SetupPackageDeclarations
  ) {
    baseline = declarations.baseline
    exclusions = declarations.exclusions
    taps = declarations.taps
    let packageSources = Dictionary(
      uniqueKeysWithValues: declarations.packages.map {
        ($0.identity, $0.sources)
      })
    self.observation = observation
    adoptionIssue = adoptionState.issue
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
    let identities = Set(groups.keys).union(packageSources.keys)
    proposed = identities.sorted { $0.key < $1.key }.map { identity in
      let requirements = groups[identity] ?? []
      let sources = packageSources[identity] ?? []
      let standardDeclaration: StandardDeclaration? =
        sources.contains { $0.source == "standard_baseline" }
        ? StandardDeclaration(
          remediation: identity.kind == .cask
            ? .cask(identity.name)
            : (identity.name.contains("/")
              ? .externallyTrustedFormula(identity.name) : .formula(identity.name)))
        : nil
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
      let adoption: String
      if adoptionState.issue != nil {
        adoption = "unknown"
      } else if let entry = adoptionState.ledger?.entries.first(where: { $0.identity == identity })
      {
        adoption = entry.status(in: observation)
      } else {
        adoption =
          status == "installed" ? "unadopted" : (status == "missing" ? "missing" : "unknown")
      }
      return Package(
        identity: identity, standardDeclaration: standardDeclaration,
        personalDeclarations: sources.filter { $0.source == "personal_brewfile" },
        requirements: requirements, homebrewStatus: status,
        externallySatisfiedCapabilities: status == "missing"
          ? requirements.filter { $0.runtime == .present }.map(\.capabilityID) : [],
        adoption: adoption
      )
    }
    nonHomebrewRequirements = nonHomebrew
    outsideProposedRequirements = observation.packages.filter {
      guard let identity = $0.identity else { return false }
      return !identities.contains(identity)
    }.sorted { $0.identity!.key < $1.identity!.key }
    unresolvedInstallations = observation.packages.filter { $0.identity == nil }
      .sorted { "\($0.kind.rawValue):\($0.token)" < "\($1.kind.rawValue):\($1.token)" }
    retainedAdoptionsOutsideProposed = (adoptionState.ledger?.entries ?? [])
      .filter { !identities.contains($0.identity) }
      .map { RetainedAdoption(entry: $0, status: $0.status(in: observation)) }
    effectiveBrewfile = SetupBrewfile(packages: Array(identities), taps: taps.map(\.name)).text
  }

  var humanOutput: String {
    var lines = [
      "Package inventory [\(observation.status); \(baseline.rawValue) baseline and provider requirements]:",
      "- Read-only inventory; adoption requires setup adopt-packages and explicit approval.",
      "- Apply does not yet provision package-only declarations or implicitly adopt packages.",
      "- Existing provider dependency installation is unchanged; installer compatibility is not verified here.",
      "- Package-only declarations do not enable behavior/theme presets or prove runtime readiness.",
      "- Packages do not authorize permissions, accounts, services/helpers, model/toolchain downloads or shell hooks.",
      "- Identities come from installation records; aliases/tap renames are not resolved.",
      "- Runtime availability is separate; it does not identify which installation supplies an executable.",
    ]
    for package in proposed {
      lines.append("- \(package.identity.key) [\(package.homebrewStatus); \(package.adoption)]")
      if let declaration = package.standardDeclaration {
        lines.append(
          "  - standard_baseline from \(declaration.layer): package only; runtime not assessed")
        if case .external(let instruction, _) = declaration.remediation {
          lines.append("    Manual/trust boundary (trust not inspected): \(instruction)")
        }
      }
      for declaration in package.personalDeclarations {
        lines.append(
          "  - personal_brewfile from \(declaration.layer): \(declaration.sourcePath ?? "unknown"); package only"
        )
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
    for exclusion in exclusions {
      lines.append(
        "- Excluded \(exclusion.identity.key) by \(exclusion.source.layer) (\(exclusion.source.sourcePath ?? "unknown")); no uninstall authorized."
      )
    }
    for tap in taps {
      lines.append("- Declared tap \(tap.name): acquisition/trust not inspected or changed here.")
    }
    for requirement in nonHomebrewRequirements {
      if case .external(let instruction, _) = requirement.remediation {
        lines.append(
          "- \(requirement.capabilityID) [non-Homebrew; runtime \(requirement.runtime.rawValue)]: \(instruction)"
        )
      }
    }
    lines.append(
      "- Outside current proposed requirements (not implicitly adopted): "
        + (outsideProposedRequirements.isEmpty
          ? "none"
          : outsideProposedRequirements.compactMap { $0.identity?.key }.joined(separator: ", ")))
    for package in unresolvedInstallations {
      lines.append(
        "- Unresolved \(package.kind.rawValue):\(package.token): \(package.issue ?? "unknown identity")"
      )
    }
    for retained in retainedAdoptionsOutsideProposed {
      lines.append(
        "- Retained adoption outside current declarations: \(retained.entry.identity.key) [\(retained.status)]; no prune authorized."
      )
    }
    if let adoptionIssue { lines.append("- Adoption evidence unavailable: \(adoptionIssue)") }
    if let installation {
      lines.append(
        "- Last package installation [\(installation.phase.rawValue)]: \(installation.targets.joined(separator: ", ")); native exit \(installation.nativeExit.map(String.init) ?? "unknown")."
      )
      if installation.phase == .running {
        lines.append(
          "  - Run setup install-packages --recover; no automatic Homebrew retry or rollback.")
      }
      if !installation.diagnostic.isEmpty { lines.append("  - \(installation.diagnostic)") }
    }
    if let installationIssue {
      lines.append("- Installation evidence unavailable: \(installationIssue)")
    }
    lines += observation.issues.map { "- Inventory unavailable: \($0)" }
    lines.append(
      "Effective Brewfile (declaration intent, not full-install approval):\n\(effectiveBrewfile)")
    return lines.joined(separator: "\n")
  }

  /// These are the selection fields used by DependencyProfile, not a second
  /// package catalog. Package identity always comes from typed remediation.
  private static func selectionField(for capabilityID: String) -> String? {
    switch capabilityID {
    case "skhd", "yabai": "desktop.provider"
    case "sketchybar": "top_bar.provider"
    case "borders": "focus_ring.provider"
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
