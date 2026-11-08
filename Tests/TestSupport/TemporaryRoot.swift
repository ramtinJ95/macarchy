import Foundation

/// Creates a new, uniquely named directory `<prefix>-<UUID>` under `parent`.
package func makeTemporaryDirectory(
  named prefix: String,
  under parent: URL = FileManager.default.temporaryDirectory
) throws -> URL {
  let root = parent.appending(
    path: "\(prefix)-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

/// Runs `operation` with a new temporary directory and removes it afterwards, including
/// any directories the test left read-only.
package func withTemporaryRoot(
  named prefix: String,
  _ operation: (URL) throws -> Void
) throws {
  let root = try makeTemporaryDirectory(named: prefix)
  defer { removeTemporaryRoot(root) }
  try operation(root)
}

/// Runs `operation` with a new temporary directory and removes it afterwards, including
/// any directories the test left read-only.
package func withTemporaryRoot(
  named prefix: String,
  _ operation: (URL) async throws -> Void
) async throws {
  let root = try makeTemporaryDirectory(named: prefix)
  defer { removeTemporaryRoot(root) }
  try await operation(root)
}

/// Best-effort removal of a test's temporary tree.
///
/// Tests deliberately publish read-only directories, which would make a plain removal fail
/// silently and leak the tree. Every directory, `root` included, is first made owner-writable,
/// deepest first. File modes are left alone: removing a file needs only its parent directory
/// to be writable.
package func removeTemporaryRoot(_ root: URL) {
  if let enumerator = FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: [.isDirectoryKey]
  ) {
    var directories = [root]
    for case let item as URL in enumerator
    where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      directories.append(item)
    }
    for directory in directories.reversed() {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }
  try? FileManager.default.removeItem(at: root)
}
