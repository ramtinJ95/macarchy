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
    let kitty = outputRoot.appending(path: "generated/kitty.conf")
    let writtenJSON = try Data(contentsOf: themeJSON)
    let writtenKitty = try String(contentsOf: kitty, encoding: .utf8)
    #expect(writtenJSON == rendered.themeJSON)
    #expect(writtenKitty == rendered.kittyConfiguration)

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
  func bothBuiltInPackagesMatchRenderedGoldens() throws {
    let themesRoot = repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
    let packages = try ThemeRepository(builtInRoot: themesRoot).packages()
    #expect(packages.map(\.id) == ["catppuccin-mocha", "tokyo-night"])

    for package in packages {
      let generationID = "golden-\(package.id)"
      let rendered = try ThemeRenderer().render(package: package, generationID: generationID)

      let goldenRoot =
        repositoryRoot
        .appending(path: "Tests/Fixtures/Golden/\(package.id)", directoryHint: .isDirectory)
      #expect(
        rendered.themeJSON == (try Data(contentsOf: goldenRoot.appending(path: "theme.json"))))
      #expect(
        rendered.kittyConfiguration
          == (try String(contentsOf: goldenRoot.appending(path: "kitty.conf"), encoding: .utf8)))
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
  func missingMappingsFailsExplicitly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root, named: "missing-mappings")
    try "schema_version = 1\n\n[mappings]\n".write(
      to: packageURL.appending(path: "mappings.toml"),
      atomically: true,
      encoding: .utf8
    )

    let diagnostic = try themeDiagnostic {
      _ = try ThemePackageLoader().load(packageURL: packageURL)
    }
    #expect(diagnostic.field == "mappings")
    #expect(diagnostic.message.contains("At least one"))
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
