import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct HerdrPaletteMigrationTests {
  private func legacyData(custom: [String: String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schema_version": 1, "name": "catppuccin", "custom": custom,
    ])
  }

  @Test
  func generatedPaletteVersionsRejectPartialAndMismatchedSurfaces() throws {
    let custom = Dictionary(
      uniqueKeysWithValues: HerdrAdapter.legacyCustomKeySet.map { ($0, "#494335") })
    let data = try legacyData(custom: custom)
    let legacy = try HerdrAdapter.decodeGeneratedTheme(data, rendererVersion: 3)
    #expect(legacy.custom.count == 16)
    #expect(throws: (any Error).self) {
      try HerdrAdapter.decodeGeneratedTheme(data, rendererVersion: 4)
    }
    var partial = custom
    partial["sidebar_bg"] = "#312b20"
    #expect(throws: (any Error).self) {
      try HerdrAdapter.decodeGeneratedTheme(legacyData(custom: partial), rendererVersion: 3)
    }
    #expect(throws: (any Error).self) {
      try GeneratedHerdrTheme(name: "catppuccin", custom: custom).validated()
    }
    let current = GeneratedHerdrTheme(
      name: "catppuccin",
      custom: custom.merging([
        "sidebar_bg": "#312b20", "active_row_bg": "#494335", "selection_bg": "#494335",
      ]) { _, new in new })
    let encoded = try JSONEncoder().encode(current)
    #expect(try HerdrAdapter.decodeGeneratedTheme(encoded, rendererVersion: 4) == current)
    #expect(throws: (any Error).self) {
      try HerdrAdapter.decodeGeneratedTheme(encoded, rendererVersion: 3)
    }
  }

  @Test
  func authenticatedLegacyPaletteExpandsRollsBackAndRestoresWithoutClaimingDrift() throws {
    let source = URL(filePath: "/fixture/config.toml")
    let original = "[theme]\n  name = \"personal\" # keep\n[terminal]\nshell_mode = \"auto\"\n"
    let custom = Dictionary(
      uniqueKeysWithValues: HerdrAdapter.legacyCustomKeySet.map { ($0, "#494335") })
    let legacy = try HerdrAdapter.decodeGeneratedTheme(
      legacyData(custom: custom), rendererVersion: 3)
    let ownership = try EnvironmentHerdrDocument.ownership(
      original: original, source: source, resolvedSource: source,
      originalFileExisted: true, directoryLink: nil, migratedLegacy: false, managedTheme: legacy
    )
    let saved = try JSONEncoder().encode(ownership)
    #expect(try JSONDecoder().decode(EnvironmentHerdrOwnership.self, from: saved) == ownership)
    let old = try EnvironmentHerdrDocument.applyingManaged(
      original, desired: legacy, source: source)
    let current = GeneratedHerdrTheme(
      name: "catppuccin",
      custom: custom.merging([
        "sidebar_bg": "#312b20", "active_row_bg": "#494335", "selection_bg": "#494335",
      ]) { _, new in new })
    let updated = try EnvironmentHerdrDocument.applyingManaged(
      old, desired: current, replacing: legacy, source: source
    )
    #expect(try EnvironmentHerdrDocument.matchesManaged(updated, desired: current, source: source))
    #expect(updated.contains("shell_mode = \"auto\""))
    let rollback = try EnvironmentHerdrDocument.applyingManaged(
      updated, desired: legacy, replacing: current, source: source
    )
    #expect(rollback == old)
    #expect(
      try EnvironmentHerdrDocument.restoringOriginal(
        in: updated, ownership: ownership.replacingManagedTheme(current), source: source
      ) == original)
    let drifted = old + "\n[theme.custom.unowned]\ncolor = \"#ffffff\"\n"
    // A newly supported key is not implicitly owned by a legacy receipt.
    let collision = old.replacingOccurrences(
      of: "[theme.custom]\n", with: "[theme.custom]\nsidebar_bg = \"#ffffff\"\n")
    #expect(throws: (any Error).self) {
      try EnvironmentHerdrDocument.applyingManaged(
        collision, desired: current, replacing: legacy, source: source)
    }
    #expect(throws: (any Error).self) {
      try EnvironmentHerdrDocument.applyingManaged(
        drifted, desired: current, replacing: legacy, source: source)
    }
  }
}
