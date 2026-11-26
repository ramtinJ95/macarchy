import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarSymbolFontTests {
  // These are the actual pre-remap factory glyphs, not values taken from the new map.
  static let pairs: [(String, String)] = [
    ("\u{f0f4}", "\u{100e19}"), ("\u{f130}", "\u{1002b1}"),
    ("\u{f131}", "\u{1002b3}"), ("\u{f26c}", "\u{10114b}"),
    ("\u{f04c}", "\u{100286}"), ("\u{f1eb}", "\u{100647}"),
    ("\u{f127}", "\u{100648}"), ("\u{f001}", "\u{10046a}"),
  ]

  @Test(arguments: pairs, ["SF Pro:Semibold:14.00", "MesloLGS Nerd Font Mono:Regular:14.00"])
  func retainedAndFreshBarsUseTheGlyphTheirActualFontContains(
    pair: (String, String), font: String
  ) throws {
    let retained = font.hasPrefix("SF Pro:")
    let expected = retained ? pair.1 : pair.0
    var checks: [(String, String)] = []
    let renderer = SketchyBarSymbolFont(supports: { face, glyph in
      checks.append((face, glyph))
      return true
    })
    let log = Calls(font: font)
    #expect(try renderer.icon(pair.0, item: "macarchy.item", bar: log.bar) == expected)
    #expect(log.arguments == [["--query", "macarchy.item"]])
    #expect(checks.map(\.0) == [retained ? "SFPro-Semibold" : "MesloLGSNFM-Regular"])
    #expect(checks.map(\.1) == [expected])
  }

  @Test(arguments: [
    "SF Pro:Bold:13.00", "MesloLGS Nerd Font Mono:Bold:13.00",
    "Other Nerd Font:Regular:13.00", "SF Pro:Bold:nan", "SF Pro:Bold:0", "invalid",
  ])
  func missingFontsAndUnsupportedContractsFailWithoutSubstitution(font: String) {
    let log = Calls(font: font)
    let renderer = SketchyBarSymbolFont(supports: { _, _ in false })
    let error = #expect(throws: SketchyBarSymbolFont.Failure.self) {
      try renderer.icon("\u{f1eb}", item: "macarchy.wifi", bar: log.bar)
    }
    #expect(error?.description.contains("macarchy setup plan") == true)
    #expect(log.arguments == [["--query", "macarchy.wifi"]])
  }

  @Test(arguments: ["malformed", "missing-font", "wrong-item", "rejected"])
  func invalidQueriesNeverGuessAFont(condition: String) {
    let bar = SketchyBarControl(
      processRunner: ProcessRunner { _ in
        let output =
          switch condition {
          case "malformed": "not json"
          case "missing-font": #"{"name":"macarchy.wifi","icon":{}}"#
          default: #"{"name":"wrong","icon":{"font":"SF Pro:Bold:13.00"}}"#
          }
        return .init(terminationStatus: condition == "rejected" ? 1 : 0, output: output)
      }, failure: { _, _ in MessageError("bar refused") })
    #expect(throws: (any Error).self) {
      try SketchyBarSymbolFont(supports: { _, _ in
        Issue.record("invalid query cannot reach glyph validation")
        return true
      }).icon("\u{f1eb}", item: "macarchy.wifi", bar: bar)
    }
  }

  @Test func realCoreTextChecksRejectMissingFacesAndFallbackRuns() {
    #expect(SketchyBarSymbolFont.supports("Helvetica", "A"))
    #expect(!SketchyBarSymbolFont.supports("Macarchy-Missing-\(UUID())", "A"))
    #expect(!SketchyBarSymbolFont.supports("Helvetica", "\u{f1eb}"))
    #expect(!SketchyBarSymbolFont.supports("Helvetica", "\u{100647}"))
    #expect(!SketchyBarSymbolFont.supports("Helvetica", ""))
  }

  @Test(arguments: ["SF Pro", "MesloLGS Nerd Font Mono"])
  func companionHelpersPairEveryStateWithTheRetainedOrFreshFont(family: String) throws {
    for (companion, icons) in [
      (SketchyBarClockCompanion.keepAwake, ["\u{f0f4}"]),
      (.microphone, ["\u{f130}", "\u{f131}"]),
      (.saverPaused, ["\u{f26c}", "\u{f04c}"]),
    ] {
      for icon in icons {
        let log = Calls(font: "\(family):Regular:14.00")
        try SketchyBarCompanionToggle(
          symbolFont: .init(supports: { _, _ in true }),
          companion: companion, stateRoot: CompanionToggleHarness.stateRoot,
          processRunner: log.runner,
          read: {
            .init(lit: false, olderBarClick: nil, icon: icon, detail: "Off", click: [])
          }, launch: { _ in Issue.record("unexpected launch") }
        ).execute(sender: "forced", accent: "accent", muted: "muted")
        let expected = family == "SF Pro" ? Self.pairs.first { $0.0 == icon }!.1 : icon
        #expect(log.arguments.first == ["--query", companion.item])
        #expect(log.arguments.last?.contains("icon=\(expected)") == true)
      }
    }
  }

  @Test func aMissingCompanionFontFailsBeforeSendingAnyGlyph() {
    let log = Calls(font: "MesloLGS Nerd Font Mono:Regular:14.00")
    let helper = SketchyBarCompanionToggle(
      symbolFont: .init(supports: { _, _ in false }),
      companion: .keepAwake, stateRoot: CompanionToggleHarness.stateRoot,
      processRunner: log.runner,
      read: {
        .init(lit: false, olderBarClick: nil, icon: "\u{f0f4}", detail: "Off", click: [])
      }, launch: { _ in Issue.record("unexpected launch") })
    #expect(throws: SketchyBarSymbolFont.Failure.self) {
      try helper.execute(sender: "forced", accent: "accent", muted: "muted")
    }
    #expect(log.arguments == [["--query", "macarchy.keep-awake"]])
  }

  private final class Calls: Sendable {
    let font: String
    private let values = Mutex([[String]]())
    init(font: String) { self.font = font }
    var arguments: [[String]] { values.withLock { $0 } }
    var runner: ProcessRunner {
      ProcessRunner { [self] request in
        values.withLock { $0.append(request.arguments) }
        let item = request.arguments.count > 1 ? request.arguments[1] : ""
        return .init(
          terminationStatus: 0,
          output: #"{"name":"\#(item)","icon":{"font":"\#(font)"}}"#)
      }
    }
    var bar: SketchyBarControl {
      .init(processRunner: runner, failure: { _, _ in MessageError("bar refused") })
    }
  }
}
