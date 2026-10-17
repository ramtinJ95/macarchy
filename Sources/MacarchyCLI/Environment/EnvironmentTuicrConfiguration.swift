import Darwin
import Foundation
import TOMLDecoder
import ThemeCore

struct EnvironmentTuicrOwnership: Codable, Equatable, Sendable {
  let path: String
  let originalFileExisted: Bool
  let originalSelector: EnvironmentTuicrSelectorBoundary?
  let insertedSeparatorBefore: Bool

  enum CodingKeys: String, CodingKey {
    case path
    case originalFileExisted = "original_file_existed"
    case originalSelector = "original_selector"
    case insertedSeparatorBefore = "inserted_separator_before"
  }

  var hasValidShape: Bool {
    path.hasPrefix("/")
      && (originalSelector?.hasValidShape ?? true)
      && (!insertedSeparatorBefore || originalSelector == nil)
      && (originalFileExisted || (originalSelector == nil && !insertedSeparatorBefore))
  }
}

struct EnvironmentTuicrSelectorBoundary: Codable, Equatable, Sendable {
  let contents: String
  let lineIndex: Int

  var hasValidShape: Bool {
    guard !contents.isEmpty, contents.utf8.count <= 4_096, lineIndex >= 0,
      (try? TOMLDecoder().decode(TuicrValidationDocument.self, from: contents).theme) != nil
    else { return false }
    let selector = CanonicalTOMLSelector(
      configuration: contents,
      key: TuicrAdapter.selectionKey
    )
    return selector.assignments.count == 1
      && selector.assignments[0].fullRange == contents.startIndex..<contents.endIndex
  }
}

struct EnvironmentTuicrDocument {
  private static var managedSelector: String {
    "theme = \"\(TuicrAdapter.themeName)\""
  }

  static func matchesManaged(_ text: String, source: URL) throws -> Bool {
    let document = try validatedDocument(text, source: source)
    let assignments = CanonicalTOMLSelector(
      configuration: text,
      key: TuicrAdapter.selectionKey
    ).assignments
    return document.theme == TuicrAdapter.themeName
      && assignments.count == 1
      && text[assignments[0].contentRange] == managedSelector
  }

  static func ownership(for text: String, source: URL) throws -> EnvironmentTuicrOwnership {
    _ = try validatedDocument(text, source: source)
    let selector = CanonicalTOMLSelector(configuration: text, key: TuicrAdapter.selectionKey)
    guard selector.assignments.count <= 1 else {
      throw EnvironmentLifecycleError.blocked(
        "tuicr configuration has duplicate root theme selectors: \(source.path)"
      )
    }
    let lines = tomlPhysicalLines(text)
    let originalSelector = selector.assignments.first.map {
      EnvironmentTuicrSelectorBoundary(
        contents: String(text[$0.fullRange]),
        lineIndex: $0.lineIndex
      )
    }
    let insertedSeparatorBefore =
      originalSelector == nil
      && selector.firstTopLevelTableIndex == nil
      && !text.isEmpty
      && lines.last?.terminator.isEmpty == true
    return EnvironmentTuicrOwnership(
      path: source.path,
      originalFileExisted: true,
      originalSelector: originalSelector,
      insertedSeparatorBefore: insertedSeparatorBefore
    )
  }

  static func applyingManaged(to text: String, source: URL) throws -> String {
    _ = try validatedDocument(text, source: source)
    let selector = CanonicalTOMLSelector(configuration: text, key: TuicrAdapter.selectionKey)
    guard selector.assignments.count <= 1 else {
      throw EnvironmentLifecycleError.blocked(
        "tuicr configuration has duplicate root theme selectors: \(source.path)"
      )
    }
    let result: String
    if let assignment = selector.assignments.first {
      var updated = text
      updated.replaceSubrange(assignment.contentRange, with: managedSelector)
      result = updated
    } else if let insertion = selector.firstTopLevelTableIndex {
      let newline = tomlPreferredNewline(in: text)
      result = String(text[..<insertion]) + managedSelector + newline + text[insertion...]
    } else if text.isEmpty {
      result = managedSelector + "\n"
    } else if tomlPhysicalLines(text).last?.terminator.isEmpty == false {
      result = text + managedSelector + tomlPreferredNewline(in: text)
    } else {
      result = text + tomlPreferredNewline(in: text) + managedSelector
    }
    _ = try validatedDocument(result, source: source)
    return result
  }

