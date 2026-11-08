import Darwin
import Foundation

/// Durable JSON state-file I/O shared by Macarchy's stores (ADR-0297). Stores keep their own
/// paths, record types, encoding, size caps, decoding strictness and error text; the
/// durability style is the choice of function.
package enum StateFile {
  package enum RemovalStep {
    case unlink
    case sync
  }

  /// Pinned and synced: sorted, pretty-printed JSON written exclusively to a temporary sibling
  /// at 0600, fsynced, renamed over `name` and the parent synced.
  package static func write(
    _ value: some Encodable,
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      data: try encoder.encode(value),
      mode: 0o600
    )
  }

  /// Unlinks `name` and syncs the parent; an absent file is not an error. `syncWhenAbsent`
  /// keeps a store's released choice to sync the parent even when nothing was removed.
  /// Returns the failed step and its errno.
  package static func remove(
    _ name: String,
    parentDescriptor: Int32,
    syncWhenAbsent: Bool
  ) -> (step: RemovalStep, code: Int32)? {
    let removed = name.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) } == 0
    guard removed || errno == ENOENT else { return (.unlink, errno) }
    guard removed || syncWhenAbsent else { return nil }
    return fsync(parentDescriptor) == 0 ? nil : (.sync, errno)
  }

  /// Path-based and unsynced: creates the parent directory, writes the encoded bytes to
  /// `temporaryName` beside `destination` with `temporaryWriteOptions`, sets 0600 and renames
  /// it over `destination`. Neither the file nor the parent is fsynced. `beforeRename` runs
  /// after the temporary file is complete; a leftover temporary file is removed.
  package static func replaceByRename<WriteError: Error>(
    at destination: URL,
    temporaryName: String,
    temporaryWriteOptions: Data.WritingOptions,
    encode: () throws -> Data,
    tooLargeError: @autoclosure () -> WriteError,
    beforeRename: () throws -> Void = {},
    renameError: (Int32) -> WriteError
  ) throws {
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encode()
    guard data.count <= BoundedRegularFile.maximumSize else {
      throw tooLargeError()
    }

    let temporary = directory.appending(path: temporaryName)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: temporaryWriteOptions)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: temporary.path
    )
    try beforeRename()
    if Darwin.rename(temporary.path, destination.path) != 0 {
      throw renameError(errno)
    }
  }
}
