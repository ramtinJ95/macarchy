import Darwin
import Foundation
import ThemeCore

struct EnvironmentSpicetifyOwnership: Codable, Equatable, Sendable {
  static let maximumSelectorSize = 32_768

  let path: String
  let originalTheme: String?
  let originalColorScheme: String?

  enum CodingKeys: String, CodingKey {
    case path
    case originalTheme = "original_theme"
    case originalColorScheme = "original_color_scheme"
  }

  init(
    path: String,
    originalSelection: SpicetifyAdapter.ConfigurationSelection
  ) {
    self.path = path
    originalTheme = originalSelection.rawTheme
    originalColorScheme = originalSelection.rawColorScheme
  }

  var hasValidShape: Bool {
    guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { return false }
    return (try? originalSelection(target: URL(filePath: path))) != nil
  }

  func originalSelection(
    target: URL
  ) throws -> SpicetifyAdapter.ConfigurationSelection {
    let values = [originalTheme, originalColorScheme].compactMap { $0 }
    guard
      values.allSatisfy({
        !$0.isEmpty
          && $0.utf8.count <= Self.maximumSelectorSize
          && !$0.contains("\n")
          && !$0.contains("\r")
          && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
      })
    else {
      throw EnvironmentLifecycleError.blocked(
        "Spicetify selector restoration evidence is invalid"
      )
    }
    var configuration = "[Setting]\n"
    if let originalTheme {
      configuration += "current_theme = \(originalTheme)\n"
    }
    if let originalColorScheme {
      configuration += "color_scheme = \(originalColorScheme)\n"
    }
    let selection = try SetupOwnershipManager().spicetifySelection(
      Data(configuration.utf8),
      target: target
    )
    guard selection.rawTheme == originalTheme,
      selection.rawColorScheme == originalColorScheme
    else {
      throw EnvironmentLifecycleError.blocked(
        "Spicetify selector restoration evidence does not round-trip"
      )
    }
    return selection
  }
}

struct EnvironmentSpicetifyFileTransaction: Sendable {
  private enum ExpectedState {
    case original(EnvironmentSpicetifyOwnership)
    case managed
  }

  let homeDirectory: URL

  func preflight(_ ownership: EnvironmentSpicetifyOwnership) throws {
    let url = URL(filePath: ownership.path)
    guard try matches(try read(url), .managed, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    replacementName: String
  ) throws {
    guard let ownership = old?.spicetify ?? new?.spicetify else { return }
    if let oldValue = old?.spicetify, let newValue = new?.spicetify, oldValue != newValue {
      throw EnvironmentLifecycleError.blocked("Spicetify selector ownership changed unexpectedly")
    }
    let url = URL(filePath: ownership.path)
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    let source: ExpectedState = old?.spicetify == nil ? .original(ownership) : .managed
    let target: ExpectedState = new?.spicetify == nil ? .original(ownership) : .managed
    var current = try read(url)
    if let residueData = try read(residue) {
      if try matches(current, target, ownership: ownership, at: url),
        try matches(residueData, source, ownership: ownership, at: residue)
      {
        try remove(residue)
        return
      }
      if try matches(current, source, ownership: ownership, at: url),
        try matches(residueData, target, ownership: ownership, at: residue)
      {
        try remove(residue)
      } else {
        throw EnvironmentLifecycleError.drift("Spicetify replacement residue")
      }
      current = try read(url)
    }
    if try matches(current, target, ownership: ownership, at: url) { return }
    guard let current,
      try matches(current, source, ownership: ownership, at: url)
    else { throw EnvironmentLifecycleError.drift(url.path) }

    let manager = SetupOwnershipManager()
    let updated: Data
    switch target {
    case .managed:
      updated = try manager.addingSpicetifySelectors(to: current, target: url)
    case .original(let original):
      updated = try manager.restoringSpicetifySelectors(
        in: current,
        from: try original.originalSelection(target: url),
        target: url
      )
    }
    try replace(updated, current: current, at: url, replacementName: replacementName)
    guard try matches(try read(url), target, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  private func matches(
    _ data: Data?,
    _ state: ExpectedState,
    ownership: EnvironmentSpicetifyOwnership,
    at url: URL
  ) throws -> Bool {
    guard let data else { return false }
    let manager = SetupOwnershipManager()
    switch state {
    case .managed:
      return try manager.spicetifySelectorsAreExternal(data, target: url)
    case .original(let original):
      let current = try manager.spicetifySelection(data, target: url)
      let expected = try original.originalSelection(target: url)
      return manager.spicetifySelectionsEqual(current, expected)
    }
  }

  private func read(_ url: URL) throws -> Data? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return nil }
      throw EnvironmentLifecycleError.system("inspect Spicetify configuration", url, errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
      throw EnvironmentLifecycleError.blocked(
        "Spicetify configuration is not an ordinary file: \(url.path)"
      )
    }
    return try BoundedRegularFile.read(
      at: url,
      maximumSize: SetupOwnershipManager.maximumConfigurationSize
    ).data
  }

  private func replace(
    _ data: Data,
    current: Data,
    at url: URL,
    replacementName: String
  ) throws {
    guard data != current else { return }
    do {
      try SetupOwnershipManager().replaceRegularFile(
        target: url,
        replacementName: replacementName,
        homeDirectory: homeDirectory,
        expectedDigest: sha256Digest(current),
        data: data,
        label: "Spicetify current_theme and color_scheme selectors"
      )
    } catch {
      throw EnvironmentLifecycleError.blocked("cannot replace Spicetify selectors: \(error)")
    }
  }

  private func remove(_ url: URL) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let removed = url.lastPathComponent.withCString { Darwin.unlinkat(parent, $0, 0) }
    guard removed == 0 || errno == ENOENT else {
      throw EnvironmentLifecycleError.system("remove Spicetify transaction residue", url, errno)
    }
    if removed == 0, fsync(parent) != 0 {
      throw EnvironmentLifecycleError.system("sync Spicetify transaction residue", url, errno)
    }
  }
}
