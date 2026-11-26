import CoreText
import Foundation
import ThemeCore

/// A retained generated bar can outlive the CLI its plugins invoke. Select glyphs
/// from the item's actual font contract, not the running executable's version.
struct SketchyBarSymbolFont {
  var supports: (String, String) -> Bool = Self.supports

  func icon(_ icon: String, item: String, bar: SketchyBarControl) throws -> String {
    struct Item: Decodable {
      struct Icon: Decodable { let font: String }
      let name: String
      let icon: Icon
    }
    let query = try SketchyBarQueryReply.decode(Item.self, from: bar(["--query", item]))
    guard query.name == item else { throw Failure(detail: "unexpected item in font query") }
    let parts = query.icon.font.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, let size = Double(parts[2]), size.isFinite, size > 0 else {
      throw Failure(detail: "invalid icon font: \(query.icon.font)")
    }
    let glyph: String
    let face: String
    switch (String(parts[0]), String(parts[1])) {
    case (SketchyBarSymbol.fontFamily, "Regular"), (SketchyBarSymbol.fontFamily, "Bold"):
      glyph = icon
      guard
        let declaredFace = SketchyBarSymbol.postScriptNames.first(where: {
          $0.hasSuffix("-\(parts[1])")
        })
      else { throw Failure(detail: "no declared symbol face for \(parts[1])") }
      face = declaredFace
    case ("SF Pro", "Regular"), ("SF Pro", "Semibold"), ("SF Pro", "Bold"):
      guard let retained = Self.retainedSF[icon] else {
        throw Failure(detail: "no retained SF glyph for \(icon)")
      }
      glyph = retained
      face = "SFPro-\(parts[1])"
    default:
      throw Failure(detail: "unsupported icon font: \(query.icon.font)")
    }
    guard supports(face, glyph) else {
      throw Failure(detail: "\(face) is missing or cannot render the icon without fallback")
    }
    return glyph
  }

  /// Only symbols emitted by CLI helpers need pre-0.18.1 compatibility. Static
  /// volume/battery/arrows already live with their matching fonts in old scripts.
  static let retainedSF = [
    SketchyBarSymbol.coffee.rawValue: "\u{100e19}",
    SketchyBarSymbol.microphone.rawValue: "\u{1002b1}",
    SketchyBarSymbol.microphoneMuted.rawValue: "\u{1002b3}",
    SketchyBarSymbol.screensaver.rawValue: "\u{10114b}",
    SketchyBarSymbol.pause.rawValue: "\u{100286}",
    SketchyBarSymbol.wifi.rawValue: "\u{100647}",
    SketchyBarSymbol.disconnected.rawValue: "\u{100648}",
    SketchyBarSymbol.music.rawValue: "\u{10046a}",
  ]

  static func supports(_ face: String, _ glyph: String) -> Bool {
    // Constructing a font by name alone silently substitutes when it is absent.
    guard (CTFontManagerCopyAvailablePostScriptNames() as! [String]).contains(face) else {
      return false
    }
    let font = CTFontCreateWithName(face as CFString, 14, nil)
    let text = NSAttributedString(
      string: glyph, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as! [CTRun]
    return !runs.isEmpty
      && runs.allSatisfy { run in
        let attributes = CTRunGetAttributes(run) as! [String: Any]
        guard let actual = attributes[kCTFontAttributeName as String] else { return false }
        guard CTFontCopyPostScriptName(actual as! CTFont) as String == face else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        return !glyphs.isEmpty && glyphs.allSatisfy { $0 != 0 }
      }
  }

  struct Failure: Error, CustomStringConvertible {
    let detail: String
    var description: String {
      "SketchyBar symbol font: \(detail). Run macarchy setup plan and apply to provision "
        + "the required Meslo font and regenerate the bar; no substitute font was used."
    }
  }
}
