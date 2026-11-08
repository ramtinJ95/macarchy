import Foundation
import ThemeCore

func writeBoundedEvidenceJSON<Value: Encodable, WriteError: Error>(
  _ value: Value,
  to destination: URL,
  temporaryPrefix: String,
  tooLargeError: @autoclosure () -> WriteError,
  replaceError: (Int32) -> WriteError
) throws {
  try StateFile.replaceByRename(
    at: destination,
    temporaryName: "\(temporaryPrefix)\(UUID().uuidString).tmp",
    temporaryWriteOptions: .withoutOverwriting,
    encode: { try encodeBoundedEvidenceJSON(value) },
    tooLargeError: tooLargeError(),
    renameError: replaceError
  )
}

/// The exact bytes `writeBoundedEvidenceJSON` stores; readers use it to check a file is canonical.
func encodeBoundedEvidenceJSON<Value: Encodable>(_ value: Value) throws -> Data {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}

/// Decodes closed-schema evidence in the form `writeBoundedEvidenceJSON` stores. The record must
/// re-encode to the same JSON object, so an unknown or missing field at any level throws
/// `mismatch`. `validateBeforeComparison` lets a store report its own checks first.
func decodeCanonicalEvidenceJSON<Value: Codable, MismatchError: Error>(
  _ type: Value.Type, from data: Data, mismatch: @autoclosure () -> MismatchError,
  validateBeforeComparison: (Value) throws -> Void = { _ in }
) throws -> Value {
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  let value = try decoder.decode(type, from: data)
  try validateBeforeComparison(value)
  guard
    try JSONSerialization.jsonObject(with: data) as? NSDictionary
      == JSONSerialization.jsonObject(with: encodeBoundedEvidenceJSON(value)) as? NSDictionary
  else { throw mismatch() }
  return value
}
