import Foundation

/// A settings file in JSON with comments, as Zed and the VS Code family write them: `//` and
/// `/* */` comments and trailing commas are allowed. Edits replace, insert or remove one
/// top-level member and leave every other byte, comments included, as it was.
struct JSONCObjectDocument {
  struct Member {
    let key: String
    let keyRange: Range<Int>
    let valueRange: Range<Int>
    /// The comma after the value, if any; the last member may have one too.
    let separatorAfter: Int?
  }

  let bytes: [UInt8]
  let openingBraceIndex: Int
  let closingBraceIndex: Int
  let members: [Member]

  /// Parses `data`, rejecting anything that is not one object, duplicate top-level keys, and
  /// values JSON would not accept once comments and trailing commas are taken out.
  init(data: Data, id: String, target: URL) throws {
    let bytes = Array(data)
    var parser = Parser(bytes: bytes, id: id, target: target)
    try parser.skipInsignificant()
    guard parser.peek(UInt8(ascii: "{")) else {
      throw parser.invalid("top-level JSON value must be an object")
    }
    let root = try parser.parseObject(captureMembers: true)
    try parser.skipInsignificant()
    guard parser.index == bytes.count else {
      throw parser.invalid("unexpected bytes after object")
    }
    do {
      _ = try JSONSerialization.jsonObject(with: Data(parser.strictBytes()))
    } catch {
      throw SetupOwnershipError.invalidConfiguration(id, target, String(describing: error))
    }
    self.bytes = bytes
    openingBraceIndex = root.openingBraceIndex
    closingBraceIndex = root.closingBraceIndex
    members = root.members
  }

  func member(_ key: String) -> Member? {
    members.first { $0.key == key }
  }

  /// The bytes of `key`'s member from its key through its value, as an owner records them.
  func memberBytes(_ key: String) -> [UInt8]? {
    member(key).map { Array(bytes[$0.keyRange.lowerBound..<$0.valueRange.upperBound]) }
  }

  /// The document with `key`'s whole member (key through value) replaced by `memberBytes`.
  func replacingMember(_ key: String, with memberBytes: [UInt8]) -> Data? {
    guard let member = member(key) else { return nil }
    var result = Data(bytes[..<member.keyRange.lowerBound])
    result.append(contentsOf: memberBytes)
    result.append(contentsOf: bytes[member.valueRange.upperBound...])
    return result
  }

