import Foundation
import Testing

@testable import ThemeCore

struct OmarchyPaletteLoaderTests {
  @Test
  func pinnedPurpleDreamPaletteMatchesCanonicalGolden() throws {
    let colors =
      repositoryRoot
      .appending(path: "Tests/Fixtures/Omarchy/purple-dream/colors.toml")
    let conversion = try OmarchyPaletteLoader().load(colorsFile: colors)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let actual = String(decoding: try encoder.encode(conversion), as: UTF8.self)
    let expected = try String(
      contentsOf:
        repositoryRoot.appending(path: "Tests/Fixtures/Omarchy/purple-dream/palette.json"),
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(actual == expected)
  }

  @Test
  func semanticPaletteDerivesRequiredRampsAndBrightANSIColors() throws {
    let file = try writePalette(
      """
      mode = "light"
      accent = "#336699"
      selection = "#808080"
      muted = "#404040"
      background = "#f0f0f0"
      foreground = "#202020"
      red = "#ff0000"
      green = "#00ff00"
      yellow = "#ffff00"
      blue = "#0000ff"
      magenta = "#ff00ff"
      cyan = "#00ffff"
      custom_surface = "rgba(010203ee) rgba(040506ee) 45deg"
      custom_priority = 2
      custom_options = ["dim", "blur"]
      """
    )
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let conversion = try OmarchyPaletteLoader().load(colorsFile: file)

    #expect(conversion.appearance == .light)
    #expect(conversion.semantic.surface.rawValue == "#f0f0f0")
    #expect(conversion.semantic.overlay.rawValue == "#808080")
    #expect(conversion.semantic.border.rawValue == "#404040")
    #expect(conversion.semantic.mutedText.rawValue == "#202020")
    #expect(conversion.terminal.selectionForeground.rawValue == "#202020")
    #expect(conversion.terminal.selectionBackground.rawValue == "#808080")
    #expect(
      conversion.terminal.ansi.map(\.rawValue) == [
        "#f0f0f0", "#ff0000", "#00ff00", "#ffff00",
        "#0000ff", "#ff00ff", "#00ffff", "#202020",
        "#404040", "#ff3333", "#33ff33", "#ffff33",
        "#3333ff", "#ff33ff", "#33ffff", "#202020",
      ])
    #expect(!conversion.compatibility.usedLegacyANSI)
    #expect(
      conversion.compatibility.ignoredFields == [
        "custom_options", "custom_priority", "custom_surface",
      ])
    #expect(conversion.compatibility.derivedFields.contains("bright_red"))
    #expect(conversion.compatibility.derivedFields.contains("color0"))
    #expect(conversion.compatibility.derivedFields.contains("color7"))
    #expect(conversion.compatibility.derivedFields.contains("lighter_background"))
  }

  @Test
  func legacyShortAliasesResolveWithCanonicalValuesTakingPrecedence() throws {
    let file = try writePalette(
      """
      theme_type = "light"
      accent = "#336699"
      selection = "#808080"
      muted = "#404040"
      background = "#f0f0f0"
      bg = "#000000"
      lighter_bg = "#e0e0e0"
      fg = "#202020"
      dark_fg = "#303030"
      light_fg = "#101010"
      bright_fg = "#000000"
      red = "#ff0000"
      green = "#00ff00"
      yellow = "#ffff00"
      blue = "#0000ff"
      purple = "#ff00ff"
      cyan = "#00ffff"
      bright_red = "#ff3333"
      bright_green = "#33ff33"
      bright_yellow = "#ffff33"
      bright_blue = "#3333ff"
      bright_purple = "#123456"
      bright_cyan = "#33ffff"
      """
    )
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let conversion = try OmarchyPaletteLoader().load(colorsFile: file)

    #expect(conversion.appearance == .light)
    #expect(conversion.semantic.background.rawValue == "#f0f0f0")
    #expect(conversion.semantic.surface.rawValue == "#e0e0e0")
    #expect(conversion.semantic.text.rawValue == "#202020")
    #expect(conversion.semantic.error.rawValue == "#ff0000")
    #expect(conversion.terminal.ansi[13].rawValue == "#123456")
    #expect(conversion.compatibility.usedLegacyAliases)
    #expect(!conversion.compatibility.usedLegacyANSI)
    #expect(conversion.compatibility.derivedFields.contains("mode"))
    #expect(conversion.compatibility.ignoredFields == ["light_fg"])
    #expect(conversion.compatibility.overriddenFields == ["bg"])
  }

  @Test
  func malformedAndDuplicateActiveFieldsReportTheirSource() throws {
    let malformed = try writePalette(
      validMinimalPalette.replacingOccurrences(
        of: "red = \"#ff0000\"", with: "color1 = \"not-a-color\""))
    defer { try? FileManager.default.removeItem(at: malformed.deletingLastPathComponent()) }

    let malformedDiagnostic = try diagnostic {
      _ = try OmarchyPaletteLoader().load(colorsFile: malformed)
    }
    #expect(malformedDiagnostic.field == "color1")
    #expect(malformedDiagnostic.location.line == 7)
    #expect(malformedDiagnostic.message.contains("#RRGGBB"))

    let duplicate = try writePalette(validMinimalPalette + "\nbackground = \"#000000\"\n")
    defer { try? FileManager.default.removeItem(at: duplicate.deletingLastPathComponent()) }

    let duplicateDiagnostic = try diagnostic {
      _ = try OmarchyPaletteLoader().load(colorsFile: duplicate)
    }
    #expect(duplicateDiagnostic.field == "background")
    #expect(duplicateDiagnostic.location.line != nil)
    #expect(duplicateDiagnostic.message == "Duplicate Omarchy color field")
  }

  @Test
  func modeFallbacksPrecedeBackgroundLuminance() throws {
    let file = try writePalette(
      validMinimalPalette.replacingOccurrences(of: "mode = \"dark\"\n", with: ""))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let marker = file.deletingLastPathComponent().appending(path: "light.mode")
    try Data().write(to: marker)

    let markerConversion = try OmarchyPaletteLoader().load(colorsFile: file)

    #expect(markerConversion.appearance == .light)
    #expect(markerConversion.compatibility.derivedFields.contains("mode"))

    try FileManager.default.removeItem(at: marker)
    let aliasPalette =
      "theme_type = \"light\"\n"
      + validMinimalPalette.replacingOccurrences(of: "mode = \"dark\"\n", with: "")
    try aliasPalette.write(to: file, atomically: true, encoding: .utf8)
    let aliasConversion = try OmarchyPaletteLoader().load(colorsFile: file)

    #expect(aliasConversion.appearance == .light)
    #expect(aliasConversion.compatibility.usedLegacyAliases)
  }

  @Test
  func paletteInputIsBoundedAndDoesNotFollowSymlinks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "target.toml")
    let link = root.appending(path: "colors.toml")
    try validMinimalPalette.write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let symlinkDiagnostic = try diagnostic {
      _ = try OmarchyPaletteLoader().load(colorsFile: link)
    }
    #expect(symlinkDiagnostic.message.contains("Cannot read Omarchy colors"))

    let oversized = root.appending(path: "oversized.toml")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(BoundedRegularFile.maximumSize + 1))
    try handle.close()

    let oversizedDiagnostic = try diagnostic {
      _ = try OmarchyPaletteLoader().load(colorsFile: oversized)
    }
    #expect(oversizedDiagnostic.message.contains("1 MiB"))
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var validMinimalPalette: String {
    """
    mode = "dark"
    accent = "#336699"
    selection = "#292929"
    muted = "#404040"
    background = "#101010"
    foreground = "#f0f0f0"
    red = "#ff0000"
    green = "#00ff00"
    yellow = "#ffff00"
    blue = "#0000ff"
    magenta = "#ff00ff"
    cyan = "#00ffff"
    """
  }

  private func writePalette(_ text: String) throws -> URL {
    let root = try temporaryDirectory()
    let file = root.appending(path: "colors.toml")
    try text.write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-omarchy-palette-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func diagnostic(_ operation: () throws -> Void) throws -> ThemeDiagnostic {
    do {
      try operation()
      Issue.record("Expected a ThemeDiagnostic")
      throw TestFailure.expectedDiagnostic
    } catch let diagnostic as ThemeDiagnostic {
      return diagnostic
    }
  }

  private enum TestFailure: Error {
    case expectedDiagnostic
  }
}
