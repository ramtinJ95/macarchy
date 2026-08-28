import Foundation
import Testing

@testable import ThemeCore

struct SkhdKeybindingCatalogTests {
  private let loader = SkhdKeybindingCatalogLoader()
  private let source = URL(filePath: "/fixtures/keybindings.toml")

  @Test
  func decodesStrictMetadataOnlyCatalog() throws {
    let catalog = try loader.decode(
      try fixtureContents("representative-catalog.toml"),
      source: source
    )

    #expect(catalog.isPresent)
    #expect(catalog.entries.count == 2)
    #expect(catalog.entries[0].identity == "alt+shift-s")
    #expect(catalog.entries[0].aliases == ["monitor left", "display west"])
    #expect(catalog.entries[1].aliases.isEmpty)
  }

  @Test
  func rejectsUnknownBehaviorFieldsAndTablesAtTheirSource() {
    let behaviorField = """
      schema_version = 1
      [[bindings]]
      identity = "alt-j"
      label = "Focus down"
      category = "Focus"
      order = 1
      command = "open Calculator"
      """
    let unknownTable = """
      schema_version = 1
      [metadata]
      label = "Not a binding"
      """
    let crlfBehaviorField = behaviorField.replacingOccurrences(of: "\n", with: "\r\n")
    let quotedTable = """
      schema_version = 1
      [["bindings"]]
      """

    #expect(
      errorDescription(behaviorField)
        .contains("line 7, column 1: unknown key 'bindings.command'")
    )
    #expect(
      errorDescription(unknownTable)
        .contains("line 2, column 1: unknown table 'metadata'")
    )
    #expect(
      errorDescription(crlfBehaviorField)
        .contains("line 7, column 1: unknown key 'bindings.command'")
    )
    let quotedTableError = errorDescription(quotedTable)
    #expect(quotedTableError.contains("line 2, column 1"))
    #expect(quotedTableError.components(separatedBy: source.path).count == 2)
  }

  @Test
  func rejectsNoncanonicalArbitraryAndDuplicateIdentities() {
    let invalidDocuments = [
      """
      schema_version = 1
      [[bindings]]
      identity = "shift+alt-j"
      label = "Focus down"
      category = "Focus"
      order = 1
      """,
      """
      schema_version = 1
      [[bindings]]
      identity = "cmd-banana"
      label = "Invalid key"
      category = "Focus"
      order = 1
      """,
      """
      schema_version = 1
      [[bindings]]
      identity = "alt-j"
      label = "Focus down"
      category = "Focus"
      order = 1
      [[bindings]]
      identity = "alt-j"
      label = "Duplicate"
      category = "Focus"
      order = 2
      """,
    ]

    #expect(errorDescription(invalidDocuments[0]).contains("not a normalized skhd chord"))
    #expect(errorDescription(invalidDocuments[1]).contains("not a normalized skhd chord"))
    #expect(errorDescription(invalidDocuments[2]).contains("appears more than once"))
  }

  @Test
  func validatesMetadataBoundsAndSchema() {
    let invalidDocuments: [(String, String)] = [
      (
        """
        schema_version = 2
        [[bindings]]
        identity = "alt-j"
        label = "Focus down"
        category = "Focus"
        order = 1
        """,
        "unsupported schema_version 2"
      ),
      (
        """
        schema_version = 1
        [[bindings]]
        identity = "alt-j"
        label = " Focus down"
        category = "Focus"
        order = 1
        """,
        "label must be nonempty without outer whitespace"
      ),
      (
        """
        schema_version = 1
        [[bindings]]
        identity = "alt-j"
        label = "Focus down"
        category = "Focus"
        order = -1
        """,
        "order must be between 0 and 1000000"
      ),
      (
        """
        schema_version = 1
        [[bindings]]
        identity = "alt-j"
        label = "Focus down"
        category = "Focus"
        order = 1
        aliases = ["down", "down"]
        """,
        "contains duplicate aliases"
      ),
    ]

    for (document, expected) in invalidDocuments {
      #expect(errorDescription(document).contains(expected))
    }
  }

  @Test
  func correlatesOrderingMissingAndStaleMetadata() throws {
    let parsed = SkhdConfigurationParser().parse(
      """
      alt - j : focus south
      alt - k : focus north
      shift + alt - s : move west
      """
    )
    let catalog = try loader.decode(
      try fixtureContents("representative-catalog.toml")
        + """

        [[bindings]]
        identity = "cmd-x"
        label = "Stale"
        category = "Test"
        order = 1
        """,
      source: source
    )

    let correlation = loader.correlate(bindings: parsed.bindings, catalog: catalog)

    #expect(correlation.bindings.map(\.binding.identity) == ["alt+shift-s", "alt-j", "alt-k"])
    #expect(correlation.missingMetadataIdentities == ["alt-k"])
    #expect(correlation.staleMetadataIdentities == ["cmd-x"])
  }

  @Test
  func absentCatalogIsAnExplicitEmptyState() throws {
    let missing = URL(filePath: "/tmp/macarchy-tests-\(UUID().uuidString)/missing.toml")

    let catalog = try loader.load(at: missing)

    #expect(!catalog.isPresent)
    #expect(catalog.entries.isEmpty)
  }

  private func fixtureContents(_ name: String) throws -> String {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures/Skhd", directoryHint: .isDirectory)
    return try String(contentsOf: root.appending(path: name), encoding: .utf8)
  }

  private func errorDescription(_ document: String) -> String {
    do {
      _ = try loader.decode(document, source: source)
      Issue.record("Expected keybinding catalog decoding to fail")
      return ""
    } catch {
      return String(describing: error)
    }
  }
}
