import Foundation
import ThemeCore

/// Guided intent feeds the existing planner and lifecycle; it is not a second installer.
enum UnifiedSetupNativeStarters {
  static func relativeDirectory(context: UnifiedSetupPlanContext) -> String {
    context.profileURL.deletingLastPathComponent().standardizedFileURL.path
      == context.stateRoot.standardizedFileURL.path ? "../macarchy-user" : "native"
  }

  static func destination(
    _ provider: EnvironmentNativeSeed.Provider, context: UnifiedSetupPlanContext
  ) -> URL {
    context.profileURL.deletingLastPathComponent()
      .appending(path: relativeDirectory(context: context))
      .appending(path: provider.starterName).standardizedFileURL
  }

  static func prepare(
    context: UnifiedSetupPlanContext, profile: PortableProfile, theme: ThemePackage
  ) throws -> [EnvironmentNativeSeed] {
    guard !context.nativeStarterProviders.isEmpty else { return [] }
    let ownership = try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership()
    let palette =
      context.nativeStarterProviders.contains(.starship)
      ? Data(StarshipAdapter.render(package: theme).utf8) : nil
    return try context.nativeStarterProviders.map { provider in
      let expected = destination(provider, context: context)
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
        bootstrapPalette: palette, createParentDirectory: true)
    }
  }

  static func pendingProviders(
    context: UnifiedSetupPlanContext, profile: PortableProfile
  ) -> [EnvironmentNativeSeed.Provider] {
    EnvironmentNativeSeed.Provider.allCases.filter { provider in
      let expected = destination(provider, context: context)
      return provider.isEnabled(in: profile.environment)
        && provider.source(in: profile.environment)?.path == expected.path
        && !FileManager.default.fileExists(atPath: expected.path)
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
}
