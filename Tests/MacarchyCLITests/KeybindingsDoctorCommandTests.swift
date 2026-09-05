import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingsDoctorCommandTests {
  @Test
  func missingAndStaleMetadataMatchHumanAndJSONGoldens() throws {
    let catalog = try SkhdKeybindingCatalogLoader().decode(
      """
      schema_version = 1
      [[bindings]]
      identity = "alt-j"
      label = "Focus below"
      category = "Window focus"
      order = 1

      [[bindings]]
      identity = "cmd-x"
      label = "Stale"
      category = "Test"
      order = 2
      """,
      source: URL(filePath: "/fixtures/keybindings.toml")
    )
    let runner = KeybindingsDoctorCommandRunner(
      read: { _ in "alt - j : south\nalt - k : north\n" },
      loadCatalog: { _ in catalog }
    )
    let configuration = URL(filePath: "/fixtures/skhdrc")
    let catalogURL = URL(filePath: "/fixtures/keybindings.toml")

    let human = try runner.execute(
      configurationURL: configuration,
      catalogURL: catalogURL,
      json: false
    )
    let json = try runner.execute(
      configurationURL: configuration,
      catalogURL: catalogURL,
      json: true
    )
    let expectedHuman = try fixtureContents("CLI/keybindings-doctor.txt")
      .trimmingCharacters(in: .newlines)
    let expectedJSON = try fixtureContents("CLI/keybindings-doctor.json")
      .trimmingCharacters(in: .newlines)

    #expect(human.succeeded)
    #expect(json.succeeded)
    #expect(human.output == expectedHuman)
    #expect(json.output == expectedJSON)
  }

  @Test
  func parserProblemsAreWarningsWithExactLineEvidence() throws {
    let runner = KeybindingsDoctorCommandRunner(
      read: { _ in "alt - j : first\nalt - j : second\n:: mode\n" },
      loadCatalog: { _ in .missing }
    )

    let execution = try runner.execute(
      configurationURL: URL(filePath: "/fixtures/skhdrc"),
      catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
      json: true
    )
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(execution.output.utf8)) as? [String: Any]
    )
    let findings = try #require(report["findings"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(findings.contains { $0["id"] as? String == "skhd.duplicate.2" })
    #expect(findings.contains { $0["id"] as? String == "skhd.syntax.3" })
    #expect(
      findings.first { $0["id"] as? String == "skhd.syntax.3" }?["source"] as? String
        == "/fixtures/skhdrc"
    )
    #expect(
      findings.first { $0["id"] as? String == "skhd.duplicate.2" }?["related_line"] as? Int
        == 1
    )
  }

  @Test
  func unreadableConfigurationAndInvalidCatalogFail() throws {
    struct ReadFailure: Error, CustomStringConvertible {
      let description = "cannot read fixture"
    }
    let readFailure = KeybindingsDoctorCommandRunner(
      read: { _ in throw ReadFailure() },
      loadCatalog: { _ in .missing }
    )
    let catalogFailure = KeybindingsDoctorCommandRunner(
      read: { _ in "alt - j : valid\n" },
      loadCatalog: { source in
        throw SkhdCatalogError.invalid(source, "contains an unknown key")
      }
    )
    let configuration = URL(filePath: "/fixtures/skhdrc")
    let catalog = URL(filePath: "/fixtures/keybindings.toml")

    let unreadable = try readFailure.execute(
      configurationURL: configuration,
      catalogURL: catalog,
      json: false
    )
    let invalidCatalog = try catalogFailure.execute(
      configurationURL: configuration,
      catalogURL: catalog,
      json: false
    )

    #expect(!unreadable.succeeded)
    #expect(unreadable.output.contains("skhd.read [failure]: /fixtures/skhdrc:"))
    #expect(!invalidCatalog.succeeded)
    #expect(
      invalidCatalog.output.contains(
        "catalog.load [failure]: /fixtures/keybindings.toml:"
      )
    )
  }
}
