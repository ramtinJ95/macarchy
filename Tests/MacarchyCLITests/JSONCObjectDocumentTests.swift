import Foundation
import Testing

@testable import MacarchyCLI

struct JSONCObjectDocumentTests {
  private let target = URL(filePath: "/settings.json")

  private func document(_ text: String) throws -> JSONCObjectDocument {
    try JSONCObjectDocument(data: Data(text.utf8), id: "zed", target: target)
  }

  private func text(_ data: Data?) -> String? {
    data.map { String(decoding: $0, as: UTF8.self) }
  }

  private let member = Array(#""theme": "Macarchy""#.utf8)

  @Test func commentsAndTrailingCommasAreAcceptedAndTopLevelMembersFound() throws {
    let parsed = try document(
      """
      // Zed settings
      {
        /* block */ "theme": { "mode": "system", "light": "One Light", "dark": "One Dark", },
        "url": "https://example.com/a//b", // a URL is not a comment
        "list": [1, 2,],
      }
      """)

    #expect(parsed.members.map(\.key) == ["theme", "url", "list"])
    #expect(
      parsed.memberBytes("theme").map { String(decoding: $0, as: UTF8.self) }
        == #""theme": { "mode": "system", "light": "One Light", "dark": "One Dark", }"#)
    #expect(parsed.member("list")?.separatorAfter != nil)
  }

  @Test(arguments: [
    "[]", "{\"a\": 1} x", "{\"a\": 1, \"a\": 2}", "{\"a\": }", "{\"a\": 1 /* open", "{\"a\": tru}",
    "{,}", "{} /* unterminated",
  ])
  func malformedDocumentsAreRejected(_ text: String) {
    #expect(throws: SetupOwnershipError.self) { try document(text) }
  }

  @Test func replacingAMemberKeepsEveryOtherByte() throws {
    let original = """
      {
        // keep me
        "theme": { "mode": "system", "light": "A", "dark": "B" }, // and me
        "buffer_font_size": 15,
      }
      """
    let parsed = try document(original)

    let replaced = try #require(parsed.replacingMember("theme", with: member))

    #expect(
      text(replaced) == """
        {
          // keep me
          "theme": "Macarchy", // and me
          "buffer_font_size": 15,
        }
        """)
    let restored = try document(text(replaced)!).replacingMember(
      "theme", with: try #require(parsed.memberBytes("theme")))
    #expect(text(restored) == original)
  }

  @Test(arguments: [
    (
      "{\n  // note\n  \"vim_mode\": true\n}\n",
      "{\n  // note\n  \"theme\": \"Macarchy\",\n  \"vim_mode\": true\n}\n"
    ),
    ("{\"vim_mode\": true}", "{\"theme\": \"Macarchy\", \"vim_mode\": true}"),
    ("{\n\"vim_mode\": true\n}", "{\n\"theme\": \"Macarchy\",\n\"vim_mode\": true\n}"),
    ("{}", "{\"theme\": \"Macarchy\"}"),
    ("{ /* c */ \"a\": 1 }", "{ /* c */ \"theme\": \"Macarchy\", \"a\": 1 }"),
  ])
  func anInsertedMemberIsRemovedByteForByte(original: String, inserted: String) throws {
    let added = try document(original).insertingFirstMember(member)

    #expect(text(added) == inserted)
    #expect(text(try document(inserted).removingMember("theme")) == original)
  }

  @Test func removingAMemberWithACommentBesideItKeepsTheComment() throws {
    let removed = try document(
      "{\n  \"theme\": \"Macarchy\", // mine\n  \"a\": 1\n}"
    ).removingMember("theme")

    #expect(text(removed) == "{\n   // mine\n  \"a\": 1\n}")
  }

  @Test func removingTheLastMemberTakesThePrecedingComma() throws {
    #expect(
      text(try document("{\"a\": 1, \"theme\": \"Macarchy\"}").removingMember("theme"))
        == "{\"a\": 1}")
    #expect(
      text(try document("{\"a\": 1, \"theme\": \"Macarchy\",}").removingMember("theme"))
        == "{\"a\": 1}")
    #expect(try document("{\"a\": 1}").removingMember("theme") == nil)
  }

  @Test(arguments: [
    (#"{"theme": "Macarchy" /* keep */, "a": 1}"#, #"{ /* keep */ "a": 1}"#),
    (#"{"a": 1, /* keep */ "theme": "Macarchy"}"#, #"{"a": 1 /* keep */ }"#),
    (
      #"{"a": 1, /* before */ "theme": "Macarchy" /* after */,}"#,
      #"{"a": 1 /* before */  /* after */}"#
    ),
    (#"{"theme": "Macarchy" /* keep */,}"#, #"{ /* keep */}"#),
  ])
  func removalPreservesCommentsOnEitherSideOfCommas(original: String, expected: String) throws {
    #expect(text(try document(original).removingMember("theme")) == expected)
    _ = try document(expected)
  }
}
