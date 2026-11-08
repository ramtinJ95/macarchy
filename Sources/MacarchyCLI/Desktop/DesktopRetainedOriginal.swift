import Darwin
import Foundation
import ThemeCore

/// How a retained directory-symlink original's source directory is read during
/// authentication. The released yabai and SketchyBar transactions read it differently.
enum DesktopRetainedSourceRead: Sendable {
  /// `FileManager` inventory and a path read of the entry (yabai).
  case path
  /// A pinned directory, an inventory capped at 1,024 names and a pinned read of the entry
  /// (SketchyBar).
  case pinned
}

extension DesktopAdoptionEvidence {
  /// Verifies that the original Macarchy moved to `retainedPath` is still this adopted entry:
  /// persistent volume identity, inode, permissions and a single link, then its bytes, or its
  /// symlink target and the bytes behind it. `provider` and `entryName` spell the messages.
  func authenticateRetained(
    at retainedPath: String,
    provider: String,
    entryName: String,
    sourceRead: DesktopRetainedSourceRead,
    invalidState: (String) -> any Error
  ) throws {
    let retained = URL(filePath: retainedPath)
    var metadata = stat()
    guard
      lstat(retained.path, &metadata) == 0,
      try RetainedOriginalIdentity.matches(
        at: retained, metadata: metadata,
        volumeUUID: volumeUUID, device: device),
      UInt64(metadata.st_ino) == inode,
      Int(metadata.st_mode & 0o777) == permissions,
      metadata.st_nlink == 1
    else {
      throw invalidState("retained \(provider) original identity has drifted")
    }
    switch kind {
    case .regularFile:
      guard
        metadata.st_mode & S_IFMT == S_IFREG,
        sha256Digest(try BoundedRegularFile.read(at: retained).data) == contentDigest
      else {
        throw invalidState("retained \(entryName) bytes have drifted")
      }
    case .entrySymlink, .directorySymlink:
      guard
        metadata.st_mode & S_IFMT == S_IFLNK,
        SymbolicLink.target(of: retained) == linkTarget,
        let target = linkTarget
      else {
        throw invalidState("retained \(provider) symlink has drifted")
      }
      let source = SymbolicLink.resolve(target, at: URL(filePath: publicPath))
      if kind == .directorySymlink {
        let inventoryDrifted = "retained \(provider) directory source inventory drifted"
        let digest: String
        switch sourceRead {
        case .path:
          let observed = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
          guard observed == inventory else { throw invalidState(inventoryDrifted) }
          digest = sha256Digest(
            try BoundedRegularFile.read(at: source.appending(path: entryName)).data
          )
        case .pinned:
          let descriptor = try PinnedFilesystem.openDirectory(at: source)
          defer { Darwin.close(descriptor) }
          let observed = try PinnedFilesystem.directoryEntries(
            descriptor: descriptor,
            url: source,
            limit: 1_024
          )
          guard !observed.truncated, observed.entries == inventory else {
            throw invalidState(inventoryDrifted)
          }
          digest = sha256Digest(
            try PinnedFilesystem.readRegularFile(
              parentDescriptor: descriptor,
              name: entryName,
              url: source.appending(path: entryName)
            ).data
          )
        }
        guard digest == contentDigest else {
          throw invalidState("retained \(provider) directory source bytes drifted")
        }
      } else {
        let digest = sha256Digest(try BoundedRegularFile.read(at: source).data)
        guard digest == contentDigest else {
          throw invalidState("retained \(entryName) symlink source bytes drifted")
        }
      }
    case .absent:
      throw invalidState("absent \(provider) state cannot have a retained original")
    }
  }
}
