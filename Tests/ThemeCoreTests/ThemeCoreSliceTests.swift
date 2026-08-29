import Foundation
import Testing

@testable import ThemeCore

struct ThemeCoreSliceTests {
  @Test
  func renderedArtifactCollectionRejectsInvalidRequirementsAndDuplicatePaths() throws {
    let artifact = RenderedArtifact(path: "generated/example.txt", data: Data("one".utf8))
    let collection = try RenderedTheme(artifacts: [artifact])
    #expect(collection.artifact(atPath: artifact.path)?.data == artifact.data)
    #expect(artifact.sizePolicy == .ordinary)
    #expect(artifact.maximumSize == BoundedRegularFile.maximumSize)
    #expect(artifact.requirement == .required)

    #expect(throws: RenderedArtifactCollectionError.duplicatePath(artifact.path)) {
      _ = try RenderedTheme(artifacts: [artifact, artifact])
    }
    #expect(throws: RenderedArtifactCollectionError.invalidPath("../outside")) {
      _ = try RenderedTheme(
        artifacts: [RenderedArtifact(path: "../outside", data: Data())]
      )
    }
    #expect(
      throws: RenderedArtifactCollectionError.invalidRequirement(
        path: "generated/example.txt"
      )
    ) {
      _ = try RenderedTheme(
        artifacts: [
          RenderedArtifact(
            path: "generated/example.txt",
            data: Data(),
            requirement: .requiredWhenRendererVersion(renderer: .herdr, minimumVersion: 0)
          )
        ]
      )
    }
    #expect(VersionGatedRendererIdentity(id: HerdrAdapter.id) == .herdr)
    #expect(VersionGatedRendererIdentity(id: NeovimAdapter.id) == .neovim)
    #expect(VersionGatedRendererIdentity(id: SlackAdapter.id) == .slack)
    #expect(VersionGatedRendererIdentity(id: "fixture-renderer").id == "fixture-renderer")
  }

  @Test
  func renderedArtifactSizesUseOnlyApprovedClosedPolicies() throws {
    #expect(BoundedRegularFile.maximumSize == 1_048_576)
    #expect(WallpaperAsset.maximumSize == 32 * 1_048_576)
    #expect(
      RenderedArtifactSizePolicy(maximumSize: BoundedRegularFile.maximumSize) == .ordinary
    )
    #expect(RenderedArtifactSizePolicy(maximumSize: WallpaperAsset.maximumSize) == .wallpaper)
    for rejected in [Int.min, -1, 0, 1, WallpaperAsset.maximumSize + 1, Int.max] {
      #expect(RenderedArtifactSizePolicy(maximumSize: rejected) == nil)
    }

    let ordinaryPath = "generated/ordinary.txt"
    let exactOrdinary = try RenderedTheme(
      artifacts: [
        RenderedArtifact(
          path: ordinaryPath,
          data: Data(count: BoundedRegularFile.maximumSize)
        )
      ]
    )
    let outputRoot = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outputRoot) }
    try ThemeRenderer().write(exactOrdinary, to: outputRoot)
    #expect(
      try Data(contentsOf: outputRoot.appending(path: ordinaryPath)).count
        == BoundedRegularFile.maximumSize
    )

    #expect(
      throws: RenderedArtifactCollectionError.dataTooLarge(
        path: ordinaryPath,
        size: BoundedRegularFile.maximumSize + 1,
        maximumSize: BoundedRegularFile.maximumSize
      )
    ) {
      _ = try RenderedTheme(
        artifacts: [
          RenderedArtifact(
            path: ordinaryPath,
            data: Data(count: BoundedRegularFile.maximumSize + 1)
          )
        ]
      )
    }

    let wallpaperPath = "generated/wallpaper.png"
    _ = try RenderedTheme(
      artifacts: [
        RenderedArtifact(
          path: wallpaperPath,
          data: Data(count: WallpaperAsset.maximumSize),
          sizePolicy: .wallpaper
        )
      ]
    )
    #expect(
      throws: RenderedArtifactCollectionError.dataTooLarge(
        path: wallpaperPath,
        size: WallpaperAsset.maximumSize + 1,
        maximumSize: WallpaperAsset.maximumSize
      )
    ) {
      _ = try RenderedTheme(
        artifacts: [
          RenderedArtifact(
            path: wallpaperPath,
            data: Data(count: WallpaperAsset.maximumSize + 1),
            sizePolicy: .wallpaper
          )
        ]
      )
    }
  }

  @Test
  func renderedArtifactCollectionRejectsFilesystemEquivalentAndPrefixPaths() {
    let caseAliases = [
      RenderedArtifact(path: "generated/example.txt", data: Data()),
      RenderedArtifact(path: "GENERATED/EXAMPLE.TXT", data: Data()),
    ]
    #expect(
      throws: RenderedArtifactCollectionError.equivalentPaths(
        caseAliases[0].path,
        caseAliases[1].path
      )
    ) {
      _ = try RenderedTheme(artifacts: caseAliases)
    }

    let canonicalUnicodeAliases = [
      RenderedArtifact(path: "generated/\u{00E9}xample.txt", data: Data()),
      RenderedArtifact(path: "generated/e\u{0301}xample.txt", data: Data()),
    ]
    #expect(
      throws: RenderedArtifactCollectionError.equivalentPaths(
        canonicalUnicodeAliases[0].path,
        canonicalUnicodeAliases[1].path
      )
    ) {
      _ = try RenderedTheme(artifacts: canonicalUnicodeAliases)
    }

    let file = RenderedArtifact(path: "generated/cache", data: Data())
    let descendant = RenderedArtifact(path: "generated/cache/theme.txt", data: Data())
    let expected = RenderedArtifactCollectionError.componentPrefixCollision(
      file: file.path,
      descendant: descendant.path
    )
    #expect(throws: expected) {
      _ = try RenderedTheme(artifacts: [file, descendant])
    }
    #expect(throws: expected) {
      _ = try RenderedTheme(artifacts: [descendant, file])
    }

    #expect(
      throws: RenderedArtifactCollectionError.componentPrefixCollision(
        file: "GENERATED/CACHE",
        descendant: descendant.path
      )
    ) {
      _ = try RenderedTheme(
        artifacts: [
          RenderedArtifact(path: "GENERATED/CACHE", data: Data()),
          descendant,
        ]
      )
    }
  }

  @Test
  func rendererWritesExactOutputsToInjectedRoot() throws {
    let packageURL =
      repositoryRoot
      .appending(path: "Themes/catppuccin-mocha", directoryHint: .isDirectory)
    let package = try ThemePackageLoader().load(packageURL: packageURL)

    let rendered = try ThemeRenderer().render(package: package, generationID: "test-generation")
    let outputRoot = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outputRoot) }
    try ThemeRenderer().write(rendered, to: outputRoot)

    #expect(
      Set(rendered.artifacts.map(\.path))
        == [
          "generated/atuin.toml", "generated/bat.tmTheme", "generated/btop.theme",
          "generated/capabilities.json", "generated/eza.yml", "generated/herdr.txt",
          "generated/kitty.conf", "generated/neovim.lua", "generated/pi.json",
          "generated/sketchybar.lua", "generated/slack.txt", "generated/spicetify.ini",
          "generated/starship.toml", "generated/tuicr.toml", "generated/wallpaper.png",
          "generated/yazi-flavor.toml", "generated/yazi.tmTheme", "theme.json",
        ]
    )
    for artifact in rendered.artifacts {
      #expect(try Data(contentsOf: outputRoot.appending(path: artifact.path)) == artifact.data)
    }
    let compatibilityOutputs = [
      AtuinAdapter.outputPath: Data(rendered.atuinTheme.utf8),
      TextMateThemeArtifact.outputPath: Data(rendered.batTheme.utf8),
      BtopAdapter.outputPath: Data(rendered.btopTheme.utf8),
      EzaAdapter.outputPath: Data(rendered.ezaTheme.utf8),
      HerdrAdapter.outputPath: Data(rendered.herdrTheme.utf8),
      ThemeRenderer.themeOutputPath: rendered.themeJSON,
      KittyAdapter.outputPath: Data(rendered.kittyConfiguration.utf8),
      NeovimAdapter.outputPath: Data(rendered.neovimTheme.utf8),
      PiAdapter.outputPath: Data(rendered.piTheme.utf8),
      SketchyBarAdapter.outputPath: Data(rendered.sketchyBarPalette.utf8),
      SlackAdapter.outputPath: Data(rendered.slackTheme.utf8),
      SpicetifyAdapter.outputPath: Data(rendered.spicetifyTheme.utf8),
      StarshipAdapter.outputPath: Data(rendered.starshipPalette.utf8),
      TuicrAdapter.outputPath: Data(rendered.tuicrTheme.utf8),
      WallpaperAdapter.outputPath: try #require(rendered.wallpaper),
      YaziAdapter.flavorOutputPath: Data(rendered.yaziFlavor.utf8),
    ]
    for (path, data) in compatibilityOutputs {
      #expect(rendered.artifact(atPath: path)?.data == data)
    }
    let writtenJSON = try Data(contentsOf: outputRoot.appending(path: "theme.json"))
    let writtenWallpaper = try Data(
      contentsOf: outputRoot.appending(path: WallpaperAdapter.outputPath)
    )
    #expect(
      rendered.artifact(atPath: TextMateThemeArtifact.outputPath)?.data
        == rendered.artifact(atPath: TextMateThemeArtifact.yaziOutputPath)?.data
    )
    #expect(
      writtenWallpaper
        == (try Data(contentsOf: packageURL.appending(path: package.backgrounds[0].path)))
    )

    let decoded = try JSONDecoder().decode(NormalizedTheme.self, from: writtenJSON)
    #expect(decoded.themeID == package.id)
    #expect(decoded.generationID == "test-generation")
  }

  @Test
  func piDerivesReadableConversationRolesWhenSurfaceMatchesThePage() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "lavender-like")
    let manifest = packageURL.appending(path: "theme.toml")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let lavenderLike =
      original
      .replacingOccurrences(of: "background = \"#1e1e2e\"", with: "background = \"#11111b\"")
      .replacingOccurrences(of: "surface = \"#313244\"", with: "surface = \"#11111b\"")
      .replacingOccurrences(of: "muted_text = \"#a6adc8\"", with: "muted_text = \"#585b70\"")
      .replacingOccurrences(of: "info = \"#74c7ec\"", with: "info = \"#94e2d5\"")
    try lavenderLike.write(to: manifest, atomically: true, encoding: .utf8)

    let package = try ThemePackageLoader().load(packageURL: packageURL)
    let rendered = try PiAdapter.render(package: package)
    let document = try #require(
      JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
    )
    let vars = try #require(document["vars"] as? [String: String])
    let colors = try #require(document["colors"] as? [String: String])
    let roleBackgrounds = [
      vars["background"],
      vars["userMessageBg"],
      vars["customMessageBg"],
      vars["toolPendingBg"],
      vars["toolSuccessBg"],
      vars["toolErrorBg"],
    ]

    #expect(
      roleBackgrounds
        == ["#11111b", "#322c43", "#232e35", "#28262a", "#232a2b", "#31222f"])
    #expect(Set(roleBackgrounds.compactMap { $0 }).count == roleBackgrounds.count)
    #expect(vars["muted"] == "#9096af")
    #expect(colors["userMessageBg"] == "userMessageBg")
    #expect(colors["customMessageBg"] == "customMessageBg")
    #expect(colors["toolPendingBg"] == "toolPendingBg")
    #expect(colors["toolSuccessBg"] == "toolSuccessBg")
    #expect(colors["toolErrorBg"] == "toolErrorBg")
  }

  @Test
  func malformedColorReportsFieldAndSourceLine() throws {
    let source =
      repositoryRoot
      .appending(path: "Themes/catppuccin-mocha", directoryHint: .isDirectory)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = root.appending(path: "broken", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: packageURL)

    let manifest = packageURL.appending(path: "theme.toml")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let malformed = original.replacingOccurrences(
      of: "background = \"#1e1e2e\"",
      with: "background = \"#xyz\""
    )
    try malformed.write(to: manifest, atomically: true, encoding: .utf8)

    let diagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: packageURL)
    }
    #expect(diagnostic.field == "semantic.background")
    #expect(diagnostic.location.line == 7)
    #expect(diagnostic.location.column == 1)
    #expect(diagnostic.description.contains("#RRGGBB"))
  }

  @Test
  func allBuiltInPackagesMatchRenderedGoldens() throws {
    let themesRoot = repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
    let packages = try ThemeRepository(builtInRoot: themesRoot).packages()
    #expect(packages.map(\.id) == ["catppuccin-mocha", "kanagawa-wave", "tokyo-night"])
    let herdrThemeNames = [
      "catppuccin-mocha": "catppuccin",
      "kanagawa-wave": "kanagawa",
      "tokyo-night": "tokyo-night",
    ]

    for package in packages {
      let generationID = "golden-\(package.id)"
      let rendered = try ThemeRenderer().render(package: package, generationID: generationID)

      let goldenRoot =
        repositoryRoot
        .appending(path: "Tests/Fixtures/Golden/\(package.id)", directoryHint: .isDirectory)
      let goldenArtifacts = [
        (AtuinAdapter.outputPath, "atuin.toml"),
        (TextMateThemeArtifact.outputPath, "bat.tmTheme"),
        (TextMateThemeArtifact.yaziOutputPath, "bat.tmTheme"),
        (BtopAdapter.outputPath, "btop.theme"),
        (EzaAdapter.outputPath, "eza.yml"),
        (ThemeRenderer.themeOutputPath, "theme.json"),
        (KittyAdapter.outputPath, "kitty.conf"),
        (NeovimAdapter.outputPath, "neovim.lua"),
        (PiAdapter.outputPath, "pi.json"),
        (SketchyBarAdapter.outputPath, "sketchybar.lua"),
        (SlackAdapter.outputPath, "slack.txt"),
        (SpicetifyAdapter.outputPath, "spicetify.ini"),
        (StarshipAdapter.outputPath, "starship.toml"),
        (TuicrAdapter.outputPath, "tuicr.toml"),
        (YaziAdapter.flavorOutputPath, "yazi-flavor.toml"),
      ]
      for (artifactPath, goldenName) in goldenArtifacts {
        #expect(
          try #require(rendered.artifact(atPath: artifactPath)).data
            == Data(contentsOf: goldenRoot.appending(path: goldenName))
        )
      }
      let herdrData = try #require(rendered.artifact(atPath: HerdrAdapter.outputPath)).data
      let herdr = try JSONDecoder().decode(GeneratedHerdrTheme.self, from: herdrData).validated()
      #expect(herdr.name == herdrThemeNames[package.id])
      #expect(herdr.custom.isEmpty)
    }
  }

  @Test
  func lightAppearanceMetadataIsAcceptedWithoutShippingALightTheme() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "light-fixture")
    let manifest = packageURL.appending(path: "theme.toml")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let light = original.replacingOccurrences(
      of: "appearance = \"dark\"", with: "appearance = \"light\"")
    try light.write(to: manifest, atomically: true, encoding: .utf8)

    let package = try ThemePackageLoader().load(packageURL: packageURL)
    #expect(package.appearance == .light)
  }

  @Test
  func invalidAppearanceReportsMetadataSourceLine() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "invalid-appearance")
    let manifest = packageURL.appending(path: "theme.toml")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let invalid = original.replacingOccurrences(
      of: "appearance = \"dark\"", with: "appearance = \"automatic\"")
    try invalid.write(to: manifest, atomically: true, encoding: .utf8)

    let diagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: packageURL)
    }
    #expect(diagnostic.field == "appearance")
    #expect(diagnostic.location.line == 4)
    #expect(diagnostic.message.contains("dark"))
    #expect(diagnostic.message.contains("light"))
  }

  @Test
  func packageCanDeliberatelyOmitNamedConsumerMappings() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "missing-mappings")
    try "schema_version = 1\n\n[mappings]\n".write(
      to: packageURL.appending(path: "mappings.toml"),
      atomically: true,
      encoding: .utf8
    )

    let package = try ThemePackageLoader().load(packageURL: packageURL)
    #expect(package.mappings.isEmpty)

    let rendered = try ThemeRenderer().render(package: package, generationID: "imported")
    let herdrData = try #require(rendered.artifact(atPath: HerdrAdapter.outputPath)).data
    let herdr = try JSONDecoder().decode(GeneratedHerdrTheme.self, from: herdrData).validated()
    #expect(herdr.name == "catppuccin")
    #expect(
      herdr.custom
        == [
          "accent": "#cba6f7",
          "panel_bg": "#1e1e2e",
          "surface0": "#313244",
          "surface1": "#45475a",
          "surface_dim": "#1e1e2e",
          "overlay0": "#585b70",
          "overlay1": "#a6adc8",
          "text": "#cdd6f4",
          "subtext0": "#a6adc8",
          "mauve": "#f5c2e7",
          "green": "#a6e3a1",
          "yellow": "#f9e2af",
          "red": "#f38ba8",
          "blue": "#89b4fa",
          "teal": "#94e2d5",
          "peach": "#f9e2af",
        ]
    )
  }

  @Test
  func missingRequiredThemeKeyFailsBeforeTypedDecoding() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "missing-key")
    let manifest = packageURL.appending(path: "theme.toml")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let missing = original.replacingOccurrences(of: "warning = \"#f9e2af\"\n", with: "")
    try missing.write(to: manifest, atomically: true, encoding: .utf8)

    let diagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: packageURL)
    }
    #expect(diagnostic.field == "semantic.warning")
    #expect(diagnostic.message == "Missing required schema key")
  }

  @Test
  func duplicateIdentifiersAcrossRootsFailExplicitly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let builtIn = root.appending(path: "built-in", directoryHint: .isDirectory)
    let user = root.appending(path: "user", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    _ = try copyCatppuccin(to: builtIn, named: "first")
    _ = try copyCatppuccin(to: user, named: "second")

    let diagnostic = try themeDiagnostic {
      _ = try ThemeRepository(builtInRoot: builtIn, userRoot: user).packages()
    }
    #expect(diagnostic.field == "id")
    #expect(diagnostic.message.contains("Duplicate theme identifier 'catppuccin-mocha'"))
  }

  @Test
  func missingAndCorruptBackgroundAssetsFail() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let missingPackage = try copyCatppuccin(to: root, named: "missing-asset")
    try FileManager.default.removeItem(at: missingPackage.appending(path: "wallpapers/default.png"))
    let missingDiagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: missingPackage)
    }
    #expect(missingDiagnostic.field == "backgrounds.path")
    #expect(missingDiagnostic.message.contains("Cannot load background 'default'"))

    let corruptPackage = try copyCatppuccin(to: root, named: "corrupt-asset")
    try Data("not a png".utf8).write(to: corruptPackage.appending(path: "wallpapers/default.png"))
    let corruptDiagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: corruptPackage)
    }
    #expect(corruptDiagnostic.field == "backgrounds.path")
    #expect(corruptDiagnostic.message.contains("PNG"))
  }

  @Test
  func backgroundSymlinkCannotEscapePackage() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "external-wallpaper")
    let wallpaper = packageURL.appending(path: "wallpapers/default.png")
    let external = root.appending(path: "external.png")
    try FileManager.default.copyItem(at: wallpaper, to: external)
    try FileManager.default.removeItem(at: wallpaper)
    try FileManager.default.createSymbolicLink(at: wallpaper, withDestinationURL: external)

    let diagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: packageURL)
    }
    #expect(diagnostic.field == "backgrounds.path")
    #expect(diagnostic.message.contains("resolve inside"))
  }

  @Test
  func wallpaperOverrideRejectsInvalidConfigurationAndSource() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = root.appending(path: "config.toml")
    try """
    schema_version = 1

    [wallpaper_overrides]
    catppuccin-mocha = "relative.png"
    """.write(to: configuration, atomically: true, encoding: .utf8)
    #expect(throws: MacarchyConfigurationError.self) {
      _ = try MacarchyConfigurationStore(root: root).load()
    }

    try """
    schema_version = 1
    unexpected = true
    """.write(to: configuration, atomically: true, encoding: .utf8)
    #expect(throws: MacarchyConfigurationError.self) {
      _ = try MacarchyConfigurationStore(root: root).load()
    }

    try "schema_version = 2\n".write(
      to: configuration,
      atomically: true,
      encoding: .utf8
    )
    #expect(throws: MacarchyConfigurationError.self) {
      _ = try MacarchyConfigurationStore(root: root).load()
    }

    let invalidPNG = root.appending(path: "invalid.png")
    try Data("not png".utf8).write(to: invalidPNG)
    try overrideConfiguration(in: configuration, wallpaper: invalidPNG)
    #expect(throws: MacarchyConfigurationError.self) {
      _ = try MacarchyConfigurationStore(root: root).load().wallpaperData(
        themeID: "catppuccin-mocha"
      )
    }

    let oversized = root.appending(path: "oversized.png")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(WallpaperAsset.maximumSize + 1))
    try handle.close()
    try overrideConfiguration(in: configuration, wallpaper: oversized)
    #expect(throws: MacarchyConfigurationError.self) {
      _ = try MacarchyConfigurationStore(root: root).load().wallpaperData(
        themeID: "catppuccin-mocha"
      )
    }
  }

  @Test
  func unknownSchemaKeyReportsItsSource() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "unknown-key")
    let manifest = packageURL.appending(path: "theme.toml")
    var text = try String(contentsOf: manifest, encoding: .utf8)
    text += "\n[extra]\nvalue = \"unexpected\"\n"
    try text.write(to: manifest, atomically: true, encoding: .utf8)

    let diagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: packageURL)
    }
    #expect(diagnostic.field == "extra")
    #expect(diagnostic.location.line != nil)
    #expect(diagnostic.message == "Unknown schema table")
  }

  @Test
  func quotedTableNameFailsWithCanonicalSyntaxDiagnostic() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "quoted-table")
    let manifest = packageURL.appending(path: "theme.toml")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let quoted = original.replacingOccurrences(of: "[semantic]", with: "[\"semantic\"]")
    try quoted.write(to: manifest, atomically: true, encoding: .utf8)

    let diagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: packageURL)
    }
    #expect(diagnostic.location.line == 6)
    #expect(diagnostic.message == "Theme manifest tables must use bare names")
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "macarchy-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func copyCatppuccin(to root: URL, named name: String) throws -> URL {
    let source =
      repositoryRoot
      .appending(path: "Themes/catppuccin-mocha", directoryHint: .isDirectory)
    let destination = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  private func overrideConfiguration(in configuration: URL, wallpaper: URL) throws {
    try """
    schema_version = 1

    [wallpaper_overrides]
    catppuccin-mocha = "\(wallpaper.path)"
    """.write(to: configuration, atomically: true, encoding: .utf8)
  }

  private func themeDiagnostic(from operation: () throws -> Void) throws -> ThemeDiagnostic {
    do {
      try operation()
    } catch let diagnostic as ThemeDiagnostic {
      return diagnostic
    }
    throw TestError.expectedThemeDiagnostic
  }

  private enum TestError: Error {
    case expectedThemeDiagnostic
  }
}
