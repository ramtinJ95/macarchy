import Foundation

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
