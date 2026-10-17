import Darwin
import Foundation
import ThemeCore

/// Ordinary-file inspection and authenticated mutation shared by the presets' configuration files.
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
    return try BoundedRegularFile.read(at: url).data
  }

  /// Settles the replacement residue an interrupted transition may have left, then reports whether
  /// the file at `fileURL` (default `url`) still has to move from `source` to `target`.
  /// `matches` checks contents against a state, reporting them under the given URL: `url` for the
  /// file and the residue's own URL.
  func pendingTransition<State>(
    at url: URL,
    readingFrom fileURL: URL? = nil,
    residue: URL,
    from source: State,
    to target: State,
    driftLabel: String,
    matches: (Data?, State, URL) throws -> Bool
  ) throws -> EnvironmentPresetTransition {
    let fileURL = fileURL ?? url
    var current = try read(fileURL)
    if let residueData = try read(residue) {
      if try matches(current, target, url), try matches(residueData, source, residue) {
        try remove(residue)
        return .reached
      }
      if try matches(current, source, url), try matches(residueData, target, residue) {
        try remove(residue)
      } else {
        throw EnvironmentLifecycleError.drift("\(driftLabel) replacement residue")
      }
      current = try read(fileURL)
    }
    if try matches(current, target, url) { return .reached }
    guard try matches(current, source, url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
    return .pending(current: current)
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
    do {
      try PinnedFilesystem.publishNewRegularFile(
        data, as: url.lastPathComponent, through: replacementName, parentDescriptor: parent,
        url: url, mode: 0o600)
    } catch let failure as PinnedFilesystem.PublicationError {
      let operation =
        failure.step == .publish
        ? "publish \(configurationLabel)" : "sync \(configurationLabel) parent"
      throw EnvironmentLifecycleError.system(operation, url, failure.code)
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
    guard PinnedFilesystem.renameExclusively(url.lastPathComponent, to: replacementName, in: parent)
    else {
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
    if let failure = PinnedStateFile.remove(
      url.lastPathComponent, parentDescriptor: parent, syncWhenAbsent: false)
    {
      let operation = failure.step == .unlink ? "remove \(residueLabel)" : "sync \(residueLabel)"
      throw EnvironmentLifecycleError.system(operation, url, failure.code)
    }
  }
}

enum EnvironmentPresetTransition {
  /// The file already holds the target state.
  case reached
  /// The file holds the source state and must be transitioned from `current`.
  case pending(current: Data?)
}
