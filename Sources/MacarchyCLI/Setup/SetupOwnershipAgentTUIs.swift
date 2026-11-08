import Darwin
import Foundation
import ThemeCore

extension SetupOwnershipManager {
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

    try attributingFailure(to: Self.piSelectorID, target: context.piConfiguration) {
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
    }
    return integrationResult(
      id: Self.piSelectorID,
      target: context.piConfiguration,
      status: .removed,
      message: "Removed only the recorded Pi theme selector ownership",
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
    try withReplacementResidue(
      target: context.piConfiguration,
      replacementName: context.piSelectorReplacementName,
      homeDirectory: context.homeDirectory,
      label: "Pi theme selector",
      residueDescription: "Pi selector residue",
      remove: remove
    ) { (residue: Data, current: Data) throws -> Void in
      let residueState = try ownedPiSelectionState(residue, context: context)
      let currentState = try ownedPiSelectionState(current, context: context)
      guard residueState != currentState else {
        throw SetupOwnershipError.ownershipDrift(context.piConfiguration)
      }
    } != nil
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
    try piSelectionState(
      StrictJSONObjectDocument(data: data, id: id, target: target),
      key: key, value: value, id: id, target: target)
  }

  fileprivate func piSelectionState(
    _ document: StrictJSONObjectDocument,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> PiSelectionState {
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
    let document = try StrictJSONObjectDocument(data: original, id: id, target: target)
    if try piSelectionState(document, key: key, value: value, id: id, target: target) == .exact {
      return original
    }

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
    let document = try StrictJSONObjectDocument(data: original, id: id, target: target)
    guard
      let memberIndex = document.members.firstIndex(where: { $0.key == key }),
      try piSelectionState(document, key: key, value: value, id: id, target: target) == .exact
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
}

private enum PiSelectionState: Equatable {
  case absent
  case exact
}
