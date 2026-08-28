import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingsListCommandTests {
  @Test
  func representativeConfigurationMatchesHumanAndJSONGoldens() throws {
    let fixture = try fixtureContents("Skhd/representative.skhdrc")
    let runner = KeybindingsListCommandRunner(
      read: { _ in fixture },
      loadCatalog: { _ in .missing }
    )
    let source = URL(filePath: "/fixtures/representative.skhdrc")

    let catalog = URL(filePath: "/fixtures/keybindings.toml")
    let human = try runner.execute(configurationURL: source, catalogURL: catalog, json: false)
    let json = try runner.execute(configurationURL: source, catalogURL: catalog, json: true)
    let expectedHuman = try fixtureContents("CLI/keybindings-list.txt")
    let expectedJSON = try fixtureContents("CLI/keybindings-list.json")

    #expect(human.succeeded)
    #expect(json.succeeded)
    #expect(human.output == expectedHuman)
    #expect(json.output == expectedJSON)
  }

  @Test
  func catalogMetadataOrdersAndAnnotatesRowsWithoutReplacingCommands() throws {
    let catalog = try SkhdKeybindingCatalogLoader().decode(
      """
      schema_version = 1
      [[bindings]]
      identity = "alt-k"
      label = "Focus above"
      category = "Window focus"
      order = 1
      aliases = ["north"]
      """,
      source: URL(filePath: "/fixtures/keybindings.toml")
    )
    let runner = KeybindingsListCommandRunner(
      read: { _ in "alt - j : focus south\nalt - k : focus north\n" },
      loadCatalog: { _ in catalog }
    )

    let execution = try runner.execute(
      configurationURL: URL(filePath: "/fixtures/skhdrc"),
      catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
      json: true
    )
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(execution.output.utf8)) as? [String: Any]
    )
    let bindings = try #require(report["bindings"] as? [[String: Any]])
    let firstMetadata = try #require(bindings[0]["metadata"] as? [String: Any])

    #expect(execution.succeeded)
    #expect(bindings.map { $0["identity"] as? String } == ["alt-k", "alt-j"])
    #expect(bindings[0]["command"] as? String == "focus north")
    #expect(firstMetadata["label"] as? String == "Focus above")
    #expect(firstMetadata["aliases"] as? [String] == ["north"])
    #expect(bindings[1]["metadata"] == nil)
  }

  @Test
  func invalidCatalogFailsListButPreservesParsedRows() throws {
    let runner = KeybindingsListCommandRunner(
      read: { _ in "alt - j : valid\n" },
      loadCatalog: { source in
        throw SkhdCatalogError.invalid(source, "contains an executable command")
      }
    )

    let execution = try runner.execute(
      configurationURL: URL(filePath: "/fixtures/skhdrc"),
      catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
      json: false
    )

    #expect(!execution.succeeded)
    #expect(execution.output.contains("alt - j\tvalid"))
    #expect(
      execution.output.contains(
        "/fixtures/keybindings.toml: error [catalog_invalid]"
      )
    )
    #expect(!execution.output.contains("/fixtures/skhdrc: error [catalog_invalid]"))
  }

  @Test
  func diagnosticsPreserveValidRowsAndFailTheCommand() throws {
    let runner = KeybindingsListCommandRunner(
      read: { _ in "cmd + hyper - x : unsupported\nalt - j : valid\n" },
      loadCatalog: { _ in .missing }
    )

    let execution = try runner.execute(
      configurationURL: URL(filePath: "/fixtures/broken.skhdrc"),
      catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
      json: false
    )

    #expect(!execution.succeeded)
    #expect(execution.output.contains("alt - j\tvalid"))
    #expect(
      execution.output.contains(
        "/fixtures/broken.skhdrc:1: error [unsupported_syntax]:"
      )
    )
  }

  @Test
  func readFailuresRemainMachineReadable() throws {
    struct ProbeError: Error, CustomStringConvertible {
      let description = "probe read failed"
    }
    let runner = KeybindingsListCommandRunner(
      read: { _ in throw ProbeError() },
      loadCatalog: { _ in .missing }
    )

    let execution = try runner.execute(
      configurationURL: URL(filePath: "/missing/skhdrc"),
      catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
      json: true
    )
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(execution.output.utf8)) as? [String: Any]
    )
    let diagnostics = try #require(report["diagnostics"] as? [[String: Any]])
    let bindings = try #require(report["bindings"] as? [Any])

    #expect(!execution.succeeded)
    #expect(bindings.isEmpty)
    #expect(diagnostics.first?["code"] as? String == "configuration_read_failed")
    #expect(diagnostics.first?["message"] as? String == "probe read failed")
  }

  private func fixtureContents(_ path: String) throws -> String {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures", directoryHint: .isDirectory)
    return try String(contentsOf: root.appending(path: path), encoding: .utf8)
      .trimmingCharacters(in: .newlines)
  }
}
