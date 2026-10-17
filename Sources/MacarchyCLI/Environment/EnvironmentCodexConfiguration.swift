import Darwin
import Foundation
import TOMLDecoder
import ThemeCore

struct EnvironmentCodexOwnership: Codable, Equatable, Sendable {
  let path: String
  let originalFileExisted: Bool
  let originalSelector: EnvironmentCodexSelectorBoundary?
  let introducedTable: Bool
  let insertedSeparatorBeforeTable: Bool
  let insertedSeparatorAfterTable: Bool

  enum CodingKeys: String, CodingKey {
    case path
    case originalFileExisted = "original_file_existed"
    case originalSelector = "original_selector"
    case introducedTable = "introduced_table"
    case insertedSeparatorBeforeTable = "inserted_separator_before_table"
    case insertedSeparatorAfterTable = "inserted_separator_after_table"
  }

  var hasValidShape: Bool {
    path.hasPrefix("/")
      && (originalSelector?.hasValidShape ?? true)
      && (!introducedTable || originalSelector == nil)
      && (!insertedSeparatorBeforeTable || introducedTable)
      && (!insertedSeparatorAfterTable || (!introducedTable && originalSelector == nil))
      && (originalFileExisted
        || (originalSelector == nil && introducedTable && !insertedSeparatorBeforeTable))
  }
}

struct EnvironmentCodexSelectorBoundary: Codable, Equatable, Sendable {
  let contents: String

  var hasValidShape: Bool {
    guard !contents.isEmpty, contents.utf8.count <= 4_096 else { return false }
    let wrapped = "[\(CodexAdapter.selectionTable)]\n" + contents
    guard
      (try? TOMLDecoder().decode(CodexValidationDocument.self, from: wrapped).tui?.theme) != nil
    else { return false }
    let selector = CanonicalTOMLSelector(
      configuration: wrapped,
      table: CodexAdapter.selectionTable,
      key: CodexAdapter.selectionKey
    )
    return selector.assignments.count == 1
      && selector.assignments[0].fullRange.upperBound == wrapped.endIndex
  }
}

struct EnvironmentCodexDocument {
  private static var tableHeader: String { "[\(CodexAdapter.selectionTable)]" }
  private static var managedSelector: String {
    "\(CodexAdapter.selectionKey) = \"\(CodexAdapter.themeName)\""
  }

  static func matchesManaged(_ text: String, source: URL) throws -> Bool {
    let document = try validatedDocument(text, source: source)
    let selector = canonicalSelector(text)
    return document.tui?.theme == CodexAdapter.themeName
      && selector.tableHeaderCount == 1
      && selector.assignments.count == 1
      && text[selector.assignments[0].contentRange] == managedSelector
  }

  static func ownership(for text: String, source: URL) throws -> EnvironmentCodexOwnership {
    let document = try validatedDocument(text, source: source)
    let selector = canonicalSelector(text)
    try validateCanonicalBoundary(document: document, selector: selector, source: source)
    let originalSelector = selector.assignments.first.map {
      EnvironmentCodexSelectorBoundary(
        contents: String(text[$0.fullRange])
      )
    }
    let introducedTable = selector.tableHeaderCount == 0
    let insertedSeparator =
      introducedTable && !text.isEmpty
      && tomlPhysicalLines(text).last?.terminator.isEmpty == true
    let insertedSeparatorAfterTable =
      !introducedTable && originalSelector == nil
      && selector.selectionTableHeader?.terminator.isEmpty == true
    return EnvironmentCodexOwnership(
      path: source.path,
      originalFileExisted: true,
      originalSelector: originalSelector,
      introducedTable: introducedTable,
      insertedSeparatorBeforeTable: insertedSeparator,
      insertedSeparatorAfterTable: insertedSeparatorAfterTable
    )
  }

  static func applyingManaged(to text: String, source: URL) throws -> String {
    let document = try validatedDocument(text, source: source)
    let selector = canonicalSelector(text)
    try validateCanonicalBoundary(document: document, selector: selector, source: source)
    let result: String
    if let assignment = selector.assignments.first {
      var updated = text
      updated.replaceSubrange(assignment.contentRange, with: managedSelector)
      result = updated
    } else if selector.tableHeaderCount == 1, let header = selector.selectionTableHeader {
      let newline = tomlPreferredNewline(in: text)
      result =
        String(text[..<header.fullRange.upperBound])
        + (header.terminator.isEmpty ? newline : "")
        + managedSelector + newline + String(text[header.fullRange.upperBound...])
    } else {
      let newline = tomlPreferredNewline(in: text)
      let separator =
        text.isEmpty || tomlPhysicalLines(text).last?.terminator.isEmpty == false
        ? "" : newline
      result = text + separator + tableHeader + newline + managedSelector + newline
    }
    guard try matchesManaged(result, source: source) else {
      throw EnvironmentLifecycleError.blocked("cannot install the Codex [tui].theme selector")
    }
    return result
  }

