import CryptoKit
import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct MacOSIconStyleSchemaTests {
  @Test func absentMacOSOptionsPreserveTheLegacyThemeDigest() throws {
    try withTemporaryRoot(named: "icon-style-legacy-digest") { root in
      let package = try BuiltInThemePackages.catppuccinMocha.get()
      let manifest = try ThemeActivator(root: root).activate(package: package)
      let legacy = LegacyGenerationThemeInput(
        manifestSchemaVersion: GenerationManifest.currentSchemaVersion,
        themeSchemaVersion: package.schemaVersion, themeID: package.id,
        appearance: package.appearance, semantic: package.semantic, terminal: package.terminal,
        mappings: package.mappings, rendererVersions: manifest.rendererVersions)
      let digest = SHA256.hash(data: try prettyJSONDocument(legacy))
      #expect(
        manifest.themeDigest == "sha256:" + digest.map { String(format: "%02x", $0) }.joined())
    }
  }

  @Test(arguments: ThemeIconStyle.allCases)
  func optionalPackageFieldSurvivesMetadataAndNormalization(style: ThemeIconStyle) throws {
    try withTemporaryRoot(named: "icon-style-schema") { root in
      let packageURL = root.appending(path: "package")
      try FileManager.default.copyItem(
        at: repositoryRoot.appending(path: "Themes/catppuccin-mocha"), to: packageURL)
      let manifest = packageURL.appending(path: "theme.toml")
      let text = try String(contentsOf: manifest, encoding: .utf8)
      try (text + "\n[macos]\nicon_style = \"\(style.rawValue)\"\n").write(
        to: manifest, atomically: false, encoding: .utf8)
      let loader = ThemePackageLoader()
      let metadata = try loader.loadMetadata(packageURL: packageURL)
      #expect(metadata.macos?.iconStyle == style)
      #expect(try metadata.addingPersonalBackgrounds([]).macos?.iconStyle == style)
      let package = try loader.load(packageURL: packageURL)
      #expect(package.macos?.iconStyle == style)
      #expect(package.metadata.macos?.iconStyle == style)
      #expect(try package.addingPersonalBackgrounds([]).macos?.iconStyle == style)
      let normalized = NormalizedTheme(package: package, generationID: "fixture")
      let data = try JSONEncoder().encode(normalized)
      let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(json["schema_version"] as? Int == 1)
      #expect((json["macos"] as? [String: Any])?["icon_style"] as? String == style.rawValue)
      #expect(try JSONDecoder().decode(NormalizedTheme.self, from: data).macos?.iconStyle == style)
      let state = root.appending(path: "state")
      let generation = try ThemeActivator(root: state).activate(package: package)
      #expect(try generation.normalizedTheme(root: state).macos?.iconStyle == style)
    }
  }

  @Test(arguments: [
    ("[macos]\nicon_style = \"automatic\"", "macos.icon_style"),
    ("[macos]\niconStyle = \"dark\"", "macos.iconStyle"),
    ("[macos]\nextra = true", "macos.extra"),
    ("[[macos]]\nicon_style = \"dark\"", "macos"),
  ])
  func badValuesAndUnknownKeysAreSourceLocated(declaration: String, field: String) throws {
    try withTemporaryRoot(named: "icon-style-invalid") { root in
      let packageURL = root.appending(path: "package")
      try FileManager.default.copyItem(
        at: repositoryRoot.appending(path: "Themes/catppuccin-mocha"), to: packageURL)
      let manifest = packageURL.appending(path: "theme.toml")
      let original = try String(contentsOf: manifest, encoding: .utf8)
      try (original + "\n" + declaration + "\n").write(
        to: manifest, atomically: false, encoding: .utf8)
      do {
        _ = try ThemePackageLoader().load(packageURL: packageURL)
        Issue.record("Invalid icon style declaration was accepted")
      } catch let error as ThemeDiagnostic {
        #expect(error.field == field)
        #expect(error.location.file == manifest)
        #expect(error.location.line != nil)
      }
    }
  }

  @Test(arguments: ["icon_style = 1", "icon_style = true", "icon_style = [\"dark\"]"])
  func nonStringStylesAreRejected(declaration: String) throws {
    try withTemporaryRoot(named: "icon-style-wrong-type") { root in
      let packageURL = root.appending(path: "package")
      try FileManager.default.copyItem(
        at: repositoryRoot.appending(path: "Themes/catppuccin-mocha"), to: packageURL)
      let manifest = packageURL.appending(path: "theme.toml")
      let original = try String(contentsOf: manifest, encoding: .utf8)
      try (original + "\n[macos]\n" + declaration + "\n").write(
        to: manifest, atomically: false, encoding: .utf8)
      #expect(throws: ThemeDiagnostic.self) {
        try ThemePackageLoader().load(packageURL: packageURL)
      }
    }
  }

  @Test func legacyPackagesAndGenerationsLeaveStyleUnset() async throws {
    let package = try BuiltInThemePackages.catppuccinMocha.get()
    #expect(package.macos == nil)
    let data = try JSONEncoder().encode(NormalizedTheme(package: package, generationID: "legacy"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["macos"] == nil)
    #expect(try JSONDecoder().decode(NormalizedTheme.self, from: data).macos == nil)
    try await withTemporaryRoot(named: "icon-style-unset") { root in
      _ = try ThemeActivator(root: root).activate(package: package)
      let fake = ProcessRunnerFake(status: 99, output: "must not call the helper")
      let adapter = MacOSIconStyleAdapter(
        root: root,
        helper: MacOSLookHelper(
          executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner))
      #expect(adapter.inspection().message == "theme does not set an icon style")
      let result = try await adapter.reconciliation().run()
      #expect(result.message == "theme does not set an icon style")
      #expect(fake.requests.isEmpty)
      #expect(try MacOSIconStyleStore(root: root).load() == nil)
    }
  }

  @Test(arguments: [
    (ThemeIconStyle.default, ThemeAppearance.light, "RegularLight"),
    (.default, .dark, "RegularLight"), (.dark, .light, "RegularDark"),
    (.dark, .dark, "RegularDark"), (.clear, .light, "ClearLight"),
    (.clear, .dark, "ClearDark"), (.tinted, .light, "TintedLight"),
    (.tinted, .dark, "TintedDark"),
  ])
  func mappingUsesPackageAppearanceAndSemanticAccent(
    style: ThemeIconStyle, appearance: ThemeAppearance, native: String
  ) throws {
    let accent = try #require(SRGBColor(rawValue: "#ABCDEF"))
    #expect(
      MacOSIconStyle.desired(style, appearance: appearance, accent: accent)
        == MacOSIconStyle(
          style: native, tint: style == .tinted ? "Other" : "-",
          custom: style == .tinted ? "#abcdef" : nil))
  }
}

// Frozen pre-icon-style input shape: a nil field must encode as absent, never as null.
private struct LegacyGenerationThemeInput: Encodable {
  let manifestSchemaVersion: Int
  let themeSchemaVersion: Int
  let themeID: String
  let appearance: ThemeAppearance
  let semantic: SemanticColors
  let terminal: TerminalColors
  let mappings: [String: String]
  let rendererVersions: [String: Int]

  enum CodingKeys: String, CodingKey {
    case manifestSchemaVersion = "manifest_schema_version"
    case themeSchemaVersion = "theme_schema_version"
    case themeID = "theme_id"
    case appearance, semantic, terminal, mappings
    case rendererVersions = "renderer_versions"
  }
}
