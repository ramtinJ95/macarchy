import Darwin
import Foundation

/// One committed theme selection. The activation history is subordinate evidence for
/// `theme undo`; the `current` pointer and its manifest stay authoritative (section 4.4).
package struct ThemeHistoryEntry: Codable, Equatable, Sendable {
  package let themeID: String
  package let backgroundID: String?
  package let generationID: String
  package let recordedAt: String

  package init(themeID: String, backgroundID: String?, generationID: String, recordedAt: String) {
    self.themeID = themeID
    self.backgroundID = backgroundID
    self.generationID = generationID
    self.recordedAt = recordedAt
  }

  package init(manifest: GenerationManifest, recordedAt: String) {
    self.init(
      themeID: manifest.themeID,
      backgroundID: manifest.background?.id,
      generationID: manifest.generationID,
      recordedAt: recordedAt
    )
  }

  /// Whether `other` selects the same theme and background. Generations may differ, since a
  /// changed package or renderer gives the same selection a new generation.
  package func selectsSame(as other: Self) -> Bool {
    selects(themeID: other.themeID, backgroundID: other.backgroundID)
  }

  package func selects(themeID: String, backgroundID: String?) -> Bool {
    self.themeID == themeID && self.backgroundID == backgroundID
  }

  enum CodingKeys: String, CodingKey {
    case themeID = "theme_id"
    case backgroundID = "background_id"
    case generationID = "generation_id"
    case recordedAt = "recorded_at"
  }
}

/// What `theme undo` activates, and the history once that activation commits.
package struct ThemeUndoStep: Equatable, Sendable {
  package let target: ThemeHistoryEntry
  /// Every entry up to and including `target`; the undone entries are dropped.
  package let remaining: [ThemeHistoryEntry]
}

/// The history rules, kept free of I/O so they can be tested directly.
package enum ThemeHistory {
  package static let maximumEntries = 50

  /// `entries` after `committed` became active. `previous` is the selection that was active
  /// before; it is added first when the history does not already end with it, so the first
  /// recorded change, and a change made while the history could not be written, can still be
  /// undone. A commit of the selection the history already ends with refreshes that entry.
  package static func recording(
    _ entries: [ThemeHistoryEntry],
    previous: ThemeHistoryEntry?,
    committed: ThemeHistoryEntry
  ) -> [ThemeHistoryEntry] {
    var result = entries
    if let previous, !(result.last?.selectsSame(as: previous) ?? false) {
      result.append(previous)
    }
    if let last = result.last, last.selectsSame(as: committed) {
      result[result.count - 1] = committed
    } else {
      result.append(committed)
    }
    return Array(result.suffix(maximumEntries))
  }

  /// The newest recorded selection that differs from the active one, or nil when there is
  /// none. Entries that select the active theme and background are dropped with the undo.
  package static func undoStep(
    _ entries: [ThemeHistoryEntry],
    activeThemeID: String,
    activeBackgroundID: String?
  ) -> ThemeUndoStep? {
    var remaining = entries
    while let last = remaining.last,
      last.selects(themeID: activeThemeID, backgroundID: activeBackgroundID)
    {
      remaining.removeLast()
    }
    guard let target = remaining.last else { return nil }
    return ThemeUndoStep(target: target, remaining: remaining)
  }
}

package enum ThemeHistoryStoreError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL)
  case cannotReplace(Int32)
  case invalid(String)

  package var description: String {
    switch self {
    case .cannotRead(let url):
      "Cannot read theme history at \(url.path)"
    case .cannotReplace(let code):
      "Cannot atomically replace theme history (errno \(code)): " + String(cString: strerror(code))
    case .invalid(let reason):
      "Invalid theme history: \(reason)"
    }
  }
}

private struct ThemeHistoryDocument: Codable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let entries: [ThemeHistoryEntry]

  init(entries: [ThemeHistoryEntry]) {
    schemaVersion = Self.schemaVersion
    self.entries = entries
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case entries
  }
}

/// `state/theme-history.json`, oldest entry first.
package struct ThemeHistoryStore: Sendable {
  private let historyURL: URL

  package init(root: URL) {
    historyURL = root.standardizedFileURL.appending(path: "state/theme-history.json")
  }

  package func load() throws -> [ThemeHistoryEntry] {
    let file: BoundedRegularFile?
    do {
      file = try BoundedRegularFile.readIfPresent(at: historyURL)
    } catch {
      throw ThemeHistoryStoreError.cannotRead(historyURL)
    }
    guard let data = file?.data else { return [] }

    do {
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard
        let object,
        Set(object.keys) == Set(ThemeHistoryDocument.CodingKeys.allCases.map(\.stringValue))
      else {
        throw ThemeHistoryStoreError.invalid("contains unknown or missing fields")
      }
      let document = try JSONDecoder().decode(ThemeHistoryDocument.self, from: data)
      guard document.schemaVersion == ThemeHistoryDocument.schemaVersion else {
        throw ThemeHistoryStoreError.invalid(
          "unsupported schema version \(document.schemaVersion)"
        )
      }
      try validate(document.entries)
      return document.entries
    } catch let error as ThemeHistoryStoreError {
      throw error
    } catch {
      throw ThemeHistoryStoreError.invalid(String(describing: error))
    }
  }

  package func persist(_ entries: [ThemeHistoryEntry]) throws {
    try validate(entries)
    try StateFile.replaceByRename(
      at: historyURL,
      temporaryName: ".theme-history-\(UUID().uuidString.lowercased()).json",
      temporaryWriteOptions: [],
      encode: { try prettyJSONDocument(ThemeHistoryDocument(entries: entries)) },
      tooLargeError: ThemeHistoryStoreError.invalid("exceeds the 1 MiB file limit"),
      renameError: ThemeHistoryStoreError.cannotReplace
    )
  }

  private func validate(_ entries: [ThemeHistoryEntry]) throws {
    guard entries.count <= ThemeHistory.maximumEntries else {
      throw ThemeHistoryStoreError.invalid(
        "holds more than \(ThemeHistory.maximumEntries) entries")
    }
    for entry in entries {
      guard ThemeSchema.isThemeID(entry.themeID),
        entry.backgroundID.map(ThemeSchema.isThemeID) ?? true,
        isGenerationID(entry.generationID)
      else {
        throw ThemeHistoryStoreError.invalid(
          "entries must name a valid theme, background and generation")
      }
    }
  }
}
