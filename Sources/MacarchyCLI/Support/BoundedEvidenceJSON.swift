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
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(value)
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
