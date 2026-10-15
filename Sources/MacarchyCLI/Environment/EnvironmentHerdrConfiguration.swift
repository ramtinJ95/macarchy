import Darwin
import Foundation
import TOMLDecoder
import ThemeCore

struct EnvironmentHerdrOwnership: Codable, Equatable, Sendable {
  let path: String
  let resolvedPath: String
  let originalFileExisted: Bool
  let originalSelector: EnvironmentHerdrSelectorBoundary?
  let introducedThemeTable: Bool
  let introducedThemeTablePrefix: String
  let originalCustomTableExisted: Bool
  let introducedCustomTablePrefix: String
  let directoryLink: EnvironmentEntryEvidence?
  var directoryVolumeUUID: String?
  let migratedLegacy: Bool
  let managedTheme: GeneratedHerdrTheme

  enum CodingKeys: String, CodingKey {
    case path
    case resolvedPath = "resolved_path"
    case originalFileExisted = "original_file_existed"
    case originalSelector = "original_selector"
    case introducedThemeTable = "introduced_theme_table"
    case introducedThemeTablePrefix = "introduced_theme_table_prefix"
    case originalCustomTableExisted = "original_custom_table_existed"
    case introducedCustomTablePrefix = "introduced_custom_table_prefix"
    case directoryLink = "directory_link"
    case directoryVolumeUUID = "directory_volume_uuid"
    case migratedLegacy = "migrated_legacy"
    case managedTheme = "managed_theme"
  }

  init(
    path: String,
    resolvedPath: String,
    originalFileExisted: Bool,
    originalSelector: EnvironmentHerdrSelectorBoundary?,
    introducedThemeTable: Bool,
    introducedThemeTablePrefix: String,
    originalCustomTableExisted: Bool,
    introducedCustomTablePrefix: String,
    directoryLink: EnvironmentEntryEvidence?,
    directoryVolumeUUID: String? = nil,
    migratedLegacy: Bool = false,
    managedTheme: GeneratedHerdrTheme
  ) {
    self.path = path
    self.resolvedPath = resolvedPath
    self.originalFileExisted = originalFileExisted
    self.originalSelector = originalSelector
    self.introducedThemeTable = introducedThemeTable
    self.introducedThemeTablePrefix = introducedThemeTablePrefix
    self.originalCustomTableExisted = originalCustomTableExisted
    self.introducedCustomTablePrefix = introducedCustomTablePrefix
    self.directoryLink = directoryLink
    self.directoryVolumeUUID = directoryVolumeUUID
    self.migratedLegacy = migratedLegacy
    self.managedTheme = managedTheme
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    resolvedPath = try container.decode(String.self, forKey: .resolvedPath)
    originalFileExisted = try container.decode(Bool.self, forKey: .originalFileExisted)
    originalSelector = try container.decodeIfPresent(
      EnvironmentHerdrSelectorBoundary.self,
      forKey: .originalSelector
    )
    introducedThemeTable = try container.decode(Bool.self, forKey: .introducedThemeTable)
    introducedThemeTablePrefix = try container.decode(
      String.self,
      forKey: .introducedThemeTablePrefix
    )
    originalCustomTableExisted = try container.decode(
      Bool.self,
      forKey: .originalCustomTableExisted
    )
    introducedCustomTablePrefix = try container.decode(
      String.self,
      forKey: .introducedCustomTablePrefix
    )
    directoryLink = try container.decodeIfPresent(
      EnvironmentEntryEvidence.self,
      forKey: .directoryLink
    )
    directoryVolumeUUID = try container.decodeIfPresent(String.self, forKey: .directoryVolumeUUID)
    migratedLegacy = try container.decodeIfPresent(Bool.self, forKey: .migratedLegacy) ?? false
    managedTheme = try container.decode(GeneratedHerdrTheme.self, forKey: .managedTheme)
  }

