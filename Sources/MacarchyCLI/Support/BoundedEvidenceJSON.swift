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
