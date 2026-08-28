import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingsShowTests {
  @Test
  func popupRowsPreserveCorrelationOrderAndSearchEveryInformationalField() throws {
    let catalog = try SkhdKeybindingCatalogLoader().decode(
      """
      schema_version = 1
      [[bindings]]
      identity = "alt-k"
      label = "Focus above"
      category = "Window focus"
      order = 1
      aliases = ["north", "upward"]

      [[bindings]]
      identity = "alt-j"
      label = "Focus below"
      category = "Window focus"
      order = 2
      aliases = ["south"]
      """,
      source: URL(filePath: "/fixtures/keybindings.toml")
    )
    let loader = testLoader(
      configuration:
        "alt - j : yabai -m window --focus south\nalt - k : yabai -m window --focus north\n",
      catalog: catalog
    )

    let content = try loader.load(
      configurationURL: URL(filePath: "/fixtures/skhdrc"),
      catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
      stateRoot: URL(filePath: "/state")
    )

    #expect(content.rows.map(\.identity) == ["alt-k", "alt-j"])
    #expect(content.filteredRows(query: "NORTH").map(\.identity) == ["alt-k"])
    #expect(content.filteredRows(query: "focus below").map(\.identity) == ["alt-j"])
    #expect(content.filteredRows(query: "window upward").map(\.identity) == ["alt-k"])
    #expect(content.filteredRows(query: "alt k").map(\.identity) == ["alt-k"])
    #expect(content.filteredRows(query: "--focus south").map(\.identity) == ["alt-j"])
  }

  @Test
  func uncataloguedRowsRemainVisibleWithCommandFallbacks() throws {
    let loader = testLoader(
      configuration: "cmd - x : printf 'opaque command'\n",
      catalog: .missing
    )

    let content = try loader.load(
      configurationURL: URL(filePath: "/fixtures/skhdrc"),
      catalogURL: URL(filePath: "/missing/keybindings.toml"),
      stateRoot: URL(filePath: "/state")
    )
    let row = try #require(content.rows.first)

    #expect(row.label == "printf 'opaque command'")
    #expect(row.category == "Uncatalogued")
    #expect(row.command == "printf 'opaque command'")
    #expect(content.filteredRows(query: "opaque").map(\.identity) == ["cmd-x"])
  }

  @Test
  func popupRejectsParserDiagnosticsWithSourceLines() throws {
    let loader = KeybindingsShowCommandLoader(
      read: { _ in "cmd + hyper - x : unsupported\nalt - j : valid\n" },
      loadCatalog: { _ in .missing },
      loadTheme: { _ in try testTheme() }
    )

    do {
      _ = try loader.load(
        configurationURL: URL(filePath: "/fixtures/broken.skhdrc"),
        catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
        stateRoot: URL(filePath: "/state")
      )
      Issue.record("Expected unsupported syntax to prevent popup presentation")
    } catch {
      #expect(
        String(describing: error)
          == "/fixtures/broken.skhdrc:1: unsupported key chord 'cmd + hyper - x'"
      )
    }
  }

  @Test
  func popupReportsConfigurationCatalogAndThemeFailuresAtTheirSources() throws {
    struct ProbeError: Error, CustomStringConvertible {
      let description: String
    }

    let readFailure = KeybindingsShowCommandLoader(
      read: { _ in throw ProbeError(description: "read probe") },
      loadCatalog: { _ in .missing },
      loadTheme: { _ in try testTheme() }
    )
    do {
      _ = try readFailure.load(
        configurationURL: URL(filePath: "/missing/skhdrc"),
        catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
        stateRoot: URL(filePath: "/state")
      )
      Issue.record("Expected unreadable configuration to prevent popup presentation")
    } catch {
      #expect(
        String(describing: error)
          == "Cannot read skhd configuration at /missing/skhdrc: read probe"
      )
    }

    let catalogFailure = KeybindingsShowCommandLoader(
      read: { _ in "alt - j : valid\n" },
      loadCatalog: { source in throw SkhdCatalogError.invalid(source, "bad metadata") },
      loadTheme: { _ in try testTheme() }
    )
    do {
      _ = try catalogFailure.load(
        configurationURL: URL(filePath: "/fixtures/skhdrc"),
        catalogURL: URL(filePath: "/broken/keybindings.toml"),
        stateRoot: URL(filePath: "/state")
      )
      Issue.record("Expected invalid catalog to prevent popup presentation")
    } catch {
      #expect(
        String(describing: error)
          == "Cannot load keybinding catalog at /broken/keybindings.toml: invalid keybinding catalog: bad metadata"
      )
    }

    let themeFailure = KeybindingsShowCommandLoader(
      read: { _ in "alt - j : valid\n" },
      loadCatalog: { _ in .missing },
      loadTheme: { _ in throw ProbeError(description: "theme probe") }
    )
    do {
      _ = try themeFailure.load(
        configurationURL: URL(filePath: "/fixtures/skhdrc"),
        catalogURL: URL(filePath: "/fixtures/keybindings.toml"),
        stateRoot: URL(filePath: "/state")
      )
      Issue.record("Expected invalid active theme to prevent popup presentation")
    } catch {
      #expect(String(describing: error) == "Cannot load the active Macarchy theme: theme probe")
    }
  }

  private func testLoader(
    configuration: String,
    catalog: SkhdKeybindingCatalog
  ) -> KeybindingsShowCommandLoader {
    KeybindingsShowCommandLoader(
      read: { _ in configuration },
      loadCatalog: { _ in catalog },
      loadTheme: { _ in try testTheme() }
    )
  }
}

private func testTheme() throws -> NormalizedTheme {
  let fixture = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Fixtures/Golden/catppuccin-mocha/theme.json")
  return try JSONDecoder().decode(
    NormalizedTheme.self,
    from: Data(contentsOf: fixture)
  )
}
