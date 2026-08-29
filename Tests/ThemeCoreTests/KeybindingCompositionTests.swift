import Foundation
import Testing

@testable import ThemeCore

struct KeybindingCompositionTests {
  private let composer = KeybindingComposer()
  private let defaultsSource = URL(filePath: "/package/defaults.skhdrc")
  private let profileSource = URL(filePath: "/dotfiles/profile.toml")
  private let overrideSource = URL(filePath: "/dotfiles/personal.skhdrc")
  private let metadataSource = URL(filePath: "/dotfiles/personal-metadata.toml")

  @Test
  func replacesAddsDisablesAndAttributesCommandsAndMetadata() throws {
    let profile = KeybindingProfile(
      sourceURL: profileSource,
      overrideURL: overrideSource,
      metadataURL: metadataSource,
      disabledIdentities: ["alt-k"]
    )
    let result = composer.compose(
      defaultsText: "alt - j : focus south\nalt - k : focus north\n",
      defaultsSource: defaultsSource,
      defaultCatalog: try catalog([
        ("alt-j", "Focus below", 10),
        ("alt-k", "Focus above", 20),
      ]),
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: profile,
      overrideText: "cmd - x : open custom\nalt - j : replacement\n",
      userCatalog: try catalog([
        ("alt-j", "Personal focus", 1),
        ("cmd-x", "Open custom", 2),
      ])
    )

    #expect(!result.isBlocked)
    #expect(result.bindings.map(\.binding.identity) == ["alt-j", "cmd-x"])
    #expect(result.bindings.map(\.commandSource) == [.userReplacement, .userAddition])
    #expect(result.bindings.map(\.metadataSource) == [.userOverlay, .userOverlay])
    #expect(result.bindings[0].metadata?.label == "Personal focus")
    #expect(result.disabledDefaults.map(\.binding.identity) == ["alt-k"])
    #expect(
      result.renderedConfiguration
        == "alt - j : replacement\ncmd - x : open custom\n"
    )
    #expect(result.renderedDigest == sha256Digest(Data(result.renderedConfiguration!.utf8)))
    #expect(result.diagnostics.isEmpty)
  }

  @Test
  func renderingIsStableAcrossCommentsWhitespaceAndOverrideOrder() throws {
    let profile = KeybindingProfile(
      sourceURL: profileSource,
      overrideURL: overrideSource,
      metadataURL: nil,
      disabledIdentities: []
    )
    let defaults = "# comment\nalt - j : focus south\nalt - k : focus north\n"
    let metadata = try catalog([
      ("alt-j", "Focus below", 10),
      ("alt-k", "Focus above", 20),
    ])
    let first = composer.compose(
      defaultsText: defaults,
      defaultsSource: defaultsSource,
      defaultCatalog: metadata,
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: profile,
      overrideText: "cmd - x : first\ncmd - a : second\n",
      userCatalog: nil
    )
    let second = composer.compose(
      defaultsText: defaults.replacingOccurrences(of: "# comment\n", with: "\n# moved\n"),
      defaultsSource: defaultsSource,
      defaultCatalog: metadata,
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: profile,
      overrideText: "  cmd - a : second  \n# ignored\ncmd - x : first\n",
      userCatalog: nil
    )

    #expect(first.renderedConfiguration == second.renderedConfiguration)
    #expect(first.renderedDigest == second.renderedDigest)
    #expect(first.inputDigest == second.inputDigest)
    #expect(first.diagnostics.allSatisfy { $0.severity == .warning })
    #expect(second.diagnostics.allSatisfy { $0.severity == .warning })
  }

  @Test
  func metadataAndProvenanceChangeInputDigestWithoutChangingRenderedBytes() throws {
    let defaults = "alt - j : focus south\n"
    let packaged = try catalog([("alt-j", "Packaged label", 10)])
    let inherited = composer.compose(
      defaultsText: defaults,
      defaultsSource: defaultsSource,
      defaultCatalog: packaged,
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: .empty,
      overrideText: nil,
      userCatalog: nil
    )
    let overlaid = composer.compose(
      defaultsText: defaults,
      defaultsSource: defaultsSource,
      defaultCatalog: packaged,
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: KeybindingProfile(
        sourceURL: profileSource,
        overrideURL: nil,
        metadataURL: metadataSource,
        disabledIdentities: []
      ),
      overrideText: nil,
      userCatalog: try catalog([("alt-j", "Personal label", 10)])
    )

    #expect(inherited.renderedConfiguration == overlaid.renderedConfiguration)
    #expect(inherited.renderedDigest == overlaid.renderedDigest)
    #expect(inherited.inputDigest != overlaid.inputDigest)
  }

  @Test
  func unknownAndContradictoryDisablesBlockRendering() throws {
    let metadata = try catalog([("alt-j", "Focus below", 10)])
    let unknown = composer.compose(
      defaultsText: "alt - j : default\n",
      defaultsSource: defaultsSource,
      defaultCatalog: metadata,
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: KeybindingProfile(
        sourceURL: profileSource,
        overrideURL: nil,
        metadataURL: nil,
        disabledIdentities: ["alt-k"]
      ),
      overrideText: nil,
      userCatalog: nil
    )
    let contradiction = composer.compose(
      defaultsText: "alt - j : default\n",
      defaultsSource: defaultsSource,
      defaultCatalog: metadata,
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: KeybindingProfile(
        sourceURL: profileSource,
        overrideURL: overrideSource,
        metadataURL: nil,
        disabledIdentities: ["alt-j"]
      ),
      overrideText: "alt - j : replacement\n",
      userCatalog: nil
    )

    #expect(unknown.isBlocked)
    #expect(unknown.renderedConfiguration == nil)
    #expect(unknown.diagnostics.map(\.code) == ["unknown_disabled_identity"])
    #expect(contradiction.isBlocked)
    #expect(contradiction.diagnostics.map(\.code) == ["disabled_override_conflict"])
  }

  @Test
  func parserAndPackagedMetadataDefectsBlockBeforeMerge() throws {
    let duplicate = composer.compose(
      defaultsText: "alt - j : first\nalt - j : second\n",
      defaultsSource: defaultsSource,
      defaultCatalog: try catalog([("alt-j", "Focus below", 10)]),
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: .empty,
      overrideText: nil,
      userCatalog: nil
    )
    let missingMetadata = composer.compose(
      defaultsText: "alt - j : default\nalt - k : default\n",
      defaultsSource: defaultsSource,
      defaultCatalog: try catalog([("alt-j", "Focus below", 10)]),
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: .empty,
      overrideText: nil,
      userCatalog: nil
    )

    #expect(duplicate.isBlocked)
    #expect(duplicate.diagnostics.map(\.code) == ["duplicate_chord"])
    #expect(missingMetadata.isBlocked)
    #expect(missingMetadata.diagnostics.map(\.code) == ["packaged_metadata_missing"])
  }

  private func catalog(_ records: [(String, String, Int)]) throws -> SkhdKeybindingCatalog {
    var text = "schema_version = 1\n"
    for (identity, label, order) in records {
      text += """

        [[bindings]]
        identity = "\(identity)"
        label = "\(label)"
        category = "Test"
        order = \(order)
        """
    }
    return try SkhdKeybindingCatalogLoader().decode(
      text,
      source: URL(filePath: "/fixtures/metadata.toml")
    )
  }
}
