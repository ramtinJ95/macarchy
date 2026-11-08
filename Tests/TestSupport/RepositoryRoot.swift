import Foundation

/// The checkout root, for tests that read the repository's themes, resources and fixtures.
package let repositoryRoot = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
