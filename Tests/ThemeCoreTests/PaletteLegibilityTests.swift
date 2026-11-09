import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct PaletteLegibilityTests {
  @Test func bundledThemesHaveNoUnreadableColors() throws {
    let repository = try ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes"))
    let weak: [String: [String]] = [
      "catppuccin-mocha": [],
      "kanagawa-wave": [
        "Red #c34043 on Background: 3.22, 4.5 reads better",
        "Green and Cyan look alike (0.044)",
      ],
      "tokyo-night": ["Dim text #565f89 on Background: 2.76, 3 reads better"],
    ]

    for (id, expected) in weak {
      let legibility = PaletteLegibility(package: try repository.package(id: id))
      #expect(legibility.unreadable.isEmpty, "\(id)")
      #expect(legibility.weak == expected, "\(id)")
    }
  }

  @Test func aLowContrastPaletteIsReportedColorByColor() {
    let legibility = PaletteLegibility(
      appearance: .dark,
      semantic: semantic(
        background: "#1a1b26", text: "#565f89", muted: "#2a2b36", accent: "#3b3c47",
        selection: "#1c1d28", border: "#1d1e29"),
      terminal: terminal(hues: ["#f7768e", "#f7768f", "#444444", "#7aa2f7", "#ad8ee6", "#449dab"]))

    #expect(
      legibility.unreadable == [
        "Text #565f89 on Background: 2.76, needs 4.5",
        "Dim text #2a2b36 on Background: 1.22, needs 2.2",
        "Accent #3b3c47 on Background: 1.57, needs 2.5",
        "Text #565f89 on Selection: 2.70, needs 3.5",
        "Yellow #444444 on Background: 1.75, needs 3",
      ])
    #expect(
      legibility.weak == [
        "Selection #1c1d28 is hard to see on the background",
        "Borders #1d1e29 are hard to see on the background",
        "Red and Green look alike (0.001)",
        "No color in Yellow. Fine if the theme uses one hue on purpose.",
      ])
    #expect(legibility.lines.first == "Legibility (reported only; nothing was blocked):")
    #expect(legibility.lines[1] == "- Unreadable: Text #565f89 on Background: 2.76, needs 4.5")
    #expect(
      legibility.lines.last
        == "- Weak: No color in Yellow. Fine if the theme uses one hue on purpose.")
  }

  @Test func aLegiblePaletteHasNothingToReport() {
    let legibility = PaletteLegibility(
      appearance: .dark, semantic: goodDark, terminal: terminal(hues: goodHues))

    #expect(legibility.isEmpty)
    #expect(legibility.lines == ["Legibility: no problems found."])
  }

  @Test func aLightBackgroundAcceptsDarkerHuesAndMustBeDeclaredLight() {
    let light = semantic(
      background: "#fafafa", text: "#383a42", muted: "#696c77", accent: "#4078f2",
      selection: "#d0d0d0", border: "#a0a1a7")
    let hues = ["#e45649", "#50a14f", "#d19a00", "#4078f2", "#a626a4", "#0184bc"]

    let declaredLight = PaletteLegibility(
      appearance: .light, semantic: light, terminal: terminal(hues: hues))
    let declaredDark = PaletteLegibility(
      appearance: .dark, semantic: light, terminal: terminal(hues: hues))
    let darkDeclaredLight = PaletteLegibility(
      appearance: .light, semantic: goodDark, terminal: terminal(hues: goodHues))

    // 2.41 is below a dark background's minimum of 3 but above a light one's 2.
    #expect(declaredLight.unreadable.isEmpty)
    #expect(declaredLight.weak == ["Yellow #d19a00 on Background: 2.41, 3 reads better"])
    #expect(declaredDark.unreadable.contains("The dark theme has a light background"))
    #expect(darkDeclaredLight.unreadable == ["The light theme has a dark background"])
  }

  @Test func contrastAndLuminanceFollowWCAG() throws {
    let black = try #require(SRGBColor(rawValue: "#000000"))
    let white = try #require(SRGBColor(rawValue: "#ffffff"))

    #expect(black.luminance == 0)
    #expect(abs(white.luminance - 1) < 1e-9)
    #expect(abs(black.contrast(with: white) - 21) < 1e-9)
    #expect(black.contrast(with: white) == white.contrast(with: black))
    #expect(white.oklabChroma < 0.001)
  }
}

private let goodDark = semantic(
  background: "#1a1b26", text: "#c0caf5", muted: "#9aa5ce", accent: "#7aa2f7",
  selection: "#414868", border: "#565f89")
private let goodHues = ["#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff"]

private func color(_ value: String) -> SRGBColor { SRGBColor(rawValue: value)! }

private func semantic(
  background: String, text: String, muted: String, accent: String, selection: String,
  border: String
) -> SemanticColors {
  SemanticColors(
    background: color(background), surface: color(background), overlay: color(selection),
    border: color(border), text: color(text), mutedText: color(muted), accent: color(accent),
    selection: color(selection), info: color(accent), success: color(accent),
    warning: color(accent), error: color(accent))
}

/// ANSI 0 is black, 1–6 are `hues` in order red, green, yellow, blue, magenta, cyan, and the rest
/// white; the checks read only 1–6.
private func terminal(hues: [String]) -> TerminalColors {
  let ansi = [color("#000000")] + hues.map(color) + Array(repeating: color("#ffffff"), count: 9)
  return TerminalColors(
    foreground: ansi[7], background: ansi[0], cursor: ansi[7], selectionForeground: ansi[7],
    selectionBackground: ansi[0], ansi: ansi)
}
