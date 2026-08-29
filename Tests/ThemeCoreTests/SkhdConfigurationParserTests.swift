import Foundation
import Testing

@testable import ThemeCore

struct SkhdConfigurationParserTests {
  private let parser = SkhdConfigurationParser()

  @Test
  func personalFixtureHasExactCoverageWithoutDiagnostics() throws {
    let result = parser.parse(try fixtureContents("personal.skhdrc"))

    #expect(result.bindings.count == 57)
    #expect(Set(result.bindings.map(\.identity)).count == 57)
    #expect(result.diagnostics.isEmpty)
    #expect(result.bindings.first?.identity == "alt-j")
    #expect(result.bindings.last?.identity == "ctrl+alt-r")
    #expect(
      result.bindings.first { $0.identity == "cmd-k" }?.command
        == "/Users/ramtin/.local/bin/macarchy keybindings show"
    )
  }

  @Test
  func parsesTheSupportedPersonalSyntaxWithoutInterpretingCommands() {
    let source = """
      # disabled
      # cmd - k : open -a 'kitty'
      alt - j : yabai -m window --focus south
      shift + alt - s : yabai -m window --display west; yabai -m display --focus west;
      shift + alt - a : yabai -m window --resize left:-20:0
      alt - m : osascript -e 'tell application id "com.spotify.client" to reopen'
      """

    let result = parser.parse(source)

    #expect(result.diagnostics.isEmpty)
    #expect(result.bindings.count == 4)
    #expect(result.bindings[0].identity == "alt-j")
    #expect(result.bindings[1].identity == "alt+shift-s")
    #expect(
      result.bindings[1].command
        == "yabai -m window --display west; yabai -m display --focus west;"
    )
    #expect(result.bindings[2].command == "yabai -m window --resize left:-20:0")
  }

  @Test
  func diagnosesDuplicateEffectiveChordsAfterModifierNormalization() {
    let result = parser.parse(
      """
      shift + cmd - f : first
      cmd + shift - f : second
      """
    )

    #expect(result.bindings.map(\.identity) == ["cmd+shift-f", "cmd+shift-f"])
    #expect(
      result.diagnostics
        == [
          SkhdDiagnostic(
            code: .duplicateChord,
            line: 2,
            relatedLine: 1,
            message: "chord 'cmd + shift - f' duplicates the binding on line 1"
          )
        ]
    )
  }

  @Test
  func diagnosesDuplicateKeycodesAfterWidthNormalization() {
    let result = parser.parse(
      """
      cmd - 0xA : first
      cmd - 0x0A : second
      """
    )

    #expect(result.bindings.map(\.identity) == ["cmd-0x0A", "cmd-0x0A"])
    #expect(result.diagnostics.map(\.code) == [.duplicateChord])
  }

  @Test
  func diagnosesEveryUnsupportedEnabledLine() {
    let result = parser.parse(
      """
      :: resize
      cmd - return
      cmd - banana : command
      cmd - x :
      cmd - y : first \\
        && second
      alt - j : valid
      """
    )

    #expect(result.bindings.map(\.identity) == ["alt-j"])
    #expect(result.diagnostics.map(\.line) == [1, 2, 3, 4, 5])
    #expect(result.diagnostics.allSatisfy { $0.code == .unsupportedSyntax })
  }

  @Test
  func acceptsDocumentedNamedNumericAndKeycodeChords() {
    let result = parser.parse(
      """
      return : named
      cmd - 7 : numeric
      cmd - 0xA : short keycode
      cmd - 0x3C : keycode
      """
    )

    #expect(result.diagnostics.isEmpty)
    #expect(
      result.bindings.map(\.identity) == ["return", "cmd-7", "cmd-0x0A", "cmd-0x3C"]
    )
  }

  @Test
  func rejectsArbitraryIdentifiersPunctuationAndMalformedKeycodes() {
    let result = parser.parse(
      """
      banana : arbitrary
      cmd - / : punctuation
      cmd - 0x : empty keycode
      cmd - 0x123 : oversized keycode
      cmd - 0xGG : malformed keycode
      cmd - 0x3c : lowercase hex
      CMD - a : uppercase modifier
      cmd - A : uppercase letter
      fn - left : explicit fn
      """
    )

    #expect(result.bindings.isEmpty)
    #expect(result.diagnostics.map(\.line) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
  }

  @Test
  func acceptsCRLFAndTrimsOnlyCommandBoundaryWhitespace() {
    let result = parser.parse(
      "alt - j : printf 'a  b'  \r\nalt - k : printf 'c  d'\r\n"
    )

    #expect(result.diagnostics.isEmpty)
    #expect(result.bindings.map(\.command) == ["printf 'a  b'", "printf 'c  d'"])
  }

  @Test
  func trailingWhitespaceAfterBackslashDoesNotConsumeTheNextBinding() {
    let result = parser.parse("alt - j : printf first \\   \nalt - k : printf second\n")

    #expect(result.diagnostics.isEmpty)
    #expect(result.bindings.map(\.identity) == ["alt-j", "alt-k"])
  }

  private func fixtureContents(_ name: String) throws -> String {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures/Skhd", directoryHint: .isDirectory)
    return try String(contentsOf: root.appending(path: name), encoding: .utf8)
  }
}
