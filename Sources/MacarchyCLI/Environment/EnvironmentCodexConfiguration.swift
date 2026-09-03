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
      let newline = preferredNewline(in: text)
      result =
        String(text[..<header.fullRange.upperBound])
        + (header.terminator.isEmpty ? newline : "")
        + managedSelector + newline + String(text[header.fullRange.upperBound...])
    } else {
      let newline = preferredNewline(in: text)
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
        ? preferredNewline(in: result) : ""
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
      ? preferredNewline(in: text) : ""
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

  private static func preferredNewline(in text: String) -> String {
    tomlPhysicalLines(text).first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
  }
}

private struct CodexValidationDocument: Decodable {
  let tui: TUI?

  struct TUI: Decodable {
    let theme: String?
  }
}

struct EnvironmentCodexFileTransaction: Sendable {
  private enum ExpectedState {
    case original(EnvironmentCodexOwnership)
    case managed
  }

  let homeDirectory: URL

  func preflight(_ ownership: EnvironmentCodexOwnership) throws {
    let url = URL(filePath: ownership.path)
    guard try matches(try read(url), .managed, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    replacementName: String
  ) throws {
    guard let ownership = old?.codex ?? new?.codex else { return }
    if let oldCodex = old?.codex, let newCodex = new?.codex, oldCodex != newCodex {
      throw EnvironmentLifecycleError.blocked("Codex ownership changed unexpectedly")
    }
    let url = URL(filePath: ownership.path)
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    let source: ExpectedState = old?.codex == nil ? .original(ownership) : .managed
    let target: ExpectedState = new?.codex == nil ? .original(ownership) : .managed
    var current = try read(url)
    if let residueData = try read(residue) {
      if try matches(current, target, ownership: ownership, at: url),
        try matches(residueData, source, ownership: ownership, at: residue)
      {
        try remove(residue)
        return
      }
      if try matches(current, source, ownership: ownership, at: url),
        try matches(residueData, target, ownership: ownership, at: residue)
      {
        try remove(residue)
      } else {
        throw EnvironmentLifecycleError.drift("Codex replacement residue")
      }
      current = try read(url)
    }
    if try matches(current, target, ownership: ownership, at: url) { return }
    guard try matches(current, source, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }

    switch target {
    case .managed:
      let updated = try EnvironmentCodexDocument.applyingManaged(
        to: current.map { try utf8($0, at: url) } ?? "",
        source: url
      )
      let data = Data(updated.utf8)
      if let current {
        try replace(data, current: current, at: url, replacementName: replacementName)
      } else {
        try create(data, at: url, replacementName: replacementName)
      }
    case .original(let original):
      guard let current else { return }
      let restored = try EnvironmentCodexDocument.restoringOriginal(
        in: try utf8(current, at: url), ownership: original, source: url)
      if !original.originalFileExisted,
        restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        try claimAndRemove(at: url, replacementName: replacementName, expected: current)
      } else {
        try replace(
          Data(restored.utf8), current: current, at: url, replacementName: replacementName)
      }
    }
    guard try matches(try read(url), target, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  private func matches(
    _ data: Data?,
    _ state: ExpectedState,
    ownership: EnvironmentCodexOwnership,
    at url: URL
  ) throws -> Bool {
    switch state {
    case .managed:
      guard let data else { return false }
      return try EnvironmentCodexDocument.matchesManaged(try utf8(data, at: url), source: url)
    case .original(let original):
      guard let data else { return !original.originalFileExisted }
      return try EnvironmentCodexDocument.matchesOriginal(
        try utf8(data, at: url), ownership: original, source: url)
    }
  }

  private func read(_ url: URL) throws -> Data? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return nil }
      throw EnvironmentLifecycleError.system("inspect Codex configuration", url, errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
      throw EnvironmentLifecycleError.blocked(
        "Codex configuration is not an ordinary file: \(url.path)"
      )
    }
    return try BoundedRegularFile.read(at: url, maximumSize: 1_048_576).data
  }

  private func utf8(_ data: Data, at url: URL) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked("Codex configuration is not UTF-8: \(url.path)")
    }
    return text
  }

  private func replace(_ data: Data, current: Data, at url: URL, replacementName: String) throws {
    guard data != current else { return }
    do {
      try SetupOwnershipManager().replaceRegularFile(
        target: url,
        replacementName: replacementName,
        homeDirectory: homeDirectory,
        expectedDigest: sha256Digest(current),
        data: data,
        label: "Codex [tui].theme selector"
      )
    } catch {
      throw EnvironmentLifecycleError.blocked("cannot replace Codex theme selector: \(error)")
    }
  }

  private func create(_ data: Data, at url: URL, replacementName: String) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let temporary = url.deletingLastPathComponent().appending(path: replacementName)
    try PinnedFilesystem.writeNewRegularFile(
      parentDescriptor: parent, name: replacementName, url: temporary, data: data, mode: 0o600)
    var removeTemporary = true
    defer {
      if removeTemporary { _ = replacementName.withCString { Darwin.unlinkat(parent, $0, 0) } }
    }
    let published = replacementName.withCString { source in
      url.lastPathComponent.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard published == 0 else {
      throw EnvironmentLifecycleError.system("publish Codex configuration", url, errno)
    }
    removeTemporary = false
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync Codex configuration parent", url, errno)
    }
  }

  private func claimAndRemove(at url: URL, replacementName: String, expected: Data) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let claimed = url.lastPathComponent.withCString { source in
      replacementName.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard claimed == 0 else {
      throw EnvironmentLifecycleError.system("claim Codex configuration", url, errno)
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync claimed Codex configuration", url, errno)
    }
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    guard try read(residue) == expected else {
      throw EnvironmentLifecycleError.drift("claimed Codex configuration")
    }
    try remove(residue)
  }

  private func remove(_ url: URL) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let removed = url.lastPathComponent.withCString { Darwin.unlinkat(parent, $0, 0) }
    guard removed == 0 || errno == ENOENT else {
      throw EnvironmentLifecycleError.system("remove Codex transaction residue", url, errno)
    }
    if removed == 0, fsync(parent) != 0 {
      throw EnvironmentLifecycleError.system("sync Codex transaction residue", url, errno)
    }
  }
}