  var hasValidShape: Bool {
    path.hasPrefix("/") && resolvedPath.hasPrefix("/")
      && (originalSelector?.hasValidShape ?? true)
      && (!introducedThemeTable || originalSelector == nil)
      && (originalFileExisted || (originalSelector == nil && introducedThemeTable))
      && Self.validPrefix(introducedThemeTablePrefix)
      && Self.validPrefix(introducedCustomTablePrefix)
      && ((try? managedTheme.validated()) != nil)
      && (directoryVolumeUUID.map { directoryLink != nil && UUID(uuidString: $0)?.uuidString == $0 }
        ?? true)
      && (directoryLink.map {
        $0.kind == .symbolicLink && $0.linkDestination != nil && $0.inventory.isEmpty
      } ?? true)
  }

  private static func validPrefix(_ value: String) -> Bool {
    ["", "\n", "\n\n", "\r\n", "\r\n\r\n"].contains(value)
  }

  func replacingManagedTheme(_ managedTheme: GeneratedHerdrTheme) -> Self {
    Self(
      path: path,
      resolvedPath: resolvedPath,
      originalFileExisted: originalFileExisted,
      originalSelector: originalSelector,
      introducedThemeTable: introducedThemeTable,
      introducedThemeTablePrefix: introducedThemeTablePrefix,
      originalCustomTableExisted: originalCustomTableExisted,
      introducedCustomTablePrefix: introducedCustomTablePrefix,
      directoryLink: directoryLink,
      directoryVolumeUUID: directoryVolumeUUID,
      migratedLegacy: migratedLegacy,
      managedTheme: managedTheme
    )
  }

  func hasSameBoundary(as other: Self) -> Bool {
    replacingManagedTheme(other.managedTheme) == other
  }
}

struct EnvironmentHerdrSelectorBoundary: Codable, Equatable, Sendable {
  let contents: String

  var hasValidShape: Bool {
    guard !contents.isEmpty, contents.utf8.count <= 4_096 else { return false }
    let wrapped = "[theme]\n" + contents
    let selector = CanonicalTOMLSelector(configuration: wrapped, table: "theme", key: "name")
    guard selector.assignments.count == 1 else { return false }
    return (try? HerdrAdapter.parseConfiguration(wrapped).selection) != nil
  }
}

struct EnvironmentHerdrDocument {
  static func ownership(
    original: String,
    source: URL,
    resolvedSource: URL,
    originalFileExisted: Bool,
    directoryLink: EnvironmentEntryEvidence?,
    migratedLegacy: Bool,
    managedTheme: GeneratedHerdrTheme
  ) throws -> EnvironmentHerdrOwnership {
    try validateDocument(original, source: source)
    let selector = CanonicalTOMLSelector(configuration: original, table: "theme", key: "name")
    guard selector.tableHeaderCount <= 1, selector.assignments.count <= 1 else {
      throw EnvironmentLifecycleError.blocked(
        "Herdr configuration has an ambiguous [theme].name boundary: \(source.path)"
      )
    }
    if selector.tableHeaderCount == 1 {
      let parsed = try HerdrAdapter.parseConfiguration(original)
      guard parsed.custom.isEmpty else {
        throw EnvironmentLifecycleError.blocked(
          "pre-existing Herdr custom colors conflict with the managed theme surface"
        )
      }
    }
    let custom = CanonicalTOMLSelector(
      configuration: original,
      table: "theme.custom",
      key: HerdrAdapter.customKeys[0]
    )
    let boundary = selector.assignments.first.map {
      EnvironmentHerdrSelectorBoundary(contents: String(original[$0.fullRange]))
    }
    let themePrefix = selector.tableHeaderCount == 0 ? themeInsertionPrefix(in: original) : ""
    var named = original
    if selector.tableHeaderCount == 0 {
      named += themePrefix + "[theme]" + tomlPreferredNewline(in: original)
    }
    let namedParsed = try HerdrAdapter.parseConfiguration(named)
    named = try HerdrAdapter.replacingManagedSurface(
      in: named,
      parsed: namedParsed,
      with: HerdrAdapter.ManagedSurface(name: "catppuccin", custom: [:])
    )
    let customPrefix = custom.tableHeaderCount == 0 ? insertionPrefix(in: named) : ""
    return EnvironmentHerdrOwnership(
      path: source.path,
      resolvedPath: resolvedSource.path,
      originalFileExisted: originalFileExisted,
      originalSelector: boundary,
      introducedThemeTable: selector.tableHeaderCount == 0,
      introducedThemeTablePrefix: themePrefix,
      originalCustomTableExisted: custom.tableHeaderCount == 1,
      introducedCustomTablePrefix: customPrefix,
      directoryLink: directoryLink,
      migratedLegacy: migratedLegacy,
      managedTheme: try managedTheme.validated()
    )
  }

