import Foundation

/// The checkout root, for tests that read the repository's themes, resources and fixtures.
package let repositoryRoot = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

/// The UTF-8 text of `Tests/Fixtures/<path>`.
package func fixtureContents(_ path: String) throws -> String {
  try String(
    contentsOf: repositoryRoot.appending(path: "Tests/Fixtures/\(path)"),
    encoding: .utf8
  )
}
