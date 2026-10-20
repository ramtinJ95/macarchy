import Foundation
import Testing

@testable import MacarchyCLI

struct SketchyBarQueryReplyTests {
  private struct Texts: Decodable {
    struct Text: Decodable {
      let value: String
      let drawing: String
    }
    let icon: Text
    let label: Text
  }

  @Test(arguments: [
    #"Theme from "Shaft""#, #"AC\DC"#, #"ends with \"#, #"say \"hi\""#, "line one\nline two",
    "tab\tand bell\u{7}", "🎸 Café ", #"", "drawing": "off"#, #"a "value": "b"#, "",
  ])
  func decodesBarTextAsSketchyBarPrintsIt(text: String) throws {
    let reply = SketchyBarNativeQuery.item(
      name: "macarchy.media.title", icon: text, label: text, labelDrawing: "off")
    let texts = try SketchyBarQueryReply.decode(Texts.self, from: reply)
    #expect(texts.icon.value == text)
    #expect(texts.icon.drawing == "on")
    #expect(texts.label.value == text)
    #expect(texts.label.drawing == "off")
    #expect(try SketchyBarLabelQuery.value(from: reply) == text)
  }

  @Test func truncatedRepliesStillFail() throws {
    let reply = SketchyBarNativeQuery.item(name: "macarchy.wifi.ssid", label: #"Cafe "Guest""#)
    let end = try #require(reply.range(of: "Guest")).upperBound
    #expect(throws: DecodingError.self) {
      try SketchyBarLabelQuery.value(from: String(reply[..<end]))
    }
  }
}
