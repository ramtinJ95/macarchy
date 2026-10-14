import CoreGraphics
import ThemeCore

enum OutlineGeometry {
  static let width = CGFloat(BordersPalette.width)
  /// JankyBorders 1.9.0's fallback for missing or non-positive native radii.
  static let defaultCornerRadius: CGFloat = 9

  static func resolvedCornerRadius(_ reported: CGFloat?) -> CGFloat {
    guard let reported, reported.isFinite, reported > 0 else { return defaultCornerRadius }
    return reported
  }

  /// Converts window-server global coordinates (origin at the primary display's
  /// top-left, y down) to AppKit global coordinates (origin at the primary screen's
  /// bottom-left, y up).
  static func appKitRect(fromWindowServer rect: CGRect, primaryScreenFrame: CGRect) -> CGRect {
    CGRect(
      x: rect.minX, y: primaryScreenFrame.maxY - rect.maxY,
      width: rect.width, height: rect.height)
  }

  /// The outline window extends half a stroke width beyond the target on every side.
  static func outlineFrame(around target: CGRect) -> CGRect {
    target.insetBy(dx: -width / 2, dy: -width / 2)
  }

  /// The stroke is centered on the target edge; the inner half is occluded by the
  /// target because the outline panel is ordered below it.
  static func strokeRect(in bounds: CGRect) -> CGRect {
    bounds.insetBy(dx: width / 2, dy: width / 2)
  }

  static func pathRadius(for rect: CGRect, cornerRadius: CGFloat = defaultCornerRadius) -> CGFloat {
    max(0, min(resolvedCornerRadius(cornerRadius), rect.width / 2, rect.height / 2))
  }
}

/// Frame changes do not require an unchanged window stack to be reordered.
enum OutlineOrdering {
  static func needsOrder(
    isVisible: Bool, previousTarget: UInt32?, target: UInt32, levelChanged: Bool
  ) -> Bool {
    !isVisible || previousTarget != target || levelChanged
  }
}

/// An opaque sRGB stroke color from the active palette's `#RRGGBB` accent.
struct OutlineColor: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double

  init?(accent: String) {
    let bytes = Array(accent.utf8)
    guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return nil }
    var value: UInt32 = 0
    for byte in bytes.dropFirst() {
      guard let digit = Self.hexDigit(byte) else { return nil }
      value = value << 4 | UInt32(digit)
    }
    red = Double(value >> 16 & 0xff) / 255
    green = Double(value >> 8 & 0xff) / 255
    blue = Double(value & 0xff) / 255
  }

  var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

  private static func hexDigit(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
  }
}
