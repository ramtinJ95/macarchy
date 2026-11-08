import Foundation

/// Pretty-printed, key-sorted, newline-terminated JSON for persisted documents.
func prettyJSONDocument<Value: Encodable>(_ value: Value) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  var data = try encoder.encode(value)
  data.append(0x0a)
  return data
}
