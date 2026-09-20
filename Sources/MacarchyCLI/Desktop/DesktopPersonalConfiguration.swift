import Foundation
import ThemeCore

enum DesktopPersonalProvider: String, Sendable {
  case yabai, sketchybar

  func source(in profile: PortableProfile) -> URL? {
    self == .yabai ? profile.desktop.yabai.configurationURL : profile.sketchyBar.configurationURL
  }

  func legacyHook(in profile: PortableProfile) -> URL? {
    self == .yabai ? profile.desktop.yabai.hookURL : profile.sketchyBar.hookURL
  }

  func compose(
    profile: PortableProfile, context: UnifiedSetupPlanContext,
    includePersonalConfiguration: Bool = true
  ) throws
    -> DesktopPersonalComposition
  {
    let defaults = context.desktopResourcesRoot.appending(path: "\(rawValue)/defaults.toml")
    switch self {
    case .yabai:
      return .yabai(
        try YabaiConfigurationComposer().compose(
          defaultsURL: defaults, profile: profile,
          macarchyExecutableURL: RuntimeEnvironment.live.persistentCommandURL,
          includePersonalConfiguration: includePersonalConfiguration))
    case .sketchybar:
      return .sketchybar(
        try SketchyBarConfigurationComposer().compose(
          defaultsURL: defaults, profile: profile, stateRoot: context.stateRoot,
          macarchyExecutableURL: RuntimeEnvironment.live.persistentCommandURL,
          includePersonalConfiguration: includePersonalConfiguration))
    }
  }

  // Excluding the personal file keeps even invalid pending edits repairable.
  // An older manifest's full input digest proves a baseline only when it matches
  // the hook-free inputs; otherwise scoped activation must request reviewed apply.
  func inputsMatchGeneration(
    profile: PortableProfile, context: UnifiedSetupPlanContext,
    excludingPersonalConfiguration: Bool = false
  ) throws -> Bool {
    switch try compose(
      profile: profile, context: context,
      includePersonalConfiguration: !excludingPersonalConfiguration)
    {
    case .yabai(let composition):
      guard let manifest = YabaiGenerationInspector(stateRoot: context.stateRoot).inspect().manifest
      else { return false }
      if excludingPersonalConfiguration {
        return composition.baselineInputDigest
          == (manifest.baselineInputDigest ?? manifest.inputDigest)
      }
      return manifest.inputDigest == composition.inputDigest
        && manifest.renderedDigest == composition.renderedDigest
    case .sketchybar(let composition):
      guard
        let manifest = SketchyBarGenerationInspector(stateRoot: context.stateRoot).inspect()
          .manifest
      else { return false }
      if excludingPersonalConfiguration {
        return composition.baselineInputDigest
          == (manifest.baselineInputDigest ?? manifest.inputDigest)
      }
      return manifest.inputDigest == composition.inputDigest
        && manifest.renderedDigest == composition.renderedDigest
    }
  }

  /// Menu editing cannot install, adopt, switch, tear down, or recover providers.
  func managedGeneration(profile: PortableProfile, context: UnifiedSetupPlanContext) throws
    -> String
  {
    guard try !DesktopAggregateTransactionStore(stateRoot: context.stateRoot).exists,
      try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read() == nil
    else {
      throw EnvironmentLifecycleError.blocked("recover the pending desktop/setup transaction first")
    }
    switch self {
    case .yabai:
      let generation = YabaiGenerationInspector(stateRoot: context.stateRoot).inspect()
      guard profile.desktop.provider == .yabaiSkhd,
        !YabaiTransactionStore(stateRoot: context.stateRoot).exists,
        generation.status == .current, let id = generation.generationID,
        YabaiProviderPlanInspector().inspect(
          homeDirectory: context.homeDirectory, stateRoot: context.stateRoot, enabled: true
        ).status == .managed,
        try YabaiOwnershipStore(stateRoot: context.stateRoot).read()?.generationID == id
      else {
        throw EnvironmentLifecycleError.blocked(
          "Configure requires an existing managed yabai connection without pending recovery")
      }
      return id
    case .sketchybar:
      let generation = SketchyBarGenerationInspector(stateRoot: context.stateRoot).inspect()
      guard profile.topBar == .sketchybar,
        !SketchyBarTransactionStore(stateRoot: context.stateRoot).exists,
        generation.status == .current, let id = generation.generationID,
        SketchyBarProviderPlanInspector().inspect(
          homeDirectory: context.homeDirectory, stateRoot: context.stateRoot,
          enabled: true, generation: generation
        ).status == .managed,
        try SketchyBarOwnershipStore(stateRoot: context.stateRoot).read()?.generationID == id
      else {
        throw EnvironmentLifecycleError.blocked(
          "Configure requires an existing managed SketchyBar connection without pending recovery")
      }
      return id
    }
  }
}

enum DesktopPersonalComposition {
  case yabai(YabaiComposition)
  case sketchybar(SketchyBarComposition)
}