  static func matchesManaged(_ text: String, desired: GeneratedHerdrTheme, source: URL) throws
    -> Bool
  {
    try validateDocument(text, source: source)
    let parsed = try HerdrAdapter.parseConfiguration(text)
    return parsed.selection == desired.name
      && parsed.custom == desired.custom.mapValues { $0.lowercased() }
  }

  static func applyingManaged(_ text: String, desired: GeneratedHerdrTheme, source: URL) throws
    -> String
  {
    try applyingManaged(text, desired: desired, replacing: nil, source: source)
  }

  static func applyingManaged(
    _ text: String,
    desired: GeneratedHerdrTheme,
    replacing expected: GeneratedHerdrTheme?,
    source: URL
  ) throws -> String {
    try validateDocument(text, source: source)
    var base = text
    let selector = CanonicalTOMLSelector(configuration: base, table: "theme", key: "name")
    guard selector.tableHeaderCount <= 1, selector.assignments.count <= 1 else {
      throw EnvironmentLifecycleError.blocked(
        "Herdr configuration has an ambiguous [theme].name boundary: \(source.path)"
      )
    }
    if selector.tableHeaderCount == 0 {
      let newline = tomlPreferredNewline(in: base)
      if !base.isEmpty, !base.hasSuffix("\n"), !base.hasSuffix("\r") { base += newline }
      if !base.isEmpty { base += newline }
      base += "[theme]" + newline
    }
    let parsed = try HerdrAdapter.parseConfiguration(base)
    let replacesAuthenticatedSurface =
      expected.map {
        parsed.selection == $0.name
          && parsed.custom == $0.custom.mapValues { $0.lowercased() }
      } ?? false
    guard parsed.custom.isEmpty || replacesAuthenticatedSurface else {
      throw EnvironmentLifecycleError.blocked(
        "pre-existing Herdr custom colors conflict with the managed theme surface"
      )
    }
    let result = try HerdrAdapter.replacingManagedSurface(
      in: base,
      parsed: parsed,
      with: HerdrAdapter.ManagedSurface(name: desired.name, custom: desired.custom)
    )
    guard try matchesManaged(result, desired: desired, source: source) else {
      throw EnvironmentLifecycleError.blocked("cannot install the Herdr theme surface")
    }
    return result
  }

