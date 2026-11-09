import Foundation

/// Whether a theme's colors read well in a terminal and an editor: unreadable findings are colors
/// people cannot read, and weak ones are worth a second look. Nothing here blocks a theme.
///
/// Ported from Scene's `PaletteCheck` (Packages/SceneKit/Sources/SceneThemes/PaletteCheck.swift
/// at 48a69ccae09e0490e2400cf8053fc4a9a5ceff7f), Copyright (c) 2026 InsaneArts, MIT licence; see
/// THIRD_PARTY_NOTICES.md. The thresholds are WCAG contrast ratios, calibrated on the Omarchy
/// palettes, plus OKLab distance for hues that look alike. Scene also compares its syntax
/// number color as orange; Macarchy themes have no such color, so orange is left out.
public struct PaletteLegibility: Codable, Equatable, Sendable {
  public var unreadable: [String] = []
  public var weak: [String] = []

  public init(package: ThemePackage) {
    self.init(
      appearance: package.appearance, semantic: package.semantic, terminal: package.terminal)
  }

  init(appearance: ThemeAppearance, semantic: SemanticColors, terminal: TerminalColors) {
    let background = semantic.background
    let ansi = terminal.ansi
    let light = background.luminance > 0.4
    func need(
      _ name: String, _ color: SRGBColor, on otherName: String, _ other: SRGBColor,
      _ minimum: Double, _ good: Double
    ) {
      let ratio = color.contrast(with: other)
      let text = "\(name) \(color.rawValue) on \(otherName): \(String(format: "%.2f", ratio))"
      if ratio < minimum {
        unreadable.append("\(text), needs \(Self.format(minimum))")
      } else if ratio < good {
        weak.append("\(text), \(Self.format(good)) reads better")
      }
    }
    need("Text", semantic.text, on: "Background", background, 4.5, 7)
    need("Dim text", semantic.mutedText, on: "Background", background, 2.2, 3)
    need("Accent", semantic.accent, on: "Background", background, 2.5, 3)
    need("Text", semantic.text, on: "Selection", semantic.selection, 3.5, 4.5)
    // A light theme prints yellow and cyan darker than a dark theme needs.
    let hues = [
      ("Red", ansi[1]), ("Green", ansi[2]), ("Yellow", ansi[3]), ("Blue", ansi[4]),
      ("Magenta", ansi[5]), ("Cyan", ansi[6]),
    ]
    for (name, color) in hues {
      need(name, color, on: "Background", background, light ? 2 : 3, light ? 3 : 4.5)
    }
    if semantic.selection.contrast(with: background) < 1.15 {
      weak.append("Selection \(semantic.selection.rawValue) is hard to see on the background")
    }
    if semantic.border.contrast(with: background) < 1.3 {
      weak.append("Borders \(semantic.border.rawValue) are hard to see on the background")
    }

    let named = [
      ("Red", ansi[1]), ("Yellow", ansi[3]), ("Green", ansi[2]), ("Cyan", ansi[6]),
      ("Blue", ansi[4]), ("Magenta", ansi[5]),
    ]
    for first in named.indices {
      for second in named.indices where second > first {
        let distance = named[first].1.oklabDistance(to: named[second].1)
        if distance < 0.06 {
          weak.append(
            "\(named[first].0) and \(named[second].0) look alike "
              + "(\(String(format: "%.3f", distance)))")
        }
      }
    }
    let grays = named.filter { $0.1.oklabChroma < 0.03 }.map(\.0)
    if !grays.isEmpty {
      weak.append(
        "No color in \(grays.joined(separator: ", ")). Fine if the theme uses one hue on purpose.")
    }
    if light != (appearance == .light) {
      unreadable.append(
        "The \(appearance.rawValue) theme has a \(light ? "light" : "dark") background")
    }
  }

  public var isEmpty: Bool { unreadable.isEmpty && weak.isEmpty }

  /// Text lines under a report's `Legibility:` heading.
  public var lines: [String] {
    guard !isEmpty else { return ["Legibility: no problems found."] }
    return ["Legibility (reported only; nothing was blocked):"]
      + unreadable.map { "- Unreadable: \($0)" } + weak.map { "- Weak: \($0)" }
  }

  private static func format(_ threshold: Double) -> String {
    threshold == threshold.rounded() ? String(Int(threshold)) : String(threshold)
  }
}

extension SRGBColor {
  /// WCAG relative luminance.
  var luminance: Double {
    let (red, green, blue) = linearComponents
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
  }

  /// WCAG contrast ratio between two opaque colors, 1...21.
  func contrast(with other: SRGBColor) -> Double {
    let (first, second) = (luminance, other.luminance)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  /// OKLab, the perceptual space the hue checks measure in.
  var oklab: (l: Double, a: Double, b: Double) {
    let (red, green, blue) = linearComponents
    let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
    let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
    let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    )
  }

  /// Perceived difference; about 0.02 is just noticeable.
  func oklabDistance(to other: SRGBColor) -> Double {
    let (x, y) = (oklab, other.oklab)
    return ((x.l - y.l) * (x.l - y.l) + (x.a - y.a) * (x.a - y.a) + (x.b - y.b) * (x.b - y.b))
      .squareRoot()
  }

  var oklabChroma: Double {
    let lab = oklab
    return (lab.a * lab.a + lab.b * lab.b).squareRoot()
  }

  private var linearComponents: (Double, Double, Double) {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    let (red, green, blue) = components
    return (linear(red), linear(green), linear(blue))
  }
}