  static func restoringOriginal(
    in text: String,
    ownership: EnvironmentTuicrOwnership,
    source: URL
  ) throws -> String {
    _ = try validatedDocument(text, source: source)
    let selector = CanonicalTOMLSelector(configuration: text, key: TuicrAdapter.selectionKey)
    guard selector.assignments.count == 1, let managed = selector.assignments.first else {
      throw EnvironmentLifecycleError.drift(source.path)
    }
    let hasFollowingContent = managed.fullRange.upperBound < text.endIndex
    var result = text
    let removalStart = managed.fullRange.lowerBound
    result.removeSubrange(managed.fullRange)
    if ownership.insertedSeparatorBefore, !hasFollowingContent,
      removalStart > result.startIndex
    {
      let before = result.index(before: removalStart)
      if result[before].isNewline {
        result.removeSubrange(before..<removalStart)
      }
    }
    if let original = ownership.originalSelector {
      let lines = tomlPhysicalLines(result)
      let insertion =
        original.lineIndex < lines.count
        ? lines[original.lineIndex].fullRange.lowerBound : result.endIndex
      let separator =
        insertion < result.endIndex
          && tomlPhysicalLines(original.contents).last?.terminator.isEmpty == true
        ? tomlPreferredNewline(in: result) : ""
      result.insert(contentsOf: original.contents + separator, at: insertion)
    }
    if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      _ = try validatedDocument(result, source: source)
    }
    return result
  }

  static func matchesOriginal(
    _ text: String,
    ownership: EnvironmentTuicrOwnership,
    source: URL
  ) throws -> Bool {
    _ = try validatedDocument(text, source: source)
    let assignments = CanonicalTOMLSelector(
      configuration: text,
      key: TuicrAdapter.selectionKey
    ).assignments
    guard let original = ownership.originalSelector else { return assignments.isEmpty }
    guard assignments.count == 1, let assignment = assignments.first else { return false }
    return assignment.lineIndex == original.lineIndex
      && text[assignment.fullRange] == original.contents
  }

  private static func validatedDocument(
    _ text: String,
    source: URL
  ) throws -> TuicrValidationDocument {
    do {
      return try TOMLDecoder().decode(TuicrValidationDocument.self, from: text)
    } catch {
      throw EnvironmentLifecycleError.blocked(
        "invalid tuicr TOML configuration at \(source.path): \(error)"
      )
    }
  }
}

private struct TuicrValidationDocument: Decodable {
  let theme: String?
}

typealias EnvironmentTuicrFileTransaction = EnvironmentPresetFileTransaction<
  EnvironmentTuicrOwnership
>

extension EnvironmentTuicrOwnership: EnvironmentPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "tuicr configuration",
    residueLabel: "tuicr transaction residue",
    nonRegularMessage: "tuicr configuration is not an ordinary file"
  )
  static let driftLabel = "tuicr"
  static let ownershipChangedMessage = "tuicr ownership changed unexpectedly"
  static let replacementLabel = "tuicr theme selector"
  static let replacementFailureLabel: String? = nil

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.tuicr }

  static func managed(from current: Data?, at url: URL) throws -> Data {
    let updated = try EnvironmentTuicrDocument.applyingManaged(
      to: current.map { try filesystem.utf8($0, at: url) } ?? "",
      source: url
    )
    return Data(updated.utf8)
  }

  static func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    try EnvironmentTuicrDocument.matchesManaged(try filesystem.utf8(data, at: url), source: url)
  }

  func restored(in current: Data, at url: URL) throws -> Data? {
    let restored = try EnvironmentTuicrDocument.restoringOriginal(
      in: try Self.filesystem.utf8(current, at: url), ownership: self, source: url)
    if !originalFileExisted, restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return nil
    }
    return Data(restored.utf8)
  }

  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return !originalFileExisted }
    return try EnvironmentTuicrDocument.matchesOriginal(
      try Self.filesystem.utf8(data, at: url), ownership: self, source: url)
  }
}
