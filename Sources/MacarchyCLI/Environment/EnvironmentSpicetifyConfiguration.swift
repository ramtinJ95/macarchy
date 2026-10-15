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
  private static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Spicetify configuration",
    residueLabel: "Spicetify transaction residue",
    nonRegularMessage: "Spicetify configuration is not an ordinary file"
  )

  private enum ExpectedState {
    case original(EnvironmentSpicetifyOwnership)
    case managed
  }

  let homeDirectory: URL

  func preflight(_ ownership: EnvironmentSpicetifyOwnership) throws {
    let url = URL(filePath: ownership.path)
    guard try matches(try Self.filesystem.read(url), .managed, ownership: ownership, at: url) else {
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
    guard
      case .pending(let current) = try Self.filesystem.pendingTransition(
        at: url, residue: residue, from: source, to: target, driftLabel: "Spicetify",
        matches: { try matches($0, $1, ownership: ownership, at: $2) })
    else { return }
    // matches() rejects missing data, so a pending configuration exists.
    guard let current else { throw EnvironmentLifecycleError.drift(url.path) }

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
    guard try matches(try Self.filesystem.read(url), target, ownership: ownership, at: url) else {
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

  private func replace(_ data: Data, current: Data, at url: URL, replacementName: String) throws {
    try Self.filesystem.replace(
      data, current: current, at: url, replacementName: replacementName,
      homeDirectory: homeDirectory, label: "Spicetify current_theme and color_scheme selectors",
      failureLabel: "Spicetify selectors"
    )
  }
}
