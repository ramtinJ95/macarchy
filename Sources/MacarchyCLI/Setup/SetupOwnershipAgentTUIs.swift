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

// Capture root member ranges for Pi's byte-preserving selector edit. The complete recursive parse
// also rejects duplicate keys and trailing commas before JSONSerialization performs semantic
// validation, so other strict setup JSON inputs can reuse the same syntax boundary.
struct StrictJSONObjectDocument {
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
