import Darwin
import Foundation
import ThemeCore

/// The durable JSON state-file discipline shared by ownership stores (ADR-0297): sorted,
/// pretty-printed JSON published atomically at 0600 with the parent synced. Callers keep their
/// own directory layout, size caps, decoding strictness and error text.
enum PinnedStateFile {
  enum RemovalStep {
    case unlink
    case sync
  }

  static func write(
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
  static func remove(
    _ name: String,
    parentDescriptor: Int32,
    syncWhenAbsent: Bool
  ) -> (step: RemovalStep, code: Int32)? {
    let removed = name.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) } == 0
    guard removed || errno == ENOENT else { return (.unlink, errno) }
    guard removed || syncWhenAbsent else { return nil }
    return fsync(parentDescriptor) == 0 ? nil : (.sync, errno)
  }
}
