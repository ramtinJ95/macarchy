import Foundation
import Testing

@testable import ThemeCore

struct ThemeCoreSliceTests {
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

    let themeJSON = outputRoot.appending(path: "theme.json")
    let atuin = outputRoot.appending(path: "generated/atuin.toml")
    let bat = outputRoot.appending(path: "generated/bat.tmTheme")
    let btop = outputRoot.appending(path: "generated/btop.theme")
    let capabilities = outputRoot.appending(path: "generated/capabilities.json")
    let eza = outputRoot.appending(path: "generated/eza.yml")
    let herdr = outputRoot.appending(path: "generated/herdr.txt")
    let kitty = outputRoot.appending(path: "generated/kitty.conf")
    let neovim = outputRoot.appending(path: "generated/neovim.lua")
    let pi = outputRoot.appending(path: "generated/pi.json")
    let sketchyBar = outputRoot.appending(path: "generated/sketchybar.lua")
    let slack = outputRoot.appending(path: "generated/slack.txt")
    let spicetify = outputRoot.appending(path: "generated/spicetify.ini")
    let starship = outputRoot.appending(path: "generated/starship.toml")
    let tuicr = outputRoot.appending(path: "generated/tuicr.toml")
    let wallpaper = outputRoot.appending(path: "generated/wallpaper.png")
    let yaziFlavor = outputRoot.appending(path: "generated/yazi-flavor.toml")
    let yaziSyntax = outputRoot.appending(path: "generated/yazi.tmTheme")
    let writtenJSON = try Data(contentsOf: themeJSON)
    let writtenAtuin = try String(contentsOf: atuin, encoding: .utf8)
    let writtenBat = try String(contentsOf: bat, encoding: .utf8)
    let writtenBtop = try String(contentsOf: btop, encoding: .utf8)
    let writtenCapabilities = try Data(contentsOf: capabilities)
    let writtenEza = try String(contentsOf: eza, encoding: .utf8)
    let writtenHerdr = try String(contentsOf: herdr, encoding: .utf8)
    let writtenKitty = try String(contentsOf: kitty, encoding: .utf8)
    let writtenNeovim = try String(contentsOf: neovim, encoding: .utf8)
    let writtenPi = try String(contentsOf: pi, encoding: .utf8)
    let writtenSketchyBar = try String(contentsOf: sketchyBar, encoding: .utf8)
    let writtenSlack = try String(contentsOf: slack, encoding: .utf8)
    let writtenSpicetify = try String(contentsOf: spicetify, encoding: .utf8)
    let writtenStarship = try String(contentsOf: starship, encoding: .utf8)
    let writtenTuicr = try String(contentsOf: tuicr, encoding: .utf8)
    let writtenWallpaper = try Data(contentsOf: wallpaper)
    let writtenYaziFlavor = try String(contentsOf: yaziFlavor, encoding: .utf8)
    let writtenYaziSyntax = try String(contentsOf: yaziSyntax, encoding: .utf8)
    #expect(writtenJSON == rendered.themeJSON)
    #expect(writtenAtuin == rendered.atuinTheme)
    #expect(writtenBat == rendered.batTheme)
    #expect(writtenBtop == rendered.btopTheme)
    #expect(writtenCapabilities == rendered.capabilities)
    #expect(writtenEza == rendered.ezaTheme)
    #expect(writtenHerdr == rendered.herdrTheme)
    #expect(writtenKitty == rendered.kittyConfiguration)
    #expect(writtenNeovim == rendered.neovimTheme)
    #expect(writtenPi == rendered.piTheme)
    #expect(writtenSketchyBar == rendered.sketchyBarPalette)
    #expect(writtenSlack == rendered.slackTheme)
    #expect(writtenSpicetify == rendered.spicetifyTheme)
    #expect(writtenStarship == rendered.starshipPalette)
    #expect(writtenTuicr == rendered.tuicrTheme)
    #expect(writtenWallpaper == rendered.wallpaper)
    #expect(writtenYaziFlavor == rendered.yaziFlavor)
    #expect(writtenYaziSyntax == rendered.batTheme)
    #expect(
      writtenWallpaper
        == (try Data(contentsOf: packageURL.appending(path: package.wallpaper.path)))
    )

    let decoded = try JSONDecoder().decode(NormalizedTheme.self, from: writtenJSON)
    #expect(decoded.themeID == package.id)
    #expect(decoded.generationID == "test-generation")
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
      #expect(
        rendered.atuinTheme
          == (try String(contentsOf: goldenRoot.appending(path: "atuin.toml"), encoding: .utf8)))
      #expect(
        rendered.batTheme
          == (try String(contentsOf: goldenRoot.appending(path: "bat.tmTheme"), encoding: .utf8)))
      #expect(
        rendered.btopTheme
          == (try String(contentsOf: goldenRoot.appending(path: "btop.theme"), encoding: .utf8)))
      #expect(
        rendered.ezaTheme
          == (try String(contentsOf: goldenRoot.appending(path: "eza.yml"), encoding: .utf8)))
      let herdrData = Data(rendered.herdrTheme.utf8)
      let herdr = try JSONDecoder().decode(GeneratedHerdrTheme.self, from: herdrData).validated()
      #expect(herdr.name == herdrThemeNames[package.id])
      #expect(herdr.custom.isEmpty)
      #expect(
        rendered.themeJSON == (try Data(contentsOf: goldenRoot.appending(path: "theme.json"))))
      #expect(
        rendered.kittyConfiguration
          == (try String(contentsOf: goldenRoot.appending(path: "kitty.conf"), encoding: .utf8)))
      #expect(
        rendered.neovimTheme
          == (try String(contentsOf: goldenRoot.appending(path: "neovim.lua"), encoding: .utf8)))
      #expect(
        rendered.piTheme
          == (try String(contentsOf: goldenRoot.appending(path: "pi.json"), encoding: .utf8)))
      #expect(
        rendered.sketchyBarPalette
          == (try String(
            contentsOf: goldenRoot.appending(path: "sketchybar.lua"), encoding: .utf8)))
      #expect(
        rendered.slackTheme
          == (try String(contentsOf: goldenRoot.appending(path: "slack.txt"), encoding: .utf8)))
      #expect(
        rendered.spicetifyTheme
          == (try String(contentsOf: goldenRoot.appending(path: "spicetify.ini"), encoding: .utf8)))
      let starshipGolden = try String(
        contentsOf: goldenRoot.appending(path: "starship.toml"), encoding: .utf8)
      #expect(rendered.starshipPalette == starshipGolden)
      #expect(
        rendered.tuicrTheme
          == (try String(contentsOf: goldenRoot.appending(path: "tuicr.toml"), encoding: .utf8)))
      #expect(
        rendered.yaziFlavor
          == (try String(
            contentsOf: goldenRoot.appending(path: "yazi-flavor.toml"), encoding: .utf8)))
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
    let herdrData = Data(rendered.herdrTheme.utf8)
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
  func missingAndCorruptWallpaperAssetsFail() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let missingPackage = try copyCatppuccin(to: root, named: "missing-asset")
    try FileManager.default.removeItem(at: missingPackage.appending(path: "wallpapers/default.png"))
    let missingDiagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: missingPackage)
    }
    #expect(missingDiagnostic.field == "wallpaper.path")
    #expect(missingDiagnostic.message.contains("Cannot read wallpaper"))

    let corruptPackage = try copyCatppuccin(to: root, named: "corrupt-asset")
    try Data("not a png".utf8).write(to: corruptPackage.appending(path: "wallpapers/default.png"))
    let corruptDiagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: corruptPackage)
    }
    #expect(corruptDiagnostic.field == "wallpaper.path")
    #expect(corruptDiagnostic.message.contains("PNG"))
  }

  @Test
  func wallpaperSymlinkCannotEscapePackage() throws {
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
    #expect(diagnostic.field == "wallpaper.path")
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
