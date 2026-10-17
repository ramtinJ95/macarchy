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

typealias EnvironmentSpicetifyFileTransaction = EnvironmentPresetFileTransaction<
  EnvironmentSpicetifyOwnership
>

extension EnvironmentSpicetifyOwnership: EnvironmentPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Spicetify configuration",
    residueLabel: "Spicetify transaction residue",
    nonRegularMessage: "Spicetify configuration is not an ordinary file"
  )
  static let driftLabel = "Spicetify"
  static let ownershipChangedMessage = "Spicetify selector ownership changed unexpectedly"
  static let replacementLabel = "Spicetify current_theme and color_scheme selectors"
  static let replacementFailureLabel: String? = "Spicetify selectors"

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.spicetify }

  /// Spicetify owns selectors only in an existing configuration, so the file is never created.
  static func managed(from current: Data?, at url: URL) throws -> Data {
    guard let current else { throw EnvironmentLifecycleError.drift(url.path) }
    return try SetupOwnershipManager().addingSpicetifySelectors(to: current, target: url)
  }

  static func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    try SetupOwnershipManager().spicetifySelectorsAreExternal(data, target: url)
  }

  /// Restoration always keeps the file.
  func restored(in current: Data, at url: URL) throws -> Data? {
    try SetupOwnershipManager().restoringSpicetifySelectors(
      in: current, from: try originalSelection(target: url), target: url)
  }

  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return false }
    let manager = SetupOwnershipManager()
    let current = try manager.spicetifySelection(data, target: url)
    return manager.spicetifySelectionsEqual(current, try originalSelection(target: url))
  }
}
