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
      let newline = preferredNewline(in: text)
      result = String(text[..<insertion]) + managedSelector + newline + text[insertion...]
    } else if text.isEmpty {
      result = managedSelector + "\n"
    } else if tomlPhysicalLines(text).last?.terminator.isEmpty == false {
      result = text + managedSelector + preferredNewline(in: text)
    } else {
      result = text + preferredNewline(in: text) + managedSelector
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
        ? preferredNewline(in: result) : ""
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

  private static func preferredNewline(in text: String) -> String {
    tomlPhysicalLines(text).first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
  }
}

private struct TuicrValidationDocument: Decodable {
  let theme: String?
}

struct EnvironmentTuicrFileTransaction: Sendable {
  private static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "tuicr configuration",
    residueLabel: "tuicr transaction residue"
  )

  private enum ExpectedState {
    case original(EnvironmentTuicrOwnership)
    case managed
  }

  let homeDirectory: URL

  func preflight(_ ownership: EnvironmentTuicrOwnership) throws {
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
    guard let ownership = old?.tuicr ?? new?.tuicr else { return }
    if let oldTuicr = old?.tuicr, let newTuicr = new?.tuicr, oldTuicr != newTuicr {
      throw EnvironmentLifecycleError.blocked("tuicr ownership changed unexpectedly")
    }
    let url = URL(filePath: ownership.path)
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    let source: ExpectedState = old?.tuicr == nil ? .original(ownership) : .managed
    let target: ExpectedState = new?.tuicr == nil ? .original(ownership) : .managed
    var current = try read(url)
    if let residueData = try read(residue) {
      if try matches(current, target, ownership: ownership, at: url),
        try matches(residueData, source, ownership: ownership, at: residue)
      {
        try Self.filesystem.remove(residue)
        return
      }
      if try matches(current, source, ownership: ownership, at: url),
        try matches(residueData, target, ownership: ownership, at: residue)
      {
        try Self.filesystem.remove(residue)
      } else {
        throw EnvironmentLifecycleError.drift("tuicr replacement residue")
      }
      current = try read(url)
    }
    if try matches(current, target, ownership: ownership, at: url) { return }
    guard try matches(current, source, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }

    switch target {
    case .managed:
      let updated = try EnvironmentTuicrDocument.applyingManaged(
        to: current.map { try utf8($0, at: url) } ?? "",
        source: url
      )
      let data = Data(updated.utf8)
      if let current {
        try replace(data, current: current, at: url, replacementName: replacementName)
      } else {
        try Self.filesystem.create(data, at: url, replacementName: replacementName)
      }
    case .original(let original):
      guard let current else { return }
      let restored = try EnvironmentTuicrDocument.restoringOriginal(
        in: try utf8(current, at: url),
        ownership: original,
        source: url
      )
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
    ownership: EnvironmentTuicrOwnership,
    at url: URL
  ) throws -> Bool {
    switch state {
    case .managed:
      guard let data else { return false }
      return try EnvironmentTuicrDocument.matchesManaged(try utf8(data, at: url), source: url)
    case .original(let original):
      guard let data else { return !original.originalFileExisted }
      return try EnvironmentTuicrDocument.matchesOriginal(
        try utf8(data, at: url),
        ownership: original,
        source: url
      )
    }
  }

  private func read(_ url: URL) throws -> Data? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return nil }
      throw EnvironmentLifecycleError.system("inspect tuicr configuration", url, errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
      throw EnvironmentLifecycleError.blocked(
        "tuicr configuration is not an ordinary file: \(url.path)"
      )
    }
    return try BoundedRegularFile.read(at: url, maximumSize: 1_048_576).data
  }

  private func utf8(_ data: Data, at url: URL) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked("tuicr configuration is not UTF-8: \(url.path)")
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
        label: "tuicr theme selector"
      )
    } catch {
      throw EnvironmentLifecycleError.blocked("cannot replace tuicr theme selector: \(error)")
    }
  }

  private func claimAndRemove(at url: URL, replacementName: String, expected: Data) throws {
    try Self.filesystem.claimAndRemove(at: url, replacementName: replacementName) { residue in
      guard try read(residue) == expected else {
        throw EnvironmentLifecycleError.drift("claimed tuicr configuration")
      }
    }
  }
}
