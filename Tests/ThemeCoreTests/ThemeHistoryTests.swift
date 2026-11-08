import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct ThemeHistoryTests {
  @Test func recordingAddsThePreviousSelectionBeforeTheFirstChange() {
    let mocha = entry("catppuccin-mocha", "mocha-1")
    let wave = entry("kanagawa-wave", "wave-1")

    #expect(ThemeHistory.recording([], previous: nil, committed: mocha) == [mocha])
    #expect(ThemeHistory.recording([], previous: mocha, committed: wave) == [mocha, wave])
    #expect(ThemeHistory.recording([mocha], previous: mocha, committed: wave) == [mocha, wave])
  }

  @Test func recordingAddsAnUnrecordedPreviousSelection() {
    let mocha = entry("catppuccin-mocha", "mocha-1")
    let wave = entry("kanagawa-wave", "wave-1")
    let night = entry("tokyo-night", "night-1")
    let waveTwo = entry("kanagawa-wave", "wave-2")

    #expect(
      ThemeHistory.recording([mocha, wave], previous: night, committed: waveTwo)
        == [mocha, wave, night, waveTwo])
  }

  @Test func recordingRefreshesARepeatedSelectionInPlace() {
    let mocha = entry("catppuccin-mocha", "mocha-1")
    let wave = entry("kanagawa-wave", "wave-1")
    let rerendered = entry("kanagawa-wave", "wave-1")

    let entries = ThemeHistory.recording([mocha, wave], previous: wave, committed: rerendered)

    #expect(entries == [mocha, rerendered])
    #expect(entries.last?.generationID == rerendered.generationID)
    #expect(ThemeHistory.recording([], previous: wave, committed: rerendered) == [rerendered])
  }

  @Test func recordingKeepsOnlyTheNewestEntries() {
    var entries: [ThemeHistoryEntry] = []
    var commits: [ThemeHistoryEntry] = []
    for index in 0..<(ThemeHistory.maximumEntries + 10) {
      let commit = entry(index.isMultiple(of: 2) ? "tokyo-night" : "kanagawa-wave", "b-\(index)")
      commits.append(commit)
      entries = ThemeHistory.recording(entries, previous: entries.last, committed: commit)
    }

    #expect(entries == Array(commits.suffix(ThemeHistory.maximumEntries)))
  }

  @Test func undoStepReturnsTheNewestDifferentSelection() throws {
    let mocha = entry("catppuccin-mocha", "mocha-1")
    let wave = entry("kanagawa-wave", "wave-1")
    let waveTwo = entry("kanagawa-wave", "wave-2")

    let backgroundOnly = try #require(
      ThemeHistory.undoStep(
        [mocha, wave, waveTwo], activeThemeID: "kanagawa-wave", activeBackgroundID: "wave-2"))
    #expect(backgroundOnly == ThemeUndoStep(target: wave, remaining: [mocha, wave]))

    let theme = try #require(
      ThemeHistory.undoStep(
        [mocha, wave], activeThemeID: "kanagawa-wave", activeBackgroundID: "wave-1"))
    #expect(theme == ThemeUndoStep(target: mocha, remaining: [mocha]))

    let unrecordedActive = try #require(
      ThemeHistory.undoStep(
        [mocha, wave], activeThemeID: "tokyo-night", activeBackgroundID: nil))
    #expect(unrecordedActive == ThemeUndoStep(target: wave, remaining: [mocha, wave]))
  }

  @Test func undoStepIsNilWithoutAnEarlierSelection() {
    let mocha = entry("catppuccin-mocha", "mocha-1")

    #expect(
      ThemeHistory.undoStep([], activeThemeID: "catppuccin-mocha", activeBackgroundID: "mocha-1")
        == nil)
    #expect(
      ThemeHistory.undoStep(
        [mocha, mocha], activeThemeID: "catppuccin-mocha", activeBackgroundID: "mocha-1") == nil)
  }

  @Test func storeRoundTripsEntriesAndTreatsAMissingFileAsEmpty() throws {
    try withTemporaryRoot(named: "macarchy-theme-history") { root in
      let store = ThemeHistoryStore(root: root)
      #expect(try store.load() == [])

      let entries = [entry("catppuccin-mocha", "mocha-1"), entry("kanagawa-wave", nil)]
      try store.persist(entries)

      #expect(try store.load() == entries)
      let attributes = try FileManager.default.attributesOfItem(
        atPath: root.appending(path: "state/theme-history.json").path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
  }

  @Test(arguments: [
    #"{"schema_version":1,"entries":[],"extra":true}"#,
    #"{"schema_version":2,"entries":[]}"#,
    #"{"schema_version":1,"entries":[{"theme_id":"Bad Theme","generation_id":"g-x","recorded_at":""}]}"#,
    "not json",
  ])
  func storeRejectsInvalidDocuments(contents: String) throws {
    try withTemporaryRoot(named: "macarchy-theme-history") { root in
      let url = root.appending(path: "state/theme-history.json")
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)

      #expect(throws: ThemeHistoryStoreError.self) { try ThemeHistoryStore(root: root).load() }
    }
  }

  @Test func storeRefusesToPersistInvalidEntries() throws {
    try withTemporaryRoot(named: "macarchy-theme-history") { root in
      let store = ThemeHistoryStore(root: root)
      let invalid = ThemeHistoryEntry(
        themeID: "catppuccin-mocha", backgroundID: nil, generationID: "not-a-generation",
        recordedAt: "")

      #expect(throws: ThemeHistoryStoreError.self) { try store.persist([invalid]) }
      #expect(throws: ThemeHistoryStoreError.self) {
        try store.persist(
          Array(repeating: entry("catppuccin-mocha", nil), count: ThemeHistory.maximumEntries + 1))
      }
      let stored = try store.load()
      #expect(stored == [])
    }
  }
}

private func entry(_ themeID: String, _ backgroundID: String?) -> ThemeHistoryEntry {
  ThemeHistoryEntry(
    themeID: themeID,
    backgroundID: backgroundID,
    generationID: "g-\(UUID().uuidString.lowercased())",
    recordedAt: "2026-11-08T00:00:00Z"
  )
}
