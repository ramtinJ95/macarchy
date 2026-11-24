import Foundation
import ThemeCore

/// Guided intent feeds the existing planner and lifecycle; it is not a second installer.
enum UnifiedSetupNativeStarters {
  static func profilePath(
    _ provider: EnvironmentNativeSeed.Provider, context: UnifiedSetupPlanContext
  ) -> String {
    let base = context.profileURL.deletingLastPathComponent().resolvingSymlinksInPath()
      .pathComponents
    let target = provider.standardURL(homeDirectory: context.homeDirectory).pathComponents
    let common = zip(base, target).prefix { $0 == $1 }.count
    return (Array(repeating: "..", count: base.count - common) + target.dropFirst(common))
      .joined(separator: "/")
  }

  static func prepare(
    context: UnifiedSetupPlanContext, profile: PortableProfile, theme: ThemePackage,
    forTeardown: Bool = false
  ) throws -> [EnvironmentNativeSeed] {
    let providers: [EnvironmentNativeSeed.Provider]
    if forTeardown {
      // User-owned starter edits (or already-restored originals) need not still
      // implement apply's theme seams. The real teardown preflights receipts and
      // retained originals, and preserves the current entry before restoration.
      let records = try SetupNativeReplacement(
        homeDirectory: context.homeDirectory, stateRoot: context.stateRoot
      ).read().records
      providers = EnvironmentNativeSeed.Provider.allCases.filter { provider in
        records.contains { $0.proposal.provider == provider && $0.phase != .cancelled }
          && provider.isEnabled(in: profile.environment)
          && provider.source(in: profile.environment)?.path
            == provider.standardURL(homeDirectory: context.homeDirectory).path
      }
    } else {
      providers = context.nativeStarterProviders
    }
    guard !providers.isEmpty else { return [] }
    let ownership = try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership()
    let palette =
      providers.contains(.starship)
      ? Data(StarshipAdapter.render(package: theme).utf8) : nil
    return try providers.map { provider in
      let expected = reviewedDestination(provider, context: context, profile: profile)
      guard provider.isEnabled(in: profile.environment),
        provider.source(in: profile.environment)?.path == expected.path
      else {
        throw EnvironmentLifecycleError.blocked(
          "Machine intent overrides the guided \(provider.rawValue) starter; review the profiles before applying."
        )
      }
      guard ownership?.records.contains(where: { $0.id == provider.entryID }) != true else {
        throw EnvironmentLifecycleError.blocked(
          "\(provider.rawValue) is already managed; use its reviewed native connection/migration instead of fresh onboarding."
        )
      }
      return EnvironmentNativeSeed(
        provider: provider, destination: expected, homeDirectory: context.homeDirectory,
        stateRoot: context.stateRoot, resourcesRoot: context.environmentResourcesRoot,
        bootstrapPalette: palette, createParentDirectory: !forTeardown,
        replacement: forTeardown ? nil : context.nativeReplacementProposals[provider.rawValue],
        restorationPreview: forTeardown)
    }
  }

  static func pendingProviders(
    context: UnifiedSetupPlanContext, profile: PortableProfile
  ) throws -> [EnvironmentNativeSeed.Provider] {
    let ownership = try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership()
    return EnvironmentNativeSeed.Provider.allCases.filter { provider in
      let expected = reviewedDestination(provider, context: context, profile: profile)
      return provider.isEnabled(in: profile.environment)
        && provider.source(in: profile.environment)?.path == expected.path
        && !(ownership?.standardNativeEntries?.contains(provider.entryID) ?? false)
        && (!FileManager.default.fileExists(atPath: expected.path)
          || SetupNativeReplacement.providers.contains(provider))
    }
  }

  static func proposedFiles(_ plans: [EnvironmentNativeSeed.Plan]) -> [URL: Data] {
    var files: [URL: Data] = [:]
    for plan in plans {
      let destination = URL(filePath: plan.destination)
      if plan.provider == EnvironmentNativeSeed.Provider.neovim.rawValue {
        for (path, data) in plan.files {
          files[destination.appending(path: String(path.dropFirst("neovim/".count)))] = data
        }
      } else {
        files[destination] = Data(plan.contents.utf8)
      }
    }
    return files
  }

  private static func reviewedDestination(
    _ provider: EnvironmentNativeSeed.Provider, context: UnifiedSetupPlanContext,
    profile: PortableProfile
  ) -> URL {
    // Resume a retained v0.9.6 questionnaire without rewriting its chosen paths.
    // This exception recognizes only that release's exact generated destination.
    let parent = context.profileURL.deletingLastPathComponent()
    let directory =
      parent.standardizedFileURL.path == context.stateRoot.standardizedFileURL.path
      ? "../macarchy-user" : "native"
    let filename: String
    switch provider {
    case .zsh: filename = "zshrc"
    case .kitty: filename = "kitty.conf"
    case .atuin: filename = "atuin.toml"
    case .starship: filename = "starship.toml"
    case .neovim: filename = "neovim"
    }
    let legacy = parent.appending(path: directory).appending(path: filename).standardizedFileURL
    return provider.source(in: profile.environment)?.path == legacy.path
      ? legacy : provider.standardURL(homeDirectory: context.homeDirectory)
  }
}
