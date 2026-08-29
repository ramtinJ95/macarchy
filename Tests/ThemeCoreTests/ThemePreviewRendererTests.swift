import AppKit
import Foundation
import Testing

@testable import ThemeCore

struct ThemePreviewRendererTests {
  @Test
  func everyValidatedThemeProducesADeterministicRenderableCard() throws {
    let themesRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Themes", directoryHint: .isDirectory)
    let packages = try ThemeRepository(builtInRoot: themesRoot).packages()

    for package in packages {
      #expect(try ImportedThemePreviewLoader().load(package: package).isEmpty)
      let first = ThemePreviewRenderer().render(package: package)
      let second = ThemePreviewRenderer().render(package: package)
      #expect(first == second)
      #expect(first.mediaType == "image/svg+xml")
      #expect(first.data.count < BoundedRegularFile.maximumSize)

      let image = try #require(NSImage(data: first.data))
      #expect(image.size.width == CGFloat(GeneratedThemePreview.width))
      #expect(image.size.height == CGFloat(GeneratedThemePreview.height))

      let source = try #require(String(data: first.data, encoding: .utf8))
      for color in [
        package.semantic.background,
        package.semantic.surface,
        package.semantic.overlay,
        package.semantic.border,
        package.semantic.text,
        package.semantic.mutedText,
        package.semantic.accent,
        package.semantic.selection,
        package.semantic.info,
        package.semantic.success,
        package.semantic.warning,
        package.semantic.error,
        package.terminal.foreground,
        package.terminal.background,
        package.terminal.cursor,
        package.terminal.selectionForeground,
        package.terminal.selectionBackground,
      ] + package.terminal.ansi {
        #expect(source.contains(color.rawValue))
      }
    }

    let package = try #require(packages.first)
    let selectionForeground = try #require(SRGBColor(rawValue: "#010203"))
    let selectionBackground = try #require(SRGBColor(rawValue: "#040506"))
    let changedSelection = TerminalColors(
      foreground: package.terminal.foreground,
      background: package.terminal.background,
      cursor: package.terminal.cursor,
      selectionForeground: selectionForeground,
      selectionBackground: selectionBackground,
      ansi: package.terminal.ansi
    )
    let variant = ThemePackage(
      packageURL: package.packageURL,
      schemaVersion: package.schemaVersion,
      id: package.id,
      displayName: package.displayName,
      appearance: package.appearance,
      semantic: package.semantic,
      terminal: changedSelection,
      backgrounds: package.backgrounds,
      backgroundData: package.backgroundData,
      mappings: package.mappings
    )
    #expect(
      ThemePreviewRenderer().render(package: package)
        != ThemePreviewRenderer().render(package: variant)
    )
  }
}
