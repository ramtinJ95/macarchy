import Darwin
import Foundation

/// Stable adapter state uses real pinned parents, single-linked regular leaves and atomic
/// replacement. These files are rebuildable projections, never generation authority.
package enum StableAdapterBridge {
  package static var statePaths: [String] {
    AlacrittyAdapter.statePaths
  }

  enum Failure: Error, CustomStringConvertible {
    case unsafe(String)
    var description: String {
      switch self {
      case .unsafe(let path):
        "Adapter bridge must be an ordinary file with nonsymlinked parents: \(path)"
      }
    }
  }

  static func publish(_ data: Data, root: URL, path: String, mode: mode_t = 0o644) throws {
    guard statePaths.contains(path) else { throw Failure.unsafe(path) }
    let url = root.appending(path: path)
    try withParent(root: root) { parent in
      _ = try isAbsent(parent: parent, url: url)
      try PinnedFilesystem.replaceRegularFileAtomically(
        parentDescriptor: parent, name: url.lastPathComponent, url: url, data: data, mode: mode)
    }
  }

  package static func restore(at url: URL, data: Data?, mode: UInt16?) throws {
    guard statePaths.contains(where: { url.path.hasSuffix("/" + $0) }) else {
      throw Failure.unsafe(url.path)
    }
    if data == nil {
      guard
        let parent = try PinnedFilesystem.openDirectoryIfPresent(
          at: url.deletingLastPathComponent())
      else { return }
      defer { close(parent) }
      if try isAbsent(parent: parent, url: url) { return }
      guard unlinkat(parent, url.lastPathComponent, 0) == 0 else {
        throw PinnedFilesystemError(operation: "remove adapter bridge", url: url, code: errno)
      }
    } else if let data {
      let root = url.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      try withParent(root: root) { parent in
        _ = try isAbsent(parent: parent, url: url)
        try PinnedFilesystem.replaceRegularFileAtomically(
          parentDescriptor: parent,
          name: url.lastPathComponent, url: url, data: data, mode: mode_t(mode ?? 0o644))
      }
    }
  }

  static func isAbsent(parent: Int32, url: URL) throws -> Bool {
    var metadata = stat()
    let result = fstatat(parent, url.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW)
    let absent = result != 0 && errno == ENOENT
    guard absent || (result == 0 && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_nlink == 1)
    else {
      throw Failure.unsafe(url.path)
    }
    return absent
  }

  static func withParent<T>(root: URL, body: (Int32) throws -> T) throws -> T {
    let rootFD = try PinnedFilesystem.openDirectory(at: root)
    defer { close(rootFD) }
    let state = root.appending(path: "state")
    let stateFD = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: rootFD, name: "state", url: state)
    defer { close(stateFD) }
    let directory = state.appending(path: "adapters")
    let parent = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: stateFD, name: "adapters", url: directory)
    defer { close(parent) }
    return try body(parent)
  }
}
