import Foundation

/// Stored state, compared at eight-bit sRGB precision. A request may use "-" to keep tint.
package struct MacOSIconStyle: Codable, Equatable, Sendable {
  package let style: String
  package let tint: String
  package let custom: String?

  package init(style: String, tint: String, custom: String?) {
    self.style = style
    self.tint = tint
    self.custom = custom
  }

  package static let styles = [
    "RegularAutomatic", "RegularLight", "RegularDark", "ClearAutomatic", "ClearLight",
    "ClearDark", "TintedAutomatic", "TintedLight", "TintedDark",
  ]
  package static let tints = [
    "None", "Hardware", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink",
    "Graphite", "Other",
  ]

  package var isValidStoredValue: Bool {
    Self.styles.contains(style) && Self.tints.contains(tint)
      && (custom == nil || custom.flatMap(SRGBColor.init(rawValue:)) != nil)
  }

  package var name: String { "\(style) / \(tint) / \(custom ?? "no custom tint")" }

  package static func desired(
    _ style: ThemeIconStyle, appearance: ThemeAppearance, accent: SRGBColor
  ) -> Self {
    let suffix = appearance == .dark ? "Dark" : "Light"
    switch style {
    case .default: return Self(style: "RegularLight", tint: "-", custom: nil)
    case .dark: return Self(style: "RegularDark", tint: "-", custom: nil)
    case .clear: return Self(style: "Clear" + suffix, tint: "-", custom: nil)
    case .tinted:
      return Self(style: "Tinted" + suffix, tint: "Other", custom: accent.rawValue.lowercased())
    }
  }

  /// The journal stores effective native values, never the keep-tint command placeholder.
  package func keepingTint(from current: Self) -> Self {
    tint == "-"
      ? Self(style: style, tint: current.tint, custom: custom ?? current.custom) : self
  }
}