  static func restoringOriginal(
    in text: String,
    ownership: EnvironmentCodexOwnership,
    source: URL
  ) throws -> String {
    _ = try validatedDocument(text, source: source)
    let selector = canonicalSelector(text)
    guard selector.tableHeaderCount == 1, selector.assignments.count == 1,
      let managed = selector.assignments.first,
      text[managed.contentRange] == managedSelector
    else { throw EnvironmentLifecycleError.drift(source.path) }

    if let original = ownership.originalSelector {
      var result = text
      let separator =
        managed.fullRange.upperBound < result.endIndex
          && tomlPhysicalLines(original.contents).last?.terminator.isEmpty == true
        ? tomlPreferredNewline(in: result) : ""
      result.replaceSubrange(managed.fullRange, with: original.contents + separator)
      _ = try validatedDocument(result, source: source)
      return result
    }

    if ownership.introducedTable,
      let header = selector.selectionTableHeader,
      tableContainsOnlyManagedSelector(text, header: header, assignment: managed)
    {
      var start = header.fullRange.lowerBound
      if ownership.insertedSeparatorBeforeTable, start > text.startIndex {
        start = text.index(before: start)
      }
      var result = text
      result.removeSubrange(start..<managed.fullRange.upperBound)
      if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = try validatedDocument(result, source: source)
      }
      return result
    }

    var result = text
    let removalStart =
      ownership.insertedSeparatorAfterTable
      ? result.index(before: managed.fullRange.lowerBound) : managed.fullRange.lowerBound
    result.removeSubrange(removalStart..<managed.fullRange.upperBound)
    if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      _ = try validatedDocument(result, source: source)
    }
    return result
  }

  static func matchesOriginal(
    _ text: String,
    ownership: EnvironmentCodexOwnership,
    source: URL
  ) throws -> Bool {
    let document = try validatedDocument(text, source: source)
    let selector = canonicalSelector(text)
    guard let original = ownership.originalSelector else {
      return document.tui?.theme == nil && selector.assignments.isEmpty
    }
    guard selector.tableHeaderCount == 1, selector.assignments.count == 1,
      let assignment = selector.assignments.first
    else {
      return false
    }
    let separator =
      assignment.fullRange.upperBound < text.endIndex
        && tomlPhysicalLines(original.contents).last?.terminator.isEmpty == true
      ? tomlPreferredNewline(in: text) : ""
    return text[assignment.fullRange] == original.contents + separator
  }

  private static func canonicalSelector(_ text: String) -> CanonicalTOMLSelector {
    CanonicalTOMLSelector(
      configuration: text,
      table: CodexAdapter.selectionTable,
      key: CodexAdapter.selectionKey
    )
  }

  private static func validateCanonicalBoundary(
    document: CodexValidationDocument,
    selector: CanonicalTOMLSelector,
    source: URL
  ) throws {
    guard selector.tableHeaderCount <= 1, selector.assignments.count <= 1 else {
      throw EnvironmentLifecycleError.blocked(
        "Codex configuration has duplicate [tui].theme selectors: \(source.path)"
      )
    }
    if document.tui?.theme != nil,
      selector.tableHeaderCount != 1 || selector.assignments.count != 1
    {
      throw EnvironmentLifecycleError.blocked(
        "Codex [tui].theme uses a noncanonical selector boundary: \(source.path)"
      )
    }
  }

  private static func tableContainsOnlyManagedSelector(
    _ text: String,
    header: TOMLPhysicalLine,
    assignment: CanonicalTOMLAssignment
  ) -> Bool {
    for line in tomlPhysicalLines(text) where line.lineIndex > header.lineIndex {
      if line.lineIndex == assignment.lineIndex { continue }
      let value = text[line.contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("[") { break }
      if !value.isEmpty { return false }
    }
    return true
  }

  private static func validatedDocument(_ text: String, source: URL) throws
    -> CodexValidationDocument
  {
    do {
      return try TOMLDecoder().decode(CodexValidationDocument.self, from: text)
    } catch {
      throw EnvironmentLifecycleError.blocked(
        "invalid Codex TOML configuration at \(source.path): \(error)"
      )
    }
  }
}

private struct CodexValidationDocument: Decodable {
  let tui: TUI?

  struct TUI: Decodable {
    let theme: String?
  }
}

typealias EnvironmentCodexFileTransaction = EnvironmentPresetFileTransaction<
  EnvironmentCodexOwnership
>

extension EnvironmentCodexOwnership: EnvironmentPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Codex configuration",
    residueLabel: "Codex transaction residue",
    nonRegularMessage: "Codex configuration is not an ordinary file"
  )
  static let driftLabel = "Codex"
  static let ownershipChangedMessage = "Codex ownership changed unexpectedly"
  static let replacementLabel = "Codex [tui].theme selector"
  static let replacementFailureLabel: String? = "Codex theme selector"

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.codex }

  static func managed(from current: Data?, at url: URL) throws -> Data {
    let updated = try EnvironmentCodexDocument.applyingManaged(
      to: current.map { try filesystem.utf8($0, at: url) } ?? "",
      source: url
    )
    return Data(updated.utf8)
  }

  static func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    try EnvironmentCodexDocument.matchesManaged(try filesystem.utf8(data, at: url), source: url)
  }

  func restored(in current: Data, at url: URL) throws -> Data? {
    let restored = try EnvironmentCodexDocument.restoringOriginal(
      in: try Self.filesystem.utf8(current, at: url), ownership: self, source: url)
    if !originalFileExisted, restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return nil
    }
    return Data(restored.utf8)
  }

  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return !originalFileExisted }
    return try EnvironmentCodexDocument.matchesOriginal(
      try Self.filesystem.utf8(data, at: url), ownership: self, source: url)
  }
}
