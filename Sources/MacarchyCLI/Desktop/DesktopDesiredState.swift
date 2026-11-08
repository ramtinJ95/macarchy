import Foundation
import ThemeCore

/// The profile and the provider configurations it selects. Plan, apply, status, doctor and
/// personal-configuration editing compose each provider through the functions below.
struct DesktopDesiredState: Sendable {
  let profile: PortableProfile
  let yabaiComposition: YabaiComposition?
  let sketchyBarComposition: SketchyBarComposition?

  static func load(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    macarchyExecutableURL: URL = RuntimeEnvironment.live.persistentCommandURL,
    profile suppliedProfile: PortableProfile? = nil,
    scope: DesktopProviderScope = .allProviders
  ) throws -> Self {
    let profile =
      try suppliedProfile
      ?? PortableProfileLoader().load(at: profileURL, required: profileRequired)
    let yabaiComposition: YabaiComposition? =
      if profile.desktop.provider == .yabaiSkhd {
        try composeYabai(
          resourcesRoot: resourcesRoot,
          profile: profile,
          macarchyExecutableURL: macarchyExecutableURL
        )
      } else {
        nil
      }
    let sketchyBarComposition: SketchyBarComposition? =
      if scope == .allProviders, profile.topBar == .sketchybar {
        try composeSketchyBar(
          resourcesRoot: resourcesRoot,
          profile: profile,
          stateRoot: stateRoot,
          macarchyExecutableURL: macarchyExecutableURL
        )
      } else {
        nil
      }
    return Self(
      profile: profile,
      yabaiComposition: yabaiComposition,
      sketchyBarComposition: sketchyBarComposition
    )
  }

  static func yabaiDefaultsURL(resourcesRoot: URL) -> URL {
    resourcesRoot.appending(path: "yabai/defaults.toml")
  }

  static func sketchyBarDefaultsURL(resourcesRoot: URL) -> URL {
    resourcesRoot.appending(path: "sketchybar/defaults.toml")
  }

  static func composeYabai(
    resourcesRoot: URL,
    profile: PortableProfile,
    macarchyExecutableURL: URL,
    includePersonalConfiguration: Bool = true
  ) throws -> YabaiComposition {
    try YabaiConfigurationComposer().compose(
      defaultsURL: yabaiDefaultsURL(resourcesRoot: resourcesRoot),
      profile: profile,
      macarchyExecutableURL: macarchyExecutableURL,
      includePersonalConfiguration: includePersonalConfiguration
    )
  }

  static func composeSketchyBar(
    resourcesRoot: URL,
    profile: PortableProfile,
    stateRoot: URL,
    macarchyExecutableURL: URL,
    includePersonalConfiguration: Bool = true
  ) throws -> SketchyBarComposition {
    try SketchyBarConfigurationComposer().compose(
      defaultsURL: sketchyBarDefaultsURL(resourcesRoot: resourcesRoot),
      profile: profile,
      stateRoot: stateRoot,
      macarchyExecutableURL: macarchyExecutableURL,
      includePersonalConfiguration: includePersonalConfiguration
    )
  }
}
