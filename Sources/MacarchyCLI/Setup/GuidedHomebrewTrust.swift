import Foundation
import ThemeCore

/// Native trust is separate from package installation approval, and guided-only.
struct GuidedHomebrewTrust: Sendable {
  let missing: @Sendable ([HomebrewPackageIdentity]) throws -> [HomebrewPackageIdentity]
  let grant: @Sendable (HomebrewPackageIdentity) throws -> Void

  static func live(homeDirectory: URL, runner: ProcessRunner = .live) -> Self {
    @Sendable func run(_ arguments: [String]) throws -> String {
      try HomebrewBundleInstaller.validateConfiguration(homeDirectory: homeDirectory)
      let result = try runner.run(
        .init(
          executableURL: URL(filePath: "/usr/bin/env"),
          arguments: HomebrewBundleInstaller.nativeArguments(
            homeDirectory: homeDirectory, arguments: arguments), timeout: 30))
      guard result.terminationStatus == 0 else {
        throw SetupPackageAdoptionError("Homebrew trust failed: \(result.output)")
      }
      return result.output
    }
    return Self(
      missing: { packages in
        let selected = packages.filter { $0.kind == .formula && $0.tap != nil }
        guard !selected.isEmpty else { return [] }
        struct Trust: Decodable {
          let taps: [String]
          let formulae: [String]
        }
        let state = try JSONDecoder().decode(
          Trust.self, from: Data(run(["trust", "--json=v1"]).utf8))
        return selected.filter { package in
          !state.formulae.contains(package.name) && !state.taps.contains(package.tap!)
        }.sorted { $0.key < $1.key }
      },
      grant: { package in
        guard package.kind == .formula, package.tap != nil else {
          throw SetupPackageAdoptionError("Guided trust requires an exact third-party formula.")
        }
        _ = try SetupPackageAdoptionCommandRunner.parseTargets([package.key])
        _ = try run(["trust", "--formula", package.name])
      })
  }
}
