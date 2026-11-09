import Foundation

/// Where Macarchy keeps its state. `--state-root` overrides the root; everything else is relative
/// to whichever root is in use. The static members name the defaults; an instance names the paths
/// that more than one module spells under a given root. Each path keeps the exact spelling and
/// directory hint its callers compare URLs with.
package struct StateLayout: Sendable {
  /// The default state root, relative to the user's home directory.
  package static let defaultRootRelativePath = ".config/macarchy"

  /// The default state root under `home`. Callers keep the directory hint they compare URLs with.
  package static func defaultRoot(
    in home: URL, directoryHint: URL.DirectoryHint = .inferFromPath
  ) -> URL {
    home.appending(path: defaultRootRelativePath, directoryHint: directoryHint)
  }

  /// The default portable profile. It stays under the default root even with `--state-root`.
  package static func defaultProfile(in home: URL) -> URL {
    defaultRoot(in: home).appending(path: "profile.toml")
  }

  /// The default machine-local profile overlay, beside the default profile.
  package static func defaultMachineOverlay(in home: URL) -> URL {
    defaultRoot(in: home).appending(path: "machine.toml")
  }

  /// The default `--state-root` value: the current user's default state root as a path string.
  package static var defaultRootPath: String {
    defaultRoot(in: FileManager.default.homeDirectoryForCurrentUser, directoryHint: .isDirectory)
      .path
  }

  /// The relative `current` destination of a generation, the same in every generation store.
  package static func generationPath(_ generationID: String) -> String {
    "generations/\(generationID)"
  }

  /// The inverse of `generationPath`: the identity a `current` destination selects, or nil
  /// unless the destination is exactly `generations/<id>` with an identity the store accepts.
  package static func generationID(
    fromPath destination: String, isGenerationID: (String) -> Bool
  ) -> String? {
    let prefix = generationPath("")
    guard destination.hasPrefix(prefix) else { return nil }
    let generationID = String(destination.dropFirst(prefix.count))
    guard !generationID.contains("/"), isGenerationID(generationID) else { return nil }
    return generationID
  }

  // Provider generation stores, relative to the state root.
  package var macOSAccentRecord: URL { root.appending(path: "state/macos-look/accent.json") }

  package static let environmentDirectory = "environment"
  package static let keybindingsDirectory = "keybindings"
  package static let yabaiDirectory = "desktop/yabai"
  package static let sketchyBarDirectory = "desktop/sketchybar"

  /// A path inside the active environment generation, relative to the state root.
  package static func environmentCurrentPath(_ path: String) -> String {
    "\(environmentDirectory)/current/\(path)"
  }

  package let root: URL

  package init(root: URL) {
    self.root = root
  }

  /// The theme `current` pointer, a relative symlink to `generations/<id>`.
  package var currentTheme: URL {
    root.appending(path: "current")
  }

  /// A rendered artifact of the active theme generation, reached through `current`.
  package func currentThemeArtifact(_ path: String) -> URL {
    root.appending(path: "current/\(path)")
  }

  /// The theme reconciliation status written after each activation.
  package var reconciliationStatus: URL {
    root.appending(path: "state/reconciliation.json")
  }

  /// The user theme library that `theme install` publishes into.
  package var userThemes: URL {
    root.appending(path: "themes", directoryHint: .isDirectory)
  }

  package var environment: URL {
    root.appending(path: Self.environmentDirectory, directoryHint: .isDirectory)
  }

  /// A path inside the active environment generation, reached through `environment/current`.
  package func environmentArtifact(_ path: String) -> URL {
    root.appending(path: Self.environmentCurrentPath(path))
  }

  /// A path inside one environment generation.
  package func environmentGenerationArtifact(_ generationID: String, _ path: String) -> URL {
    root.appending(
      path: "\(Self.environmentDirectory)/\(Self.generationPath(generationID))/\(path)")
  }

  package var keybindings: URL {
    root.appending(path: Self.keybindingsDirectory, directoryHint: .isDirectory)
  }

  /// The keybinding apply transaction record.
  package var keybindingTransaction: URL {
    root.appending(path: "\(Self.keybindingsDirectory)/\(SkhdLayout.transactionFileName)")
  }

  package var currentSkhdrc: URL {
    root.appending(path: "\(Self.keybindingsDirectory)/current/\(SkhdLayout.configurationName)")
  }

  package var yabai: URL {
    root.appending(path: Self.yabaiDirectory, directoryHint: .isDirectory)
  }

  package var sketchyBar: URL {
    root.appending(path: Self.sketchyBarDirectory, directoryHint: .isDirectory)
  }
}
