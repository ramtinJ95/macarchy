import Foundation
import ThemeCore

/// Package intent only. This compiler neither evaluates Ruby nor inspects or
/// changes Homebrew state. Provider requirements are validated after layering.
struct SetupPackageDeclarations: Encodable, Sendable {
  struct Package: Encodable, Sendable {
    let identity: HomebrewPackageIdentity
    let sources: [SetupPackageAdoptionLedger.Declaration]
  }
  struct Exclusion: Encodable, Sendable {
    let identity: HomebrewPackageIdentity
    let source: SetupPackageAdoptionLedger.Declaration
  }
  struct Tap: Encodable, Sendable {
    let name: String
    let sources: [SetupPackageAdoptionLedger.Declaration]
    let status = "acquisition_and_trust_not_inspected"
  }

  let baseline: PackageBaseline
  let packages: [Package]
  let exclusions: [Exclusion]
  let taps: [Tap]

  static let empty = Self(baseline: .standard, packages: [], exclusions: [], taps: [])

  static func compile(
    standard: SetupBrewfile, profile: PackageProfile, requirements: [SetupCapability]
  ) throws -> Self {
    guard profile.baseline != .personal || profile.layers.contains(where: { $0.brewfileURL != nil })
    else {
      throw SetupPackageAdoptionError(
        "packages.baseline = \"personal\" requires an explicit packages.brewfile.")
    }
    let stock = SetupPackageAdoptionLedger.Declaration(
      source: "standard_baseline", layer: "built_in", sourcePath: nil, selectionField: nil)
    var selected: [HomebrewPackageIdentity: [SetupPackageAdoptionLedger.Declaration]] = [:]
    var excluded: [HomebrewPackageIdentity: SetupPackageAdoptionLedger.Declaration] = [:]
    var taps: [String: [SetupPackageAdoptionLedger.Declaration]] = [:]
    if profile.baseline == .standard {
      for identity in standard.packages { selected[identity] = [stock] }
      for name in standard.taps { taps[name] = [stock] }
    }
    for layer in profile.layers {
      let additions =
        try layer.brewfileURL.map { try SetupBrewfile.read(at: $0) }
        ?? SetupBrewfile(packages: [])
      let targets =
        layer.excludedFormulae.map { "formula:" + $0 }
        + layer.excludedCasks.map { "cask:" + $0 }
      let exclusions: [HomebrewPackageIdentity]
      do {
        exclusions =
          targets.isEmpty ? [] : try SetupPackageAdoptionCommandRunner.parseTargets(targets)
      } catch {
        throw SetupPackageAdoptionError("Package exclusions in \(layer.sourceURL.path): \(error)")
      }
      if let conflict = Set(additions.packages).intersection(exclusions).sorted(by: {
        $0.key < $1.key
      }).first {
        throw SetupPackageAdoptionError(
          "\(layer.sourceURL.path) both adds and excludes \(conflict.key). A higher layer cannot hide this contradiction."
        )
      }
      for identity in exclusions {
        selected.removeValue(forKey: identity)
        excluded[identity] = .init(
          source: "package_exclusion", layer: layer.kind.rawValue,
          sourcePath: layer.sourceURL.path,
          selectionField: identity.kind == .formula
            ? "packages.exclude_formulae" : "packages.exclude_casks")
      }
      if let url = layer.brewfileURL {
        let source = SetupPackageAdoptionLedger.Declaration(
          source: "personal_brewfile", layer: layer.kind.rawValue, sourcePath: url.path,
          selectionField: "packages.brewfile")
        for identity in additions.packages {
          excluded.removeValue(forKey: identity)
          selected[identity, default: []].append(source)
        }
        for name in additions.taps { taps[name, default: []].append(source) }
      }
    }
    for requirement in requirements.sorted(by: { $0.id < $1.id }) {
      if let identity = requirement.remediation.homebrewPackage, let exclusion = excluded[identity]
      {
        throw SetupPackageAdoptionError(
          "\(exclusion.sourcePath ?? exclusion.layer) excludes required \(identity.key) (\(requirement.id)). Change or disable the selected provider first."
        )
      }
    }
    let identities = Set(selected.keys).union(excluded.keys)
      .union(requirements.compactMap { $0.remediation.homebrewPackage })
    guard identities.count <= 1024, taps.count <= 1024 else {
      throw SetupPackageAdoptionError(
        "Effective package intent exceeds 1024 package decisions or taps.")
    }
    return Self(
      baseline: profile.baseline,
      packages: selected.sorted { $0.key.key < $1.key.key }.map {
        .init(identity: $0.key, sources: $0.value)
      },
      exclusions: excluded.sorted { $0.key.key < $1.key.key }.map {
        .init(identity: $0.key, source: $0.value)
      },
      taps: taps.sorted { $0.key < $1.key }.map { .init(name: $0.key, sources: $0.value) })
  }
}
