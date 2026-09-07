import Darwin
import Foundation
import ThemeCore

/// Ordinary-file inspection and authenticated mutation shared by Pi, tuicr, and Codex.
struct EnvironmentPresetFilesystem: Sendable {
  let configurationLabel: String
  let residueLabel: String
  let nonRegularMessage: String

  func read(_ url: URL) throws -> Data? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return nil }
      throw EnvironmentLifecycleError.system("inspect \(configurationLabel)", url, errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
      throw EnvironmentLifecycleError.blocked("\(nonRegularMessage): \(url.path)")
    }
    return try BoundedRegularFile.read(at: url, maximumSize: 1_048_576).data
  }

  func utf8(_ data: Data, at url: URL) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked("\(configurationLabel) is not UTF-8: \(url.path)")
    }
    return text
  }

  func replace(
    _ data: Data, current: Data, at url: URL, replacementName: String,
    homeDirectory: URL, label: String, failureLabel: String? = nil
  ) throws {
    guard data != current else { return }
    do {
      try SetupOwnershipManager().replaceRegularFile(
        target: url,
        replacementName: replacementName,
        homeDirectory: homeDirectory,
        expectedDigest: sha256Digest(current),
        data: data,
        label: label
      )
    } catch {
      throw EnvironmentLifecycleError.blocked("cannot replace \(failureLabel ?? label): \(error)")
    }
  }

  func create(_ data: Data, at url: URL, replacementName: String) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let temporary = url.deletingLastPathComponent().appending(path: replacementName)
    try PinnedFilesystem.writeNewRegularFile(
      parentDescriptor: parent,
      name: replacementName,
      url: temporary,
      data: data,
      mode: 0o600
    )
    // Deliberately installed only after the write, chmod, and file sync succeed.
    var removeTemporary = true
    defer {
      if removeTemporary { _ = replacementName.withCString { Darwin.unlinkat(parent, $0, 0) } }
    }
    let published = replacementName.withCString { source in
      url.lastPathComponent.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard published == 0 else {
      throw EnvironmentLifecycleError.system("publish \(configurationLabel)", url, errno)
    }
    removeTemporary = false
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync \(configurationLabel) parent", url, errno)
    }
  }

  func claimAndRemove(at url: URL, replacementName: String, expected: Data) throws {
    try claimAndRemove(at: url, replacementName: replacementName) { residue in
      guard try read(residue) == expected else {
        throw EnvironmentLifecycleError.drift("claimed \(configurationLabel)")
      }
    }
  }

  func claimAndRemove(
    at url: URL,
    replacementName: String,
    validate: (URL) throws -> Void
  ) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let claimed = url.lastPathComponent.withCString { source in
      replacementName.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard claimed == 0 else {
      throw EnvironmentLifecycleError.system("claim \(configurationLabel)", url, errno)
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync claimed \(configurationLabel)", url, errno)
    }
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    // Keep the original parent pinned through provider-owned path validation and removal.
    try validate(residue)
    try remove(residue)
  }

  func remove(_ url: URL) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let removed = url.lastPathComponent.withCString { Darwin.unlinkat(parent, $0, 0) }
    guard removed == 0 || errno == ENOENT else {
      throw EnvironmentLifecycleError.system("remove \(residueLabel)", url, errno)
    }
    if removed == 0, fsync(parent) != 0 {
      throw EnvironmentLifecycleError.system("sync \(residueLabel)", url, errno)
    }
  }
}
