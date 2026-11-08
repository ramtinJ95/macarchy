import Foundation

/// The JSON document parsed, but its top level is not an object.
package struct JSONObjectExpected: Error, CustomStringConvertible {
  package var description: String { "JSON document is not an object" }
}

/// Parses `data` as a JSON document whose top level must be an object.
package func jsonObject(_ data: Data) throws -> [String: Any] {
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw JSONObjectExpected()
  }
  return object
}

/// Parses command output as a JSON document whose top level must be an object.
package func jsonObject(_ output: String) throws -> [String: Any] {
  try jsonObject(Data(output.utf8))
}