  /// The document with `memberBytes` added as the first member, on its own line indented like
  /// the member that follows it.
  func insertingFirstMember(_ memberBytes: [UInt8]) -> Data {
    guard let first = members.first else {
      var result = Data(bytes[..<closingBraceIndex])
      result.append(contentsOf: memberBytes)
      result.append(contentsOf: bytes[closingBraceIndex...])
      return result
    }
    let lineStart =
      bytes[..<first.keyRange.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }
    let indent = lineStart.map { bytes[$0..<first.keyRange.lowerBound] }
    let separator: [UInt8]
    if let indent, indent.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
      separator = Array(",\n".utf8) + indent
    } else {
      separator = Array(", ".utf8)
    }
    var result = Data(bytes[..<first.keyRange.lowerBound])
    result.append(contentsOf: memberBytes)
    result.append(contentsOf: separator)
    result.append(contentsOf: bytes[first.keyRange.lowerBound...])
    return result
  }

  /// The document without `key`'s member and the separator that joined it to its neighbour.
  /// Bytes between the member and its neighbour are removed with it only when they are
  /// whitespace, as an inserted member leaves them; otherwise only the member and its comma go.
  func removingMember(_ key: String) -> Data? {
    guard let index = members.firstIndex(where: { $0.key == key }) else { return nil }
    let member = members[index]
    let memberRange = member.keyRange.lowerBound..<member.valueRange.upperBound
    var removals = [memberRange]
    if let separator = member.separatorAfter, index + 1 < members.count {
      let next = members[index + 1].keyRange.lowerBound
      if bytes[member.valueRange.upperBound..<separator].allSatisfy(Parser.isWhitespace),
        bytes[(separator + 1)..<next].allSatisfy(Parser.isWhitespace)
      {
        removals = [member.keyRange.lowerBound..<next]
      } else {
        removals.append(separator..<(separator + 1))
      }
    } else if index > 0, let separator = members[index - 1].separatorAfter {
      let trailing = member.separatorAfter ?? member.valueRange.upperBound
      if bytes[(separator + 1)..<member.keyRange.lowerBound].allSatisfy(Parser.isWhitespace),
        bytes[member.valueRange.upperBound..<trailing].allSatisfy(Parser.isWhitespace)
      {
        removals = [separator..<(member.separatorAfter.map { $0 + 1 } ?? trailing)]
      } else {
        removals.append(separator..<(separator + 1))
        if let comma = member.separatorAfter { removals.append(comma..<(comma + 1)) }
      }
    } else {
      if let comma = member.separatorAfter { removals.append(comma..<(comma + 1)) }
    }
    var result = bytes
    for range in removals.sorted(by: { $0.lowerBound > $1.lowerBound }) {
      result.removeSubrange(range)
    }
    return Data(result)
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
    /// Byte ranges that are comments or trailing commas, blanked out for strict validation.
    var ignored: [Range<Int>] = []

    mutating func parseObject(captureMembers: Bool) throws -> ObjectResult {
      let openingBraceIndex = index
      index += 1
      var members = [Member]()
      var keys = Set<String>()
      while true {
        try skipInsignificant()
        if consume(UInt8(ascii: "}")) {
          return ObjectResult(
            openingBraceIndex: openingBraceIndex, closingBraceIndex: index - 1, members: members)
        }
        let keyStart = index
        let keyEnd = try scanString(what: "object key")
        let key = try decodeKey(keyStart..<keyEnd)
        if captureMembers, !keys.insert(key).inserted {
          throw invalid("duplicate top-level JSON key \"\(key)\"")
        }
        try skipInsignificant()
        guard consume(UInt8(ascii: ":")) else { throw invalid("object key has no value") }
        try skipInsignificant()
        let valueRange = try parseValue()
        try skipInsignificant()
        var separator: Int?
        if consume(UInt8(ascii: ",")) {
          separator = index - 1
          try skipInsignificant()
          if peek(UInt8(ascii: "}")) { ignored.append(separator!..<(separator! + 1)) }
        } else if !peek(UInt8(ascii: "}")) {
          throw invalid("object member is not closed")
        }
        if captureMembers {
          members.append(
            Member(
              key: key, keyRange: keyStart..<keyEnd, valueRange: valueRange,
              separatorAfter: separator))
        }
      }
    }

    mutating func parseArray() throws {
      index += 1
      while true {
        try skipInsignificant()
        if consume(UInt8(ascii: "]")) { return }
        _ = try parseValue()
        try skipInsignificant()
        if consume(UInt8(ascii: ",")) {
          let comma = index - 1
          try skipInsignificant()
          if peek(UInt8(ascii: "]")) { ignored.append(comma..<(comma + 1)) }
        } else if !peek(UInt8(ascii: "]")) {
          throw invalid("JSON array is not closed")
        }
      }
    }

    mutating func parseValue() throws -> Range<Int> {
      let start = index
      guard index < bytes.count else { throw invalid("object value is empty") }
      switch bytes[index] {
      case UInt8(ascii: "\""): _ = try scanString(what: "string")
      case UInt8(ascii: "{"): _ = try parseObject(captureMembers: false)
      case UInt8(ascii: "["): try parseArray()
      default:
        while index < bytes.count, !Self.isWhitespace(bytes[index]),
          !Array(",}]/".utf8).contains(bytes[index])
        {
          index += 1
        }
      }
      guard index > start else { throw invalid("object value is empty") }
      return start..<index
    }

    mutating func scanString(what: String) throws -> Int {
      guard consume(UInt8(ascii: "\"")) else { throw invalid("\(what) is not a string") }
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
      guard
        let key = try? JSONSerialization.jsonObject(
          with: Data(bytes[range]), options: .fragmentsAllowed) as? String
      else { throw invalid("object key is not a valid string") }
      return key
    }

    /// Skips whitespace and comments, recording the comments.
    mutating func skipInsignificant() throws {
      while index < bytes.count {
        if Self.isWhitespace(bytes[index]) {
          index += 1
        } else if bytes[index] == UInt8(ascii: "/"), index + 1 < bytes.count,
          bytes[index + 1] == UInt8(ascii: "/")
        {
          let start = index
          while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
          ignored.append(start..<index)
        } else if bytes[index] == UInt8(ascii: "/"), index + 1 < bytes.count,
          bytes[index + 1] == UInt8(ascii: "*")
        {
          let start = index
          index += 2
          while index + 1 < bytes.count,
            !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/"))
          {
            index += 1
          }
          guard index + 1 < bytes.count else { throw invalid("block comment is not closed") }
          index += 2
          ignored.append(start..<index)
        } else {
          return
        }
      }
    }

    /// The document with comments and trailing commas replaced by spaces.
    func strictBytes() -> [UInt8] {
      var strict = bytes
      for range in ignored {
        for position in range where strict[position] != UInt8(ascii: "\n") {
          strict[position] = UInt8(ascii: " ")
        }
      }
      return strict
    }

    func peek(_ byte: UInt8) -> Bool { index < bytes.count && bytes[index] == byte }

    mutating func consume(_ byte: UInt8) -> Bool {
      guard peek(byte) else { return false }
      index += 1
      return true
    }

    func invalid(_ reason: String) -> SetupOwnershipError {
      .invalidConfiguration(id, target, reason)
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
      byte == 0x20 || byte == 0x09 || byte == 0x0d || byte == 0x0a
    }
  }
}
