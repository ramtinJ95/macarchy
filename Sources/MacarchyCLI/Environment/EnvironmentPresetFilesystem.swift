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

/// A preset's ownership of selectors inside one provider-writable configuration file
/// (ADR-0043). Each preset keeps its own document rules, labels and messages; the shared
/// transaction only sequences residue settlement, the write and its verification.
protocol EnvironmentPresetFileOwnership: Equatable, Sendable {
  static var filesystem: EnvironmentPresetFilesystem { get }
  /// Names the preset in residue drift errors.
  static var driftLabel: String { get }
  static var ownershipChangedMessage: String { get }
  static var replacementLabel: String { get }
  static var replacementFailureLabel: String? { get }
  static func owned(by ownership: EnvironmentOwnership?) -> Self?
  /// The file contents with the managed selectors applied to `current`, or to the preset's
  /// empty document when the file is absent.
  static func managed(from current: Data?, at url: URL) throws -> Data
  static func matchesManaged(_ data: Data, at url: URL) throws -> Bool

  var path: String { get }
  /// The original selectors restored in `current`, or nil when the file should be removed.
  func restored(in current: Data, at url: URL) throws -> Data?
  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool
}

struct EnvironmentPresetFileTransaction<Ownership: EnvironmentPresetFileOwnership>: Sendable {
  private enum ExpectedState {
    case original(Ownership)
    case managed
  }

  let homeDirectory: URL

  func preflight(_ ownership: Ownership) throws {
    let url = URL(filePath: ownership.path)
    guard try matches(try Ownership.filesystem.read(url), .managed, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    replacementName: String
  ) throws {
    let oldOwnership = Ownership.owned(by: old)
    let newOwnership = Ownership.owned(by: new)
    guard let ownership = oldOwnership ?? newOwnership else { return }
    if let oldOwnership, let newOwnership, oldOwnership != newOwnership {
      throw EnvironmentLifecycleError.blocked(Ownership.ownershipChangedMessage)
    }
    let filesystem = Ownership.filesystem
    let url = URL(filePath: ownership.path)
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    let source: ExpectedState = oldOwnership == nil ? .original(ownership) : .managed
    let target: ExpectedState = newOwnership == nil ? .original(ownership) : .managed
    guard
      case .pending(let current) = try filesystem.pendingTransition(
        at: url, residue: residue, from: source, to: target, driftLabel: Ownership.driftLabel,
        matches: { try matches($0, $1, at: $2) })
    else { return }

    switch target {
    case .managed:
      let updated = try Ownership.managed(from: current, at: url)
      if let current {
        try replace(updated, current: current, at: url, replacementName: replacementName)
      } else {
        try filesystem.create(updated, at: url, replacementName: replacementName)
      }
    case .original(let original):
      guard let current else { return }
      if let restored = try original.restored(in: current, at: url) {
        try replace(restored, current: current, at: url, replacementName: replacementName)
      } else {
        try filesystem.claimAndRemove(at: url, replacementName: replacementName, expected: current)
      }
    }
    guard try matches(try filesystem.read(url), target, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  private func matches(_ data: Data?, _ state: ExpectedState, at url: URL) throws -> Bool {
    switch state {
    case .managed:
      guard let data else { return false }
      return try Ownership.matchesManaged(data, at: url)
    case .original(let original):
      return try original.matchesOriginal(data, at: url)
    }
  }

  private func replace(_ data: Data, current: Data, at url: URL, replacementName: String) throws {
    try Ownership.filesystem.replace(
      data, current: current, at: url, replacementName: replacementName,
      homeDirectory: homeDirectory, label: Ownership.replacementLabel,
      failureLabel: Ownership.replacementFailureLabel
    )
  }
}
