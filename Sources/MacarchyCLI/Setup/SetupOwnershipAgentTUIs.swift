import Darwin
import Foundation
import TOMLDecoder
import ThemeCore

extension SetupOwnershipManager {
  func setupPiSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if let record = records.first(where: { $0.id == Self.piSelectorID }) {
      return try resumePiSelector(
        record: record,
        context: context,
        dryRun: dryRun,
        records: &records
      )
    }

    let replacement = piSelectorReplacementURL(context: context)
    guard try itemExists(replacement) == false else {
      throw SetupOwnershipError.orphanedReplacement(replacement)
    }
    let original = try readConfiguration(context.piConfiguration, id: Self.piSelectorID)
    if try jsonSelectionIsExternal(
      original,
      key: PiAdapter.selectionKey,
      value: PiAdapter.themeName,
      id: Self.piSelectorID,
      target: context.piConfiguration
    ) {
      return integrationResult(
        id: Self.piSelectorID,
        target: context.piConfiguration,
        status: .external,
        message: "The exact Pi theme selector is already externally owned"
      )
    }
    guard try pathContainsSymlink(context.piConfiguration, below: context.homeDirectory) == false
    else {
      throw SetupOwnershipError.configurationIsExternallyOwned(
        Self.piSelectorID,
        context.piConfiguration
      )
    }

    let installed = try installedConfiguration(
      id: Self.piSelectorID,
      target: context.piConfiguration,
      original: original,
      transform: {
        try addingJSONSelection(
          to: $0,
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: Self.piSelectorID,
          target: context.piConfiguration
        )
      }
    )
    if dryRun {
      return integrationResult(
        id: Self.piSelectorID,
        target: context.piConfiguration,
        status: .planned,
        message: "Would add the exact Pi theme selector"
      )
    }

