import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// Simulate persisted evidence from another boot without replacing the retained filesystem object.
func ownershipFixtureReplacing<T: Codable>(_ value: T, _ fields: [String: Any]) throws -> T {
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  for (key, replacement) in fields { object[key] = replacement }
  return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
