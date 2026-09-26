import Darwin
import Foundation

/// st_dev identifies a mount only for its current lifetime. Persist volume UUID + inode;
/// keep device/inode comparisons when binding observations within one operation.
enum RetainedOriginalIdentity {
  static func volumeUUID(at url: URL, matching metadata: stat? = nil) throws -> String {
    // O_SYMLINK opens the link itself, including a moved, dangling relative link.
    let descriptor = open(url.path, O_RDONLY | O_SYMLINK | O_CLOEXEC)
    guard descriptor >= 0 else { throw failure(url) }
    defer { close(descriptor) }
    var observed = stat()
    var filesystem = statfs()
    guard fstat(descriptor, &observed) == 0, fstatfs(descriptor, &filesystem) == 0 else {
      throw failure(url)
    }
    if let metadata {
      guard observed.st_dev == metadata.st_dev, observed.st_ino == metadata.st_ino,
        observed.st_mode == metadata.st_mode
      else { throw failure(url) }
    }
    let mountPath = withUnsafePointer(to: &filesystem.f_mntonname) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    let mount = URL(filePath: mountPath)
    var mountMetadata = stat()
    guard stat(mount.path, &mountMetadata) == 0, mountMetadata.st_dev == observed.st_dev,
      let value = try mount.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
      let uuid = UUID(uuidString: value)
    else { throw failure(url) }
    return uuid.uuidString
  }

  static func matches(at url: URL, metadata: stat, volumeUUID: String?, device: UInt64?) throws
    -> Bool
  {
    if let volumeUUID {
      return try self.volumeUUID(at: url, matching: metadata) == volumeUUID
    }
    // Legacy receipts remain strict; only the reviewed migration may bind a UUID.
    return UInt64(metadata.st_dev) == device
  }

  private static func failure(_ url: URL) -> CocoaError {
    CocoaError(
      .fileReadUnknown,
      userInfo: [
        NSLocalizedDescriptionKey:
          "cannot establish persistent volume identity for \(url.path)"
      ])
  }
}
