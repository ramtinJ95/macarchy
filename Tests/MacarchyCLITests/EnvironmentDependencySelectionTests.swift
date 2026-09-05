import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

struct EnvironmentDependencySelectionTests {
  @Test(arguments: [false, true])
  func disabledAndShellOnlyKeepDistinctPlatformRequirements(shellEnabled: Bool) throws {
    let (catalog, profile) = try selection(
      core: false,
      shell: shellEnabled ? "zsh" : "disabled"
    )
    #expect(
      catalog.selectedForEnvironment(profile).map(\.id)
        == (shellEnabled ? ["macos-26", "arm64"] : [])
    )
  }

  @Test(arguments: [false, true])
  func coreAndAllPresetsKeepCatalogOrder(allPresets: Bool) throws {
    let (catalog, profile) = try selection(
      core: true,
      presets: allPresets ? Self.presetNames : []
    )
    let expected =
      allPresets
      ? [
        "macos-26", "arm64", "kitty", "atuin", "bat", "btop", "codex", "eza",
        "herdr", "neovim", "pi", "slack", "starship", "tuicr", "yazi", "spicetify", "spotify",
      ]
      : ["macos-26", "arm64", "kitty", "atuin", "bat", "btop", "eza", "neovim", "starship", "yazi"]
    #expect(catalog.selectedForEnvironment(profile).map(\.id) == expected)
    #expect(
      DependencyProfile(capabilities: catalog.capabilities.reversed())
        .selectedForEnvironment(profile).map(\.id) == Array(expected.reversed())
    )
  }

  @Test(arguments: 0..<64)
  func optionalCombinationsKeepManualSlackAndSpotifyDependencies(mask: Int) throws {
    let presets = Self.presetNames.enumerated().compactMap { index, name in
      mask & (1 << index) != 0 ? name : nil
    }
    let (catalog, profile) = try selection(core: false, presets: presets)
    let expected =
      (presets.isEmpty ? [] : ["macos-26", "arm64"])
      + ["codex", "herdr", "pi", "slack", "tuicr", "spicetify"].filter { presets.contains($0) }
      + (presets.contains("spicetify") ? ["spotify"] : [])
    #expect(catalog.selectedForEnvironment(profile).map(\.id) == expected)
  }

  private static let presetNames = ["codex", "herdr", "pi", "slack", "spicetify", "tuicr"]

  private func selection(
    core: Bool,
    shell: String = "disabled",
    presets: [String] = []
  ) throws -> (DependencyProfile, EnvironmentProfile) {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-environment-dependency-selection-tests-\(UUID().uuidString)"
    )
    let optOuts = """
      [terminal]
      provider = "disabled"
      [shell]
      provider = "\(shell)"
      [prompt]
      provider = "disabled"
      [history]
      provider = "disabled"
      [editor]
      provider = "disabled"
      [tools]
      bat = false
      btop = false
      eza = false
      yazi = false
      """
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n" + (core ? "" : optOuts) + "\n[presets]\n"
        + presets.map { "\($0) = true\n" }.joined(),
      source: home.appending(path: "profile.toml")
    )
    return (DependencyProfile.personal(homeDirectory: home), profile.environment)
  }
}
