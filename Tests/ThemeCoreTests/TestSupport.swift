import Foundation
import Testing

let repositoryRoot = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

func withTemporaryRoot(
  named name: String = "macarchy-theme-core-tests",
  _ operation: (URL) throws -> Void
) throws {
  let root = try temporaryRoot(named: name)
  defer { removeTemporaryRoot(root) }
  try operation(root)
}

func withTemporaryRoot(
  named name: String = "macarchy-theme-core-tests",
  _ operation: (URL) async throws -> Void
) async throws {
  let root = try temporaryRoot(named: name)
  defer { removeTemporaryRoot(root) }
  try await operation(root)
}

func makeWritableForRemoval(_ root: URL) {
  guard
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
  else { return }
  var directories = [root]
  for case let item as URL in enumerator {
    if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      directories.append(item)
    }
  }
  for directory in directories.reversed() {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
  }
}

private func temporaryRoot(named name: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "\(name)-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func removeTemporaryRoot(_ root: URL) {
  makeWritableForRemoval(root)
  try? FileManager.default.removeItem(at: root)
}

func jsonObject(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
