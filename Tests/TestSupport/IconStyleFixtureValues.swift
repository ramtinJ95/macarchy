import Foundation
import ThemeCore

package enum IconStyleFixtureValues {
  package static let original = MacOSIconStyle(style: "RegularLight", tint: "None", custom: nil)
  package static let applied = MacOSIconStyle(style: "TintedDark", tint: "Other", custom: "#0011ff")
  package static let pending = MacOSIconStyle(
    style: "TintedLight", tint: "Other", custom: "#ff1100")
  package static let external = MacOSIconStyle(style: "ClearLight", tint: "Green", custom: nil)
  package static let next = MacOSIconStyle(style: "TintedDark", tint: "Other", custom: "#aa00ff")
}

extension MacOSIconStyle {
  package var fixtureReply: String {
    let value: [String: Any] = [
      "style": style, "tint": tint, "custom": custom.map { $0 as Any } ?? NSNull(),
    ]
    return String(
      decoding: try! JSONSerialization.data(
        withJSONObject: ["ok": true, "value": value],
        options: [.sortedKeys]), as: UTF8.self)
  }
}
