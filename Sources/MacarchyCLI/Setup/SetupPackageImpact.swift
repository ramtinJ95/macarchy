import Foundation

struct SetupPackageImpact: Encodable, Sendable {
  struct Dependency: Codable, Sendable {
    let name: String
    let version: String
    let installed: Bool
    let linked: Bool
  }

  struct FormulaEvidence: Codable, Sendable {
    let name: String
    let status: String
    var version: String? = nil
    var url: String? = nil
    var path: String? = nil
    var installed: Bool? = nil
    var current: Bool? = nil
    var linked: Bool? = nil
    var dependencies: [Dependency]? = nil
    var issue: String? = nil
  }

  struct Package: Encodable, Sendable {
    let identity: HomebrewPackageIdentity
    let status: String
    let evidence: ResolvedFormula?
    let issue: String?
  }

  struct ResolvedFormula: Encodable, Sendable {
    let name: String
    let version: String
    let installed: Bool
    let current: Bool
    let linked: Bool
    let dependencies: [Dependency]
  }

  let status: String
  let packages: [Package]
  let issue: String?
  let authority = "preview_only_no_mutation_or_adoption"
  let scope = "native_formula_dependency_candidates"
  let qualifiedHomebrewRevision = HomebrewFormulaResolver.revision
  let qualifiedHomebrewVersion = HomebrewFormulaResolver.version
  let limitations = [
    "Not a complete install effect plan: conflicts, dependent repair and apply-time revalidation are unqualified.",
    "Pending dependencies may require installation, upgrade or repair; no existing dependency is adopted.",
    "Runtime executables and recorded tap identities remain separate inventory evidence.",
    "Casks, third-party taps, source builds and other Homebrew revisions are unsupported.",
  ]

  init(
    identities: [HomebrewPackageIdentity], evidence: [FormulaEvidence] = [], issue: String? = nil
  ) {
    self.issue = issue
    status = issue == nil ? "partial" : "unavailable"
    packages = identities.map { identity in
      guard Self.supports(identity) else {
        return Package(
          identity: identity, status: "unsupported", evidence: nil,
          issue:
            "Only official bottled formulae are qualified; no tap or trust acquisition attempted."
        )
      }
      let matches = evidence.filter { $0.name == identity.name }
      guard matches.count == 1, let result = matches.first else {
        return Package(
          identity: identity, status: "incomplete", evidence: nil,
          issue: issue ?? "Missing or duplicate native formula result."
        )
      }
      guard result.status == "resolved_dependencies", result.issue == nil,
        let version = result.version, !version.isEmpty,
        let installed = result.installed, let current = result.current, let linked = result.linked,
        let dependencies = result.dependencies,
        dependencies.allSatisfy({
          HomebrewPackageIdentity.validToken($0.name) && !$0.version.isEmpty
        }),
        Set(dependencies.map(\.name)).count == dependencies.count
      else {
        return Package(
          identity: identity, status: "incomplete", evidence: nil,
          issue: result.issue ?? "Invalid or incomplete native formula result."
        )
      }
      return Package(
        identity: identity, status: "resolved_dependencies",
        evidence: ResolvedFormula(
          name: result.name, version: version, installed: installed, current: current,
          linked: linked, dependencies: dependencies
        ), issue: nil
      )
    }
  }

  static func supports(_ identity: HomebrewPackageIdentity) -> Bool {
    identity.kind == .formula && HomebrewPackageIdentity.validToken(identity.name)
  }

  var humanOutput: String {
    var lines = ["Package impact [\(status); preview only, no installation/adoption authority]:"]
    if let issue { lines.append("- \(issue)") }
    lines += limitations.map { "- \($0)" }
    for package in packages {
      lines.append("- \(package.identity.key): \(package.status)")
      if let issue = package.issue { lines.append("  \(issue)") }
      if let evidence = package.evidence {
        lines.append(
          "  Candidate \(evidence.version); current version installed: \(evidence.current)."
        )
        let pending = evidence.dependencies
        if pending.isEmpty { lines.append("  Native dependency check: no pending dependencies.") }
        for dependency in pending {
          lines.append(
            "  Pending \(dependency.name) \(dependency.version); existing installation: \(dependency.installed); linked: \(dependency.linked)."
          )
        }
      }
    }
    return lines.joined(separator: "\n")
  }
}
