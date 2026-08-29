import Foundation
import Testing

@testable import ThemeCore

struct BuiltInOmarchyParityTests {
  @Test(
    arguments: [
      (themeID: "tokyo-night", omarchyThemeID: "tokyo-night"),
      (themeID: "kanagawa-wave", omarchyThemeID: "kanagawa"),
    ])
  func canonicalPaletteMatchesOmarchyConversion(
    themeID: String,
    omarchyThemeID: String
  ) throws {
    let package = try repository.package(id: themeID)
    let conversion = try OmarchyPaletteLoader().load(
      colorsFile: repositoryRoot.appending(
        path: "Tests/Fixtures/Omarchy/\(omarchyThemeID)/colors.toml"
      )
    )

    #expect(package.appearance == conversion.appearance)
    #expect(semanticValues(package.semantic) == semanticValues(conversion.semantic))
    #expect(terminalValues(package.terminal) == terminalValues(conversion.terminal))
  }

  @Test
  func builtInBackgroundsAreExactOmarchyAssetsInOmarchyOrder() throws {
    let tokyoNight = try repository.package(id: "tokyo-night")
    #expect(tokyoNight.backgrounds.map(\.path) == ["wallpapers/0-winding-road.webp"])
    #expect(
      tokyoNight.backgrounds.map { sha256Digest(tokyoNight.data(for: $0)) } == [
        "sha256:b149c3e1c8ce383812e7bc3170c2cf8b160ca583d72d59173cd42efdb79ced2b"
      ])

    let kanagawa = try repository.package(id: "kanagawa-wave")
    #expect(kanagawa.backgrounds.map(\.path) == ["wallpapers/1-kanagawa.jpg"])
    #expect(
      kanagawa.backgrounds.map { sha256Digest(kanagawa.data(for: $0)) } == [
        "sha256:9b817d717688539f0db87603b661992839c3cbb5d4918a02a4efc05c9f88b27d"
      ])

    let catppuccin = try repository.package(id: "catppuccin-mocha")
    #expect(catppuccin.backgrounds.map(\.path) == ["wallpapers/1-totoro.webp"])
    #expect(
      sha256Digest(catppuccin.defaultBackgroundData)
        == "sha256:4896da620ed3016b7e52eede8db8169591a9fa4856064db4039521be96f724b6"
    )
  }

  private var repository: ThemeRepository {
    ThemeRepository(
      builtInRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
    )
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func semanticValues(_ colors: SemanticColors) -> [String] {
    [
      colors.background, colors.surface, colors.overlay, colors.border,
      colors.text, colors.mutedText, colors.accent, colors.selection,
      colors.info, colors.success, colors.warning, colors.error,
    ].map(\.rawValue)
  }

  private func terminalValues(_ colors: TerminalColors) -> [String] {
    [
      colors.foreground, colors.background, colors.cursor,
      colors.selectionForeground, colors.selectionBackground,
    ].map(\.rawValue) + colors.ansi.map(\.rawValue)
  }
}
