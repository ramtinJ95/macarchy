import Foundation
import Testing

@testable import ThemeCore

struct YabaiConfigurationTests {
  private let composer = YabaiConfigurationComposer()

  @Test
  func packagedDefaultsRenderDeterministically() throws {
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: URL(filePath: "/fixtures/profile.toml")
    )

    let first = try composer.compose(defaultsURL: defaultsURL, profile: profile)
    let second = try composer.compose(defaultsURL: defaultsURL, profile: profile)

    #expect(first == second)
    #expect(first.renderedConfiguration.hasSuffix("\n"))
    #expect(first.renderedConfiguration.contains(#""$YABAI" -m config layout bsp"#))
    #expect(
      first.renderedConfiguration.contains(
        #""$YABAI" -m rule --add app='^System Settings$' manage=off"#
      )
    )
    #expect(first.renderedConfiguration.contains("external_bar all:35:0"))
    #expect(first.renderedConfiguration.contains("label=macarchy-wallpaper"))
    #expect(first.renderedDigest.hasPrefix("sha256:"))
    #expect(first.inputDigest.hasPrefix("sha256:"))
  }

  @Test
  func portableOverridesAndTrustedHookProduceSelfContainedBytes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let hook = root.appending(path: "personal-yabai.sh")
    try """
    "$YABAI" -m rule --add app='^Personal App$' manage=off
    """.write(to: hook, atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [desktop]
      provider = "yabai-skhd"
      [yabai]
      layout = "stack"
      split_ratio = 0.6
      window_gap = 12
      mouse_follows_focus = false
      hook = "personal-yabai.sh"
      [top_bar]
      provider = "disabled"
      """,
      source: root.appending(path: "profile.toml")
    )

    let composition = try composer.compose(defaultsURL: defaultsURL, profile: profile)

    #expect(composition.settings.layout == "stack")
    #expect(composition.settings.splitRatio == 0.6)
    #expect(composition.settings.windowGap == 12)
    #expect(!composition.settings.mouseFollowsFocus)
    #expect(composition.hookURL == hook)
    #expect(composition.hookDigest?.hasPrefix("sha256:") == true)
    #expect(composition.renderedConfiguration.contains("layout stack"))
    #expect(composition.renderedConfiguration.contains("window_gap 12"))
    #expect(composition.renderedConfiguration.contains("Begin trusted user hook"))
    #expect(composition.renderedConfiguration.contains("^Personal App$"))
    #expect(!composition.renderedConfiguration.contains("external_bar"))
  }

  @Test
  func invalidPackagedShapeAndMissingHookFailClosed() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let invalidDefaults = root.appending(path: "defaults.toml")
    try """
    schema_version = 1
    layout = "bsp"
    unknown = true
    """.write(to: invalidDefaults, atomically: true, encoding: .utf8)
    let defaultProfile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: YabaiConfigurationError.self) {
      _ = try composer.compose(defaultsURL: invalidDefaults, profile: defaultProfile)
    }

    let missingHookProfile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [yabai]
      hook = "missing.sh"
      """,
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: YabaiConfigurationError.self) {
      _ = try composer.compose(defaultsURL: defaultsURL, profile: missingHookProfile)
    }
  }

  private var defaultsURL: URL {
    repositoryRoot.appending(path: "Desktop/yabai/defaults.toml")
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-yabai-configuration-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
