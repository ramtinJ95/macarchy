import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct AgentTUISetupTests {
  private let ownedIntegrationIDs = [
    "pi.selector",
    "pi.theme-link",
    "tuicr.selector",
    "tuicr.theme-link",
    "tuicr.syntax-link",
    "codex.selector",
    "codex.theme-link",
  ]

  @Test
  func ownedSeamsPreserveUnrelatedBytesAndRoundTripAsOneManifestGroup() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let tuicr = "show_help = true\r\n"
    let codex = "model = \"gpt-5\"\r\n\r\n[tui]\r\nanimations = false\r\n"
    let providerRewrite =
      "{\n  \"lastChangelogVersion\": \"9.9.9\",\n  \"theme\": \"macarchy-current\",\n  \"provider\": \"anthropic\"\n}\n"
    try fixture.tearDownLegacyOwnership(
      [
        fixture.legacyPiSelector(contents: providerRewrite),
        fixture.legacyThemeLink(SetupOwnershipManager.piThemeLinkID),
        fixture.legacyFileRecord(
          SetupOwnershipManager.tuicrSelectorID,
          original: tuicr,
          installed: "theme = \"macarchy-current\"\r\n" + tuicr
        ),
        fixture.legacyThemeLink(SetupOwnershipManager.tuicrThemeLinkID),
        fixture.legacyThemeLink(SetupOwnershipManager.tuicrSyntaxLinkID),
        fixture.legacyFileRecord(
          SetupOwnershipManager.codexSelectorID,
          original: codex,
          installed:
            "model = \"gpt-5\"\r\n\r\n[tui]\r\ntheme = \"macarchy-current\"\r\nanimations = false\r\n"
        ),
        fixture.legacyThemeLink(SetupOwnershipManager.codexThemeLinkID),
      ],
      expectingRemoved: ownedIntegrationIDs)
    #expect(
      try String(contentsOf: fixture.piConfiguration, encoding: .utf8)
        == "{\n  \"lastChangelogVersion\": \"9.9.9\",\n  \"provider\": \"anthropic\"\n}\n"
    )
    #expect(try String(contentsOf: fixture.tuicrConfiguration, encoding: .utf8) == tuicr)
    #expect(try String(contentsOf: fixture.codexConfiguration, encoding: .utf8) == codex)
    #expect(try fixture.pathIsMissing(fixture.piThemeLink))
    #expect(try fixture.pathIsMissing(fixture.tuicrThemeLink))
    #expect(try fixture.pathIsMissing(fixture.tuicrSyntaxLink))
    #expect(try fixture.pathIsMissing(fixture.codexThemeLink))
  }

  /// Pi's selector document is strict JSON; each malformed or noncanonical shape is refused.
  @Test(
    arguments: [
      ("{\"theme\": \"macarchy-current\",}\n", invalidPiSelector("trailing comma in JSON object")),
      (
        "{\"theme\": \"macarchy-current\", \"provider\": {\"name\": \"test\",}}\n",
        invalidPiSelector("trailing comma in JSON object")
      ),
      (
        "{\"theme\": \"macarchy-current\", \"models\": [\"one\",]}\n",
        invalidPiSelector("trailing comma in JSON array")
      ),
      (
        "{\"theme\": \"macarchy-current\", \"provider\": {\"name\": \"one\", \"name\": \"two\"}}\n",
        invalidPiSelector("duplicate JSON key \"name\"")
      ),
      (
        "{\n  \"theme\": \"macarchy-current\",\n  \"theme\": \"macarchy-current\"\n}\n",
        invalidPiSelector("duplicate top-level JSON key \"theme\"")
      ),
      // An equivalent but noncanonical key spelling is a conflicting directive, not a match.
      (
        "{\"th\\u0065me\": \"macarchy-current\"}\n",
        SetupOwnershipError.conflictingDirective("pi.selector", piSelectorTarget)
      ),
    ]
  )
  func piSelectorRejectsMalformedOrNoncanonicalDocuments(
    document: String, expected: SetupOwnershipError
  ) {
    #expect(throws: expected) {
      _ = try SetupOwnershipManager().jsonSelectionIsExternal(
        Data(document.utf8),
        key: PiAdapter.selectionKey,
        value: PiAdapter.themeName,
        id: "pi.selector",
        target: piSelectorTarget
      )
    }
  }
}

/// The selector checks only parse bytes; the target names the file in their errors.
private let piSelectorTarget = URL(filePath: "/test/home/.pi/agent/settings.json")

private func invalidPiSelector(_ reason: String) -> SetupOwnershipError {
  .invalidConfiguration("pi.selector", piSelectorTarget, reason)
}

extension Fixture {
  var piConfiguration: URL {
    home.appending(path: ".pi/agent/settings.json")
  }

  var piThemeLink: URL {
    home.appending(path: ".pi/agent/themes/\(PiAdapter.themeName).json")
  }

  var piSelectorReplacement: URL {
    piConfiguration.deletingLastPathComponent()
      .appending(path: ".macarchy-pi-settings-transaction")
  }

  var tuicrConfiguration: URL {
    home.appending(path: ".config/tuicr/config.toml")
  }

  var tuicrThemeLink: URL {
    home.appending(path: ".config/tuicr/themes/\(TuicrAdapter.themeName).toml")
  }

  var tuicrSyntaxLink: URL {
    home.appending(path: ".config/tuicr/themes/\(TuicrAdapter.themeName).tmTheme")
  }

  var codexConfiguration: URL {
    home.appending(path: ".codex/config.toml")
  }

  var codexThemeLink: URL {
    home.appending(path: ".codex/themes/\(CodexAdapter.themeName).tmTheme")
  }

  func pathIsMissing(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return false }
    guard errno == ENOENT else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return true
  }
}
