import Foundation

/// The text a test meant to rewrite is absent, so the rewrite would silently do nothing.
package struct MissingReplacementTarget: Error, CustomStringConvertible {
  package let target: String

  package var description: String {
    "expected text to rewrite is absent: \(target)"
  }
}

extension String {
  /// Throws unless `target` occurs in this text.
  package func requireContaining(_ target: String) throws {
    guard contains(target) else { throw MissingReplacementTarget(target: target) }
  }

  /// Replaces every occurrence of `target`, throwing when there is none.
  ///
  /// Tests that execute generated scripts swap real host tools for fakes this way. If a
  /// production literal changes, a plain `replacingOccurrences` would leave the real tool in
  /// place and the test would run it on the machine; this fails the test instead.
  package func replacingRequired(_ target: String, with replacement: String) throws -> String {
    try requireContaining(target)
    return replacingOccurrences(of: target, with: replacement)
  }
}