  static func restoringOriginal(
    in text: String,
    ownership: EnvironmentHerdrOwnership,
    source: URL
  ) throws -> String {
    try validateDocument(text, source: source)
    let parsed = try HerdrAdapter.parseConfiguration(text)
    let withoutCustom = try HerdrAdapter.replacingManagedSurface(
      in: text,
      parsed: parsed,
      with: HerdrAdapter.ManagedSurface(
        name: parsed.selection,
        custom: [:]
      )
    )
    let selector = CanonicalTOMLSelector(
      configuration: withoutCustom,
      table: "theme",
      key: "name"
    )
    guard selector.tableHeaderCount == 1, selector.assignments.count == 1,
      let assignment = selector.assignments.first
    else { throw EnvironmentLifecycleError.drift(source.path) }
    var result = withoutCustom
    if let original = ownership.originalSelector {
      result.replaceSubrange(assignment.fullRange, with: original.contents)
    } else {
      result.removeSubrange(assignment.fullRange)
    }
    if !ownership.originalCustomTableExisted {
      result = removeEmptyTable(
        "theme.custom",
        from: result,
        introducedPrefix: ownership.introducedCustomTablePrefix
      )
    }
    if ownership.introducedThemeTable {
      result = removeEmptyTable(
        "theme",
        from: result,
        introducedPrefix: ownership.introducedThemeTablePrefix
      )
    }
    if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try validateDocument(result, source: source)
    }
    return result
  }

  static func matchesOriginal(
    _ text: String,
    ownership: EnvironmentHerdrOwnership,
    source: URL
  ) throws -> Bool {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return !ownership.originalFileExisted
    }
    try validateDocument(text, source: source)
    guard try HerdrAdapter.parseConfiguration(text).custom.isEmpty else { return false }
    let selector = CanonicalTOMLSelector(configuration: text, table: "theme", key: "name")
    if let original = ownership.originalSelector {
      guard selector.assignments.count == 1,
        let assignment = selector.assignments.first,
        text[assignment.fullRange] == original.contents
      else { return false }
    } else if !selector.assignments.isEmpty {
      return false
    }
    return selector.tableHeaderCount == 1
      || ownership.introducedThemeTable || !ownership.originalFileExisted
  }

  private static func validateDocument(_ text: String, source: URL) throws {
    guard !text.isEmpty else { return }
    do {
      _ = try TOMLTable(source: text)
    } catch {
      throw EnvironmentLifecycleError.blocked(
        "invalid Herdr TOML configuration at \(source.path): \(error)"
      )
    }
  }

  private static func removeEmptyTable(
    _ name: String,
    from text: String,
    introducedPrefix: String
  ) -> String {
    let lines = tomlPhysicalLines(text)
    guard
      let headerIndex = lines.firstIndex(where: {
        text[$0.contentRange].trimmingCharacters(in: .whitespacesAndNewlines) == "[\(name)]"
      })
    else { return text }
    let end =
      lines[(headerIndex + 1)...].firstIndex(where: {
        text[$0.contentRange].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
      }) ?? lines.endIndex
    let body = lines[(headerIndex + 1)..<end].map {
      text[$0.contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard body.allSatisfy({ $0.isEmpty }) else { return text }
    var lower = lines[headerIndex].fullRange.lowerBound
    if !introducedPrefix.isEmpty,
      let prefixStart = text.index(
        lower, offsetBy: -introducedPrefix.count, limitedBy: text.startIndex),
      text[prefixStart..<lower] == introducedPrefix
    {
      lower = prefixStart
    }
    var result = text
    let upper = end < lines.endIndex ? lines[end].fullRange.lowerBound : text.endIndex
    result.removeSubrange(lower..<upper)
    return result
  }

  private static func insertionPrefix(in text: String) -> String {
    let newline = tomlPreferredNewline(in: text)
    var candidate = text
    var prefix = ""
    if !candidate.isEmpty, !candidate.hasSuffix("\n"), !candidate.hasSuffix("\r") {
      candidate += newline
      prefix += newline
    }
    if !candidate.isEmpty, !candidate.hasSuffix(newline + newline) {
      prefix += newline
    }
    return prefix
  }

  private static func themeInsertionPrefix(in text: String) -> String {
    guard !text.isEmpty else { return "" }
    let newline = tomlPreferredNewline(in: text)
    return text.hasSuffix("\n") || text.hasSuffix("\r") ? newline : newline + newline
  }
}

struct EnvironmentHerdrFileTransaction: Sendable {
  private static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Herdr configuration",
    residueLabel: "Herdr transaction residue",
    nonRegularMessage: "Herdr configuration is not an ordinary single-link file"
  )

  private enum ExpectedState: Equatable {
    case original
    case managed(GeneratedHerdrTheme)
  }

  let homeDirectory: URL
  let stateRoot: URL

  func preflight(_ ownership: EnvironmentHerdrOwnership) throws {
    let url = URL(filePath: ownership.path)
    try validateTopology(ownership, at: url)
    guard
      try EnvironmentHerdrDocument.matchesManaged(
        read(ownership), desired: ownership.managedTheme, source: url
      )
    else { throw EnvironmentLifecycleError.drift(url.path) }
  }

  func preflightOriginal(_ ownership: EnvironmentHerdrOwnership) throws {
    let url = URL(filePath: ownership.path)
    try validateTopology(ownership, at: url)
    let data = try Self.filesystem.read(URL(filePath: ownership.resolvedPath))
    if data == nil, !ownership.originalFileExisted { return }
    guard let data,
      try EnvironmentHerdrDocument.matchesOriginal(
        try Self.filesystem.utf8(data, at: url), ownership: ownership, source: url)
    else { throw EnvironmentLifecycleError.drift(url.path) }
  }

  func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    replacementName: String,
    preserveLegacyManagedOnRemoval: Bool = false
  ) throws {
    guard let ownership = old?.herdr ?? new?.herdr else { return }
    if let before = old?.herdr, let after = new?.herdr, !before.hasSameBoundary(as: after) {
      throw EnvironmentLifecycleError.blocked("Herdr ownership changed unexpectedly")
    }
    let url = URL(filePath: ownership.path)
    try validateTopology(ownership, at: url)
    let wasEnabled = preserveLegacyManagedOnRemoval ? false : old?.herdrEnabled == true
    let willBeEnabled = preserveLegacyManagedOnRemoval ? true : new?.herdrEnabled == true
    let source: ExpectedState =
      wasEnabled
      ? .managed(try requiredManagedTheme(old)) : .original
    let target: ExpectedState =
      if preserveLegacyManagedOnRemoval {
        .managed(try ownership.managedTheme.validated())
      } else if willBeEnabled {
        .managed(try requiredManagedTheme(new))
      } else {
        .original
      }
    guard source != target else { return }
    let targetURL = URL(filePath: ownership.resolvedPath)
    let residueURL = targetURL.deletingLastPathComponent().appending(path: replacementName)
    var current = try Self.filesystem.read(targetURL)
    if let residue = try Self.filesystem.read(residueURL) {
      if try matches(current, target, ownership: ownership, source: url),
        try matches(residue, source, ownership: ownership, source: residueURL)
      {
        try Self.filesystem.remove(residueURL)
        return
      }
      if try matches(current, source, ownership: ownership, source: url),
        try matches(residue, target, ownership: ownership, source: residueURL)
      {
        try Self.filesystem.remove(residueURL)
      } else {
        throw EnvironmentLifecycleError.drift("Herdr replacement residue")
      }
      current = try Self.filesystem.read(targetURL)
    }
    if try matches(current, target, ownership: ownership, source: url) { return }
    guard try matches(current, source, ownership: ownership, source: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }

    switch target {
    case .managed(let desired):
      let currentText = try current.map { try Self.filesystem.utf8($0, at: url) } ?? ""
      let updated = try EnvironmentHerdrDocument.applyingManaged(
        currentText,
        desired: desired,
        replacing: {
          if case .managed(let expected) = source { return expected }
          return nil
        }(),
        source: url
      )
      if let current {
        try replace(
          Data(updated.utf8), current: current, at: targetURL, replacementName: replacementName
        )
      } else {
        try create(Data(updated.utf8), at: targetURL, replacementName: replacementName)
      }
    case .original:
      guard let current else { return }
      let restored = try EnvironmentHerdrDocument.restoringOriginal(
        in: try Self.filesystem.utf8(current, at: url), ownership: ownership, source: url
      )
      if !ownership.originalFileExisted,
        restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        try Self.filesystem.claimAndRemove(
          at: targetURL, replacementName: replacementName, expected: current)
      } else {
        try replace(
          Data(restored.utf8), current: current, at: targetURL, replacementName: replacementName
        )
      }
    }
    guard
      try matches(
        try Self.filesystem.read(targetURL), target, ownership: ownership, source: url)
    else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  private func matches(
    _ data: Data?,
    _ state: ExpectedState,
    ownership: EnvironmentHerdrOwnership,
    source: URL
  ) throws -> Bool {
    switch state {
    case .managed(let desired):
      guard let data else { return false }
      return try EnvironmentHerdrDocument.matchesManaged(
        try Self.filesystem.utf8(data, at: source),
        desired: desired,
        source: source
      )
    case .original:
      guard let data else { return !ownership.originalFileExisted }
      return try EnvironmentHerdrDocument.matchesOriginal(
        try Self.filesystem.utf8(data, at: source), ownership: ownership, source: source
      )
    }
  }

  private func requiredManagedTheme(_ ownership: EnvironmentOwnership?) throws
    -> GeneratedHerdrTheme
  {
    guard let desired = ownership?.herdr?.managedTheme else {
      throw EnvironmentLifecycleError.blocked("enabled Herdr ownership has no managed theme")
    }
    return try desired.validated()
  }

  private func validateTopology(_ ownership: EnvironmentHerdrOwnership, at url: URL) throws {
    guard url == homeDirectory.appending(path: ".config/herdr/config.toml"),
      url.resolvingSymlinksInPath().path == ownership.resolvedPath
    else { throw EnvironmentLifecycleError.blocked("Herdr ownership path is invalid") }
    if let expected = ownership.directoryLink {
      let directory = url.deletingLastPathComponent()
      try EnvironmentHerdrDirectoryIdentity.validate(
        expected, volumeUUID: ownership.directoryVolumeUUID, at: directory)
    }
  }

  private func read(_ ownership: EnvironmentHerdrOwnership) throws -> String {
    let url = URL(filePath: ownership.resolvedPath)
    guard let data = try Self.filesystem.read(url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
    return try Self.filesystem.utf8(data, at: url)
  }

  private func replace(_ data: Data, current: Data, at url: URL, replacementName: String) throws {
    try Self.filesystem.replace(
      data, current: current, at: url, replacementName: replacementName,
      homeDirectory: homeDirectory, label: "Herdr theme surface"
    )
  }

  private func create(_ data: Data, at url: URL, replacementName: String) throws {
    try ensureSafeEnvironmentParent(
      of: url, homeDirectory: homeDirectory,
      outsideHomeMessage: "Herdr configuration target is outside the selected home")
    try Self.filesystem.create(data, at: url, replacementName: replacementName)
  }
}

