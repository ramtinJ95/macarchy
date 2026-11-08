import Foundation
import ThemeCore

enum DesktopPersonalProvider: String, Sendable {
  case yabai, sketchybar

  func source(in profile: PortableProfile) -> URL? { options(in: profile).configurationURL }

  func legacyHook(in profile: PortableProfile) -> URL? { options(in: profile).hookURL }

  private func options(in profile: PortableProfile) -> any DesktopPersonalSourceOptions {
    switch self {
    case .yabai: return profile.desktop.yabai
    case .sketchybar: return profile.sketchyBar
    }
  }

  func compose(
    profile: PortableProfile, context: UnifiedSetupPlanContext,
    includePersonalConfiguration: Bool = true
  ) throws
    -> DesktopPersonalComposition
  {
    switch self {
    case .yabai:
      return .yabai(
        try DesktopDesiredState.composeYabai(
          resourcesRoot: context.desktopResourcesRoot, profile: profile,
          macarchyExecutableURL: RuntimeEnvironment.live.persistentCommandURL,
          includePersonalConfiguration: includePersonalConfiguration))
    case .sketchybar:
      return .sketchybar(
        try DesktopDesiredState.composeSketchyBar(
          resourcesRoot: context.desktopResourcesRoot, profile: profile,
          stateRoot: context.stateRoot,
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
    let composition = try compose(
      profile: profile, context: context,
      includePersonalConfiguration: !excludingPersonalConfiguration)
    guard let manifest = composition.selectedGenerationDigests(stateRoot: context.stateRoot)
    else { return false }
    let composed = composition.digests
    if excludingPersonalConfiguration {
      return composed.baseline == (manifest.baseline ?? manifest.input)
    }
    return manifest.input == composed.input && manifest.rendered == composed.rendered
  }

  /// Menu editing cannot install, adopt, switch, tear down, or recover providers.
  func managedGeneration(profile: PortableProfile, context: UnifiedSetupPlanContext) throws
    -> String
  {
    guard
      try !DesktopAggregateTransactionStore.parentTransactionPending(stateRoot: context.stateRoot)
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

  fileprivate var digests: (input: String, rendered: String, baseline: String) {
    switch self {
    case .yabai(let value):
      (
        input: value.inputDigest, rendered: value.renderedDigest,
        baseline: value.baselineInputDigest
      )
    case .sketchybar(let value):
      (
        input: value.inputDigest, rendered: value.renderedDigest,
        baseline: value.baselineInputDigest
      )
    }
  }

  /// The digests recorded by this provider's selected generation, if one is readable.
  fileprivate func selectedGenerationDigests(stateRoot: URL)
    -> (input: String, rendered: String, baseline: String?)?
  {
    switch self {
    case .yabai:
      YabaiGenerationInspector(stateRoot: stateRoot).inspect().manifest.map {
        (input: $0.inputDigest, rendered: $0.renderedDigest, baseline: $0.baselineInputDigest)
      }
    case .sketchybar:
      SketchyBarGenerationInspector(stateRoot: stateRoot).inspect().manifest.map {
        (input: $0.inputDigest, rendered: $0.renderedDigest, baseline: $0.baselineInputDigest)
      }
    }
  }
}
