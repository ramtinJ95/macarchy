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
    try fixture.writeLegacyOwnership([
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
    ])

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )

    var teardownStatuses = unownedTeardownStatuses
    for id in ownedIntegrationIDs {
      teardownStatuses[id] = .removed
    }
    expectStatuses(teardown, teardownStatuses)
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
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func piSelectorRejectsTrailingCommasAtEveryNestedContainerBoundary() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let documents = [
      ("{\"theme\": \"macarchy-current\",}\n", "trailing comma in JSON object"),
      (
        "{\"theme\": \"macarchy-current\", \"provider\": {\"name\": \"test\",}}\n",
        "trailing comma in JSON object"
      ),
      (
        "{\"theme\": \"macarchy-current\", \"models\": [\"one\",]}\n",
        "trailing comma in JSON array"
      ),
    ]

    for (document, expectedReason) in documents {
      do {
        _ = try SetupOwnershipManager().jsonSelectionIsExternal(
          Data(document.utf8),
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: "pi.selector",
          target: fixture.piConfiguration
        )
        Issue.record("Expected a trailing JSON comma to fail")
      } catch SetupOwnershipError.invalidConfiguration(_, _, let reason) {
        #expect(reason == expectedReason)
      }
    }
  }

  @Test
  func piSelectorRejectsDuplicateKeysInsideNestedObjects() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let document =
      "{\"theme\": \"macarchy-current\", \"provider\": {\"name\": \"one\", \"name\": \"two\"}}\n"

    do {
      _ = try SetupOwnershipManager().jsonSelectionIsExternal(
        Data(document.utf8),
        key: PiAdapter.selectionKey,
        value: PiAdapter.themeName,
        id: "pi.selector",
        target: fixture.piConfiguration
      )
      Issue.record("Expected a nested duplicate JSON key to fail")
    } catch SetupOwnershipError.invalidConfiguration(_, _, let reason) {
      #expect(reason == "duplicate JSON key \"name\"")
    }
  }

  @Test
  func piSelectorRejectsDuplicateTopLevelKeys() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pi =
      "{\n  \"theme\": \"macarchy-current\",\n  \"theme\": \"macarchy-current\"\n}\n"

    do {
      _ = try SetupOwnershipManager().jsonSelectionIsExternal(
        Data(pi.utf8),
        key: PiAdapter.selectionKey,
        value: PiAdapter.themeName,
        id: "pi.selector",
        target: fixture.piConfiguration
      )
      Issue.record("Expected duplicate Pi keys to fail")
    } catch SetupOwnershipError.invalidConfiguration(let id, let target, let reason) {
      #expect(id == "pi.selector")
      #expect(target == fixture.piConfiguration)
      #expect(reason == "duplicate top-level JSON key \"theme\"")
    }
  }

  @Test
  func piSelectorRejectsEquivalentButNoncanonicalKeySpelling() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pi = "{\"th\\u0065me\": \"macarchy-current\"}\n"

    #expect(
      throws: SetupOwnershipError.conflictingDirective(
        "pi.selector",
        fixture.piConfiguration
      )
    ) {
      _ = try SetupOwnershipManager().jsonSelectionIsExternal(
        Data(pi.utf8),
        key: PiAdapter.selectionKey,
        value: PiAdapter.themeName,
        id: "pi.selector",
        target: fixture.piConfiguration
      )
    }
  }
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