    let record = SetupOwnershipRecord(
      id: Self.piSelectorID,
      phase: .prepared,
      kind: .jsonSelector,
      targetPath: context.piConfiguration.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: piSelectorContractDigest(),
      linkDestination: nil
    )
    do {
      try save(record: record, records: &records, context: context)
      try faultInjector(.manifestPrepared)
      try replaceRegularFile(
        target: context.piConfiguration,
        replacementName: context.piSelectorReplacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: sha256Digest(original),
        data: installed,
        label: "Pi theme selector"
      )
      try faultInjector(.targetWritten)
      try save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(
        error,
        integrationID: Self.piSelectorID,
        target: context.piConfiguration
      )
    }
    return integrationResult(
      id: Self.piSelectorID,
      target: context.piConfiguration,
      status: .owned,
      message: "Added the Pi theme selector and recorded key-level ownership",
      mutationAttempted: true
    )
  }

  func setupPiThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.piThemeLinkID,
      target: context.piThemeLink,
      destination: context.piThemeDestination,
      label: "Pi theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupHerdrSelector(context: Context) throws -> SetupIntegrationResult {
    let data = try readConfiguration(context.herdrConfiguration, id: Self.herdrSelectorID)
    let configuration = String(decoding: data, as: UTF8.self)
    do {
      try HerdrAdapter.validateConfiguration(configuration)
    } catch {
      throw SetupOwnershipError.invalidConfiguration(
        Self.herdrSelectorID,
        context.herdrConfiguration,
        String(describing: error)
      )
    }
    return integrationResult(
      id: Self.herdrSelectorID,
      target: context.herdrConfiguration,
      status: .external,
      message: "Herdr's runtime-mutated selector remains adapter-managed and externally owned"
    )
  }

  func setupTuicrSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupRegularFile(
      id: Self.tuicrSelectorID,
      target: context.tuicrConfiguration,
      backupURL: context.tuicrSelectorBackup,
      replacementName: context.tuicrSelectorReplacementName,
      label: "tuicr theme selector",
      read: { try readConfiguration($0, id: Self.tuicrSelectorID) },
      isExternal: {
        try tomlRootSelectionIsExternal(
          $0,
          key: TuicrAdapter.selectionKey,
          value: TuicrAdapter.themeName,
          id: Self.tuicrSelectorID,
          target: context.tuicrConfiguration
        )
      },
      installedData: {
        try addingTOMLRootSelection(
          to: $0,
          key: TuicrAdapter.selectionKey,
          value: TuicrAdapter.themeName,
          id: Self.tuicrSelectorID,
          target: context.tuicrConfiguration
        )
      },
      externalOwnershipError: .configurationIsExternallyOwned(
        Self.tuicrSelectorID,
        context.tuicrConfiguration
      ),
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupTuicrThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.tuicrThemeLinkID,
      target: context.tuicrThemeLink,
      destination: context.tuicrThemeDestination,
      label: "tuicr palette",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupTuicrSyntaxLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.tuicrSyntaxLinkID,
      target: context.tuicrSyntaxLink,
      destination: context.tuicrSyntaxDestination,
      label: "tuicr syntax theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupCodexSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupTOMLSelector(
      id: Self.codexSelectorID,
      target: context.codexConfiguration,
      backupURL: context.codexSelectorBackup,
      replacementName: context.codexSelectorReplacementName,
      label: "Codex TUI theme selector",
      table: CodexAdapter.selectionTable,
      key: CodexAdapter.selectionKey,
      value: CodexAdapter.themeName,
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupCodexThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.codexThemeLinkID,
      target: context.codexThemeLink,
      destination: context.codexThemeDestination,
      label: "Codex TextMate theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func teardownPiSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    guard let record = records.first(where: { $0.id == Self.piSelectorID }) else {
      return integrationResult(
        id: Self.piSelectorID,
        target: context.piConfiguration,
        status: .none,
        message: "No Macarchy-owned Pi theme selector exists"
      )
    }
    try validatePiSelectorRecord(record, context: context)
    guard
      try regularFilePathContainsSymlink(
        id: Self.piSelectorID,
        target: context.piConfiguration,
        context: context
      ) == false
    else {
      throw SetupOwnershipError.ownershipDrift(context.piConfiguration)
    }
    let residueExists = try validatePiSelectorReplacementResidue(
      context: context,
      remove: false
    )
    let current = try readConfiguration(context.piConfiguration, id: Self.piSelectorID)
    let state = try ownedPiSelectionState(current, context: context)
    if dryRun {
      return integrationResult(
        id: Self.piSelectorID,
        target: context.piConfiguration,
        status: .planned,
        message:
          state == .exact
          ? "Would remove only the recorded Pi theme selector"
          : "Would clear the already-removed Pi selector ownership record"
      )
    }

    do {
      if residueExists {
        _ = try validatePiSelectorReplacementResidue(context: context, remove: true)
      }
      if state == .exact {
        let updated = try removingJSONSelection(
          from: current,
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: Self.piSelectorID,
          target: context.piConfiguration
        )
        try faultInjector(.teardownReady)
        try replaceRegularFile(
          target: context.piConfiguration,
          replacementName: context.piSelectorReplacementName,
          homeDirectory: context.homeDirectory,
          expectedDigest: sha256Digest(current),
          data: updated,
          label: "Pi theme selector"
        )
      }
      records.removeAll { $0.id == Self.piSelectorID }
      try persist(records: records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(
        error,
        integrationID: Self.piSelectorID,
        target: context.piConfiguration
      )
    }
    return integrationResult(
      id: Self.piSelectorID,
      target: context.piConfiguration,
      status: .removed,
      message: "Removed only the recorded Pi theme selector ownership",
      mutationAttempted: true
    )
  }

  func teardownPiThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try teardownThemeLink(
      id: Self.piThemeLinkID,
      target: context.piThemeLink,
      destination: context.piThemeDestination,
      label: "Pi theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func teardownHerdrSelector(context: Context) -> SetupIntegrationResult {
    integrationResult(
      id: Self.herdrSelectorID,
      target: context.herdrConfiguration,
      status: .none,
      message: "Herdr's adapter-managed selector has no setup ownership record"
    )
  }

  func teardownTuicrSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try teardownRegularFile(
      id: Self.tuicrSelectorID,
      target: context.tuicrConfiguration,
      backupURL: context.tuicrSelectorBackup,
      replacementName: context.tuicrSelectorReplacementName,
      label: "tuicr theme selector",
      read: { try readConfiguration($0, id: Self.tuicrSelectorID) },
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func teardownTuicrThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try teardownThemeLink(
      id: Self.tuicrThemeLinkID,
      target: context.tuicrThemeLink,
      destination: context.tuicrThemeDestination,
      label: "tuicr palette",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func teardownTuicrSyntaxLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try teardownThemeLink(
      id: Self.tuicrSyntaxLinkID,
      target: context.tuicrSyntaxLink,
      destination: context.tuicrSyntaxDestination,
      label: "tuicr syntax theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func teardownCodexSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try teardownRegularFile(
      id: Self.codexSelectorID,
      target: context.codexConfiguration,
      backupURL: context.codexSelectorBackup,
      replacementName: context.codexSelectorReplacementName,
      label: "Codex TUI theme selector",
      read: { try readConfiguration($0, id: Self.codexSelectorID) },
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func teardownCodexThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try teardownThemeLink(
      id: Self.codexThemeLinkID,
      target: context.codexThemeLink,
      destination: context.codexThemeDestination,
      label: "Codex TextMate theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func resumePiSelector(
    record: SetupOwnershipRecord,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try validatePiSelectorRecord(record, context: context)
    guard
      try regularFilePathContainsSymlink(
        id: Self.piSelectorID,
        target: context.piConfiguration,
        context: context
      ) == false
    else {
      throw SetupOwnershipError.ownershipDrift(context.piConfiguration)
    }
    let residueExists = try validatePiSelectorReplacementResidue(
      context: context,
      remove: false
    )
    let current = try readConfiguration(context.piConfiguration, id: Self.piSelectorID)
    let state = try ownedPiSelectionState(current, context: context)

    if state == .exact {
      if dryRun, record.phase == .prepared || residueExists {
        return integrationResult(
          id: Self.piSelectorID,
          target: context.piConfiguration,
          status: .planned,
          message: "Would finalize the interrupted Pi selector ownership transaction"
        )
      }
      var mutated = false
      do {
        if residueExists {
          _ = try validatePiSelectorReplacementResidue(context: context, remove: true)
          mutated = true
        }
        if record.phase == .prepared {
          try save(record: record.applied, records: &records, context: context)
          mutated = true
        }
      } catch {
        throw SetupOwnershipTransactionError(
          error,
          integrationID: Self.piSelectorID,
          target: context.piConfiguration
        )
      }
      return integrationResult(
        id: Self.piSelectorID,
        target: context.piConfiguration,
        status: .owned,
        message:
          mutated
          ? "Finalized the Pi selector ownership transaction"
          : "The Pi theme selector is Macarchy-owned and current",
        mutationAttempted: mutated
      )
    }

    let installed = try installedConfiguration(
      id: Self.piSelectorID,
      target: context.piConfiguration,
      original: current,
      transform: {
        try addingJSONSelection(
          to: $0,
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: Self.piSelectorID,
          target: context.piConfiguration
        )
      }
    )
    if dryRun {
      return integrationResult(
        id: Self.piSelectorID,
        target: context.piConfiguration,
        status: .planned,
        message: "Would restore the recorded Pi theme selector"
      )
    }
    do {
      if residueExists {
        _ = try validatePiSelectorReplacementResidue(context: context, remove: true)
      }
      try replaceRegularFile(
        target: context.piConfiguration,
        replacementName: context.piSelectorReplacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: sha256Digest(current),
        data: installed,
        label: "Pi theme selector"
      )
      try faultInjector(.targetWritten)
      try save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(
        error,
        integrationID: Self.piSelectorID,
        target: context.piConfiguration
      )
    }
    return integrationResult(
      id: Self.piSelectorID,
      target: context.piConfiguration,
      status: .owned,
      message: "Restored the recorded Pi theme selector",
      mutationAttempted: true
    )
  }

  func validatePiSelectorRecord(_ record: SetupOwnershipRecord, context: Context) throws {
    guard record.kind == .jsonSelector, record.targetPath == context.piConfiguration.path else {
      throw SetupOwnershipError.invalidManifest("Pi selector target is not allowlisted")
    }
    guard record.backupPath == nil, record.originalDigest == nil, record.linkDestination == nil
    else {
      throw SetupOwnershipError.invalidManifest("Pi selector cannot contain whole-file state")
    }
    guard record.installedDigest == piSelectorContractDigest() else {
      throw SetupOwnershipError.invalidManifest("Pi selector contract digest is invalid")
    }
    guard record.phase == .prepared || record.phase == .applied,
      record.replacementDigest == nil
    else {
      throw SetupOwnershipError.invalidManifest("Pi selector has invalid transaction state")
    }
  }

  func validatePiSelectorReplacementResidue(
    context: Context,
    remove: Bool
  ) throws -> Bool {
    let parent = try openPinnedParent(
      target: context.piConfiguration,
      homeDirectory: context.homeDirectory,
      label: "Pi theme selector"
    )
    defer { Darwin.close(parent) }
    let replacementURL = piSelectorReplacementURL(context: context)
    let descriptor = context.piSelectorReplacementName.withCString {
      Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    if descriptor < 0, errno == ENOENT { return false }
    guard descriptor >= 0 else { throw posixError("open Pi selector residue", replacementURL) }
    defer { Darwin.close(descriptor) }

    let residue = try readPinnedRegularFile(
      descriptor: descriptor,
      url: replacementURL,
      label: "Pi theme selector"
    )
    let current = try readPinnedRegularFile(
      parentDescriptor: parent,
      name: context.piConfiguration.lastPathComponent,
      url: context.piConfiguration,
      label: "Pi theme selector"
    )
    let residueState = try ownedPiSelectionState(residue.data, context: context)
    let currentState = try ownedPiSelectionState(current.data, context: context)
    guard residueState != currentState else {
      throw SetupOwnershipError.ownershipDrift(context.piConfiguration)
    }
    if remove {
      guard
        context.piSelectorReplacementName.withCString({ Darwin.unlinkat(parent, $0, 0) }) == 0
      else {
        throw posixError("remove Pi selector residue", replacementURL)
      }
    }
    return true
  }

  fileprivate func ownedPiSelectionState(
    _ data: Data,
    context: Context
  ) throws -> PiSelectionState {
    do {
      return try piSelectionState(
        data,
        key: PiAdapter.selectionKey,
        value: PiAdapter.themeName,
        id: Self.piSelectorID,
        target: context.piConfiguration
      )
    } catch SetupOwnershipError.conflictingDirective(_, _) {
      throw SetupOwnershipError.ownershipDrift(context.piConfiguration)
    }
  }

  func piSelectorContractDigest() -> String {
    sha256Digest(Data("\"\(PiAdapter.selectionKey)\": \"\(PiAdapter.themeName)\"".utf8))
  }

  func piSelectorReplacementURL(context: Context) -> URL {
    context.piConfiguration.deletingLastPathComponent()
      .appending(path: context.piSelectorReplacementName)
  }

  func jsonSelectionIsExternal(
    _ data: Data,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> Bool {
    try piSelectionState(data, key: key, value: value, id: id, target: target) == .exact
  }

  fileprivate func piSelectionState(
    _ data: Data,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> PiSelectionState {
    let document = try PiSettingsJSONDocument(data: data, id: id, target: target)
    guard let member = document.members.first(where: { $0.key == key }) else {
      return .absent
    }
    guard
      document.bytes[member.keyRange] == Array("\"\(key)\"".utf8)[...],
      document.bytes[member.valueRange] == Array("\"\(value)\"".utf8)[...]
    else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return .exact
  }

  func addingJSONSelection(
    to original: Data,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> Data {
    if try jsonSelectionIsExternal(original, key: key, value: value, id: id, target: target) {
      return original
    }

    let document = try PiSettingsJSONDocument(data: original, id: id, target: target)
    let insertionIndex: Int
    var insertion = Array("\"\(key)\": \"\(value)\"".utf8)
    if let first = document.members.first {
      insertionIndex = first.keyRange.lowerBound
      insertion.append(UInt8(ascii: ","))
      insertion.append(
        contentsOf: document.bytes[(document.openingBraceIndex + 1)..<insertionIndex]
      )
    } else {
      insertionIndex = document.closingBraceIndex
    }

    var candidate = Array(document.bytes[..<insertionIndex])
    candidate.append(contentsOf: insertion)
    candidate.append(contentsOf: document.bytes[insertionIndex...])
    let installed = Data(candidate)
    guard
      try jsonSelectionIsExternal(installed, key: key, value: value, id: id, target: target)
    else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return installed
  }

  func removingJSONSelection(
    from original: Data,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> Data {
    let document = try PiSettingsJSONDocument(data: original, id: id, target: target)
    guard
      let memberIndex = document.members.firstIndex(where: { $0.key == key }),
      try piSelectionState(original, key: key, value: value, id: id, target: target) == .exact
    else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    let member = document.members[memberIndex]
    let removalRange: Range<Int>
    if let separator = member.separatorAfter {
      let next = document.members[memberIndex + 1]
      removalRange = member.keyRange.lowerBound..<next.keyRange.lowerBound
      precondition(separator < removalRange.upperBound)
    } else if memberIndex > 0,
      let separator = document.members[memberIndex - 1].separatorAfter
    {
      removalRange = separator..<member.valueRange.upperBound
    } else {
      removalRange = member.keyRange.lowerBound..<member.valueRange.upperBound
    }

    var candidate = Array(document.bytes[..<removalRange.lowerBound])
    candidate.append(contentsOf: document.bytes[removalRange.upperBound...])
    let installed = Data(candidate)
    guard
      try piSelectionState(installed, key: key, value: value, id: id, target: target) == .absent
    else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return installed
  }

  func tomlRootSelectionIsExternal(
    _ data: Data,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> Bool {
    let configuration = String(decoding: data, as: UTF8.self)
    let document: TOMLTable
    do {
      document = try TOMLTable(source: configuration)
    } catch {
      throw SetupOwnershipError.invalidConfiguration(id, target, String(describing: error))
    }
    let selection = CanonicalTOMLSelector(configuration: configuration, key: key)
    guard document.contains(key: key) else {
      guard selection.values.isEmpty else {
        throw SetupOwnershipError.conflictingDirective(id, target)
      }
      return false
    }
    do {
      guard try document.string(forKey: key) == value else {
        throw SetupOwnershipError.conflictingDirective(id, target)
      }
    } catch let error as SetupOwnershipError {
      throw error
    } catch {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    guard selection.values == ["\"\(value)\""] else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return true
  }

  func addingTOMLRootSelection(
    to original: Data,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> Data {
    if try tomlRootSelectionIsExternal(
      original,
      key: key,
      value: value,
      id: id,
      target: target
    ) {
      return original
    }

    let newline = tomlNewline(in: original)
    let candidate = Data("\(key) = \"\(value)\"\(newline)".utf8) + original
    guard
      try tomlRootSelectionIsExternal(
        candidate,
        key: key,
        value: value,
        id: id,
        target: target
      )
    else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return candidate
  }
}

private enum PiSelectionState: Equatable {
  case absent
  case exact
}

// Pi rewrites this whole file when unrelated settings change. Keep only the root member ranges
// needed for the selector edit; recurse solely to reject duplicate keys and trailing commas before
// JSONSerialization performs the remaining semantic validation.
private struct PiSettingsJSONDocument {
  struct Member {
    let key: String
    let keyRange: Range<Int>
    let valueRange: Range<Int>
    let separatorAfter: Int?
  }

  let bytes: [UInt8]
  let openingBraceIndex: Int
  let closingBraceIndex: Int
  let members: [Member]

  init(data: Data, id: String, target: URL) throws {
    let bytes = Array(data)
    var parser = Parser(bytes: bytes, id: id, target: target)
    let root = try parser.parseRootObject()
    parser.skipWhitespace()
    guard parser.index == bytes.count else {
      throw SetupOwnershipError.invalidConfiguration(id, target, "unexpected bytes after object")
    }

    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw SetupOwnershipError.invalidConfiguration(id, target, String(describing: error))
    }
    guard parsed is [String: Any] else {
      throw SetupOwnershipError.invalidConfiguration(
        id,
        target,
        "top-level JSON value must be an object"
      )
    }

    self.bytes = bytes
    openingBraceIndex = root.openingBraceIndex
    closingBraceIndex = root.closingBraceIndex
    members = root.members
  }

  private struct ObjectResult {
    let openingBraceIndex: Int
    let closingBraceIndex: Int
    let members: [Member]
  }

  private struct Parser {
    let bytes: [UInt8]
    let id: String
    let target: URL
    var index = 0

    mutating func parseRootObject() throws -> ObjectResult {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else {
        throw invalid("top-level JSON value must be an object")
      }
      return try parseObject(captureMembers: true, isRoot: true)
    }

    mutating func parseObject(
      captureMembers: Bool,
      isRoot: Bool
    ) throws -> ObjectResult {
      let openingBraceIndex = index
      index += 1
      skipWhitespace()
      if consume(UInt8(ascii: "}")) {
        return ObjectResult(
          openingBraceIndex: openingBraceIndex,
          closingBraceIndex: index - 1,
          members: []
        )
      }

      var members = [Member]()
      var keys = Set<String>()
      while true {
        let keyStart = index
        let keyEnd = try scanString()
        let key = try decodeKey(keyStart..<keyEnd)
        guard keys.insert(key).inserted else {
          let location = isRoot ? "top-level " : ""
          throw invalid("duplicate \(location)JSON key \"\(key)\"")
        }
        skipWhitespace()
        guard consume(UInt8(ascii: ":")) else {
          throw invalid("object key has no value")
        }
        skipWhitespace()
        let valueRange = try parseValue()
        skipWhitespace()

        let separator: Int?
        if consume(UInt8(ascii: ",")) {
          separator = index - 1
          skipWhitespace()
          guard !peek(UInt8(ascii: "}")) else {
            throw invalid("trailing comma in JSON object")
          }
        } else {
          separator = nil
          guard peek(UInt8(ascii: "}")) else {
            throw invalid("object member is not closed")
          }
        }
        if captureMembers {
          members.append(
            Member(
              key: key,
              keyRange: keyStart..<keyEnd,
              valueRange: valueRange,
              separatorAfter: separator
            )
          )
        }
        if separator == nil {
          let closingBraceIndex = index
          index += 1
          return ObjectResult(
            openingBraceIndex: openingBraceIndex,
            closingBraceIndex: closingBraceIndex,
            members: members
          )
        }
      }
    }

    mutating func parseArray() throws {
      index += 1
      skipWhitespace()
      if consume(UInt8(ascii: "]")) { return }
      while true {
        _ = try parseValue()
        skipWhitespace()
        if consume(UInt8(ascii: ",")) {
          skipWhitespace()
          guard !peek(UInt8(ascii: "]")) else {
            throw invalid("trailing comma in JSON array")
          }
          continue
        }
        guard consume(UInt8(ascii: "]")) else {
          throw invalid("JSON array is not closed")
        }
        return
      }
    }

    mutating func parseValue() throws -> Range<Int> {
      let start = index
      guard index < bytes.count else { throw invalid("object value is empty") }
      switch bytes[index] {
      case UInt8(ascii: "\""):
        _ = try scanString()
      case UInt8(ascii: "{"):
        _ = try parseObject(captureMembers: false, isRoot: false)
      case UInt8(ascii: "["):
        try parseArray()
      default:
        while index < bytes.count,
          !Self.isWhitespace(bytes[index]),
          ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[index])
        {
          index += 1
        }
      }
      guard index > start else { throw invalid("object value is empty") }
      return start..<index
    }

    mutating func scanString() throws -> Int {
      guard consume(UInt8(ascii: "\"")) else {
        throw invalid("object key is not a string")
      }
      var escaped = false
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if escaped {
          escaped = false
        } else if byte == UInt8(ascii: "\\") {
          escaped = true
        } else if byte == UInt8(ascii: "\"") {
          return index
        }
      }
      throw invalid("string is not closed")
    }

    func decodeKey(_ range: Range<Int>) throws -> String {
      do {
        guard
          let decoded = try JSONSerialization.jsonObject(
            with: Data(bytes[range]),
            options: .fragmentsAllowed
          ) as? String
        else {
          throw invalid("object key is not a string")
        }
        return decoded
      } catch let error as SetupOwnershipError {
        throw error
      } catch {
        throw invalid(String(describing: error))
      }
    }

    mutating func skipWhitespace() {
      while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
    }

    func peek(_ byte: UInt8) -> Bool {
      index < bytes.count && bytes[index] == byte
    }

    mutating func consume(_ byte: UInt8) -> Bool {
      guard peek(byte) else { return false }
      index += 1
      return true
    }

    func invalid(_ reason: String) -> SetupOwnershipError {
      .invalidConfiguration(id, target, reason)
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
      byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
        || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }
  }
}