/// Persisted Herdr link identity survives mount renumbering; approval/race evidence stays strict.
enum EnvironmentHerdrDirectoryIdentity {
  static func volumeUUID(at url: URL, matching evidence: EnvironmentEntryEvidence) throws -> String
  {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      evidence.kind == .symbolicLink, metadata.st_mode & S_IFMT == S_IFLNK,
      UInt64(metadata.st_dev) == evidence.device, UInt64(metadata.st_ino) == evidence.inode,
      UInt32(metadata.st_mode) == evidence.mode, Int64(metadata.st_size) == evidence.size
    else { throw EnvironmentLifecycleError.drift("Herdr directory symlink") }
    return try RetainedOriginalIdentity.volumeUUID(at: url, matching: metadata)
  }

  static func validate(
    _ expected: EnvironmentEntryEvidence, volumeUUID: String?, at url: URL
  ) throws {
    let observed = try EnvironmentProviderInspector().capture(url, directoryLink: nil)
    guard let volumeUUID else {
      // Legacy receipts cannot establish their historical volume. Do not silently rebind them.
      guard observed == expected else {
        throw EnvironmentLifecycleError.drift(
          "Herdr directory symlink; review `macarchy environment migrate-ownership herdr`")
      }
      return
    }
    guard try self.volumeUUID(at: url, matching: observed) == volumeUUID else {
      throw EnvironmentLifecycleError.drift("Herdr directory symlink volume")
    }
    // UUID authenticates the volume; retain every other existing link/metadata check.
    let expectedOnCurrentMount = EnvironmentEntryEvidence(
      kind: expected.kind, device: observed.device, inode: expected.inode, mode: expected.mode,
      size: expected.size, linkDestination: expected.linkDestination,
      contentDigest: expected.contentDigest, metadataDigest: expected.metadataDigest,
      inventory: expected.inventory)
    guard observed == expectedOnCurrentMount else {
      throw EnvironmentLifecycleError.drift("Herdr directory symlink")
    }
  }
}
