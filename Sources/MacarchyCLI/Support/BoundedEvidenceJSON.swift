import Darwin
import Foundation
import ThemeCore

func writeBoundedEvidenceJSON<Value: Encodable, WriteError: Error>(
  _ value: Value,
  to destination: URL,
  temporaryPrefix: String,
  tooLargeError: @autoclosure () -> WriteError,
  replaceError: (Int32) -> WriteError
) throws {
  let directory = destination.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let data = try encodeBoundedEvidenceJSON(value)
  guard data.count <= BoundedRegularFile.maximumSize else {
    throw tooLargeError()
  }

  let temporary = directory.appending(path: "\(temporaryPrefix)\(UUID().uuidString).tmp")
  defer { try? FileManager.default.removeItem(at: temporary) }
  try data.write(to: temporary, options: .withoutOverwriting)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600],
    ofItemAtPath: temporary.path
  )
  if rename(temporary.path, destination.path) != 0 {
    throw replaceError(errno)
  }
}

/// The exact bytes `writeBoundedEvidenceJSON` stores; readers use it to check a file is canonical.
func encodeBoundedEvidenceJSON<Value: Encodable>(_ value: Value) throws -> Data {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}
