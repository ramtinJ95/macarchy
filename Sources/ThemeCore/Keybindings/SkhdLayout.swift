import Foundation

/// Where the skhd provider lives for one home and state root: skhd's native entry, the claim and
/// residue names Macarchy's ownership transaction uses beside it, the regular-file backup, the
/// setup ownership manifest and the keybinding state files. Every skhd path and on-disk name is
/// spelled here once; each URL keeps the exact spelling and directory hint its callers compare.
package struct SkhdLayout: Sendable {
  /// skhd's configuration file: the entry inside `~/.config/skhd`, the only file a
  /// directory-level adoption may hold, and each generation's rendered artifact.
  package static let configurationName = "skhdrc"
  /// skhd's configuration directory inside `~/.config`.
  package static let directoryName = "skhd"
  /// skhd's fallback configuration in the home directory, read when the preferred entry is absent.
  package static let fallbackName = ".skhdrc"
  /// The managed entry's link text, relative to `~/.config/skhd` under the canonical state root.
  package static let managedTarget = "../macarchy/keybindings/current/skhdrc"
  /// The regular-file backup's name inside the setup backup directory.
  package static let backupName = "keybindings-skhdrc"
  /// The setup backup directory below the state root, one component at a time.
  package static let backupDirectoryComponents = ["state", "setup", "backups"]
  /// The setup ownership manifest's name inside the setup directory.
  package static let ownershipManifestName = "ownership.json"
  /// Where restoring a legacy clean install publishes the managed link before renaming it.
  package static let legacyRestorationName = ".skhdrc.macarchy-legacy-restoration"
  /// The keybinding apply transaction record inside the keybinding state directory.
  package static let transactionFileName = "transaction.json"
  /// The skhd lifecycle success evidence inside the keybinding state directory.
  package static let lifecycleFileName = "lifecycle.json"

  /// Which item an ownership transaction claims: the `skhdrc` leaf inside `~/.config/skhd`, or
  /// the whole `skhd` directory inside `~/.config` when an adopted directory symlink is replaced.
  package enum Level: Sendable {
    case leaf
    case directory
  }

  package let home: URL
  package let stateRoot: URL
  package let configurationDirectory: URL
  package let directory: URL
  package let entry: URL

  /// The layout under the canonical per-user state root.
  package init(home: URL) {
    self.init(
      home: home,
      stateRoot: StateLayout.defaultRoot(in: home.standardizedFileURL, directoryHint: .isDirectory)
    )
  }

  package init(home: URL, stateRoot: URL) {
    self.home = home.standardizedFileURL
    self.stateRoot = stateRoot.standardizedFileURL
    configurationDirectory = self.home.appending(path: ".config", directoryHint: .isDirectory)
    directory = configurationDirectory.appending(
      path: Self.directoryName, directoryHint: .isDirectory)
    entry = directory.appending(path: Self.configurationName)
  }

  package var fallback: URL {
    home.appending(path: Self.fallbackName)
  }

  /// The entry's link text: relative under the canonical state root, otherwise the absolute
  /// path of the selected state root's current `skhdrc`.
  package var expectedTarget: String {
    let canonical = StateLayout.defaultRoot(in: home, directoryHint: .isDirectory)
      .standardizedFileURL
    return stateRoot == canonical
      ? Self.managedTarget : StateLayout(root: stateRoot).currentSkhdrc.path
  }

  /// The setup directory that holds the ownership manifest and the backup directory.
  package var setupDirectory: URL {
    stateRoot.appending(path: "state/setup", directoryHint: .isDirectory)
  }

  package var ownershipManifest: URL {
    setupDirectory.appending(path: Self.ownershipManifestName)
  }

  /// The regular-file adoption backup.
  package var backup: URL {
    stateRoot.appending(
      path: (Self.backupDirectoryComponents + [Self.backupName]).joined(separator: "/"))
  }

  /// The directory that holds the claimed item at `level`.
  package func parent(_ level: Level) -> URL {
    switch level {
    case .leaf: directory
    case .directory: configurationDirectory
    }
  }

  /// The live name of the claimed item at `level` inside its parent.
  package static func liveName(_ level: Level) -> String {
    switch level {
    case .leaf: configurationName
    case .directory: directoryName
    }
  }

  package func live(_ level: Level) -> URL {
    switch level {
    case .leaf: entry
    case .directory: directory
    }
  }

  /// The claim name without its nonce. Records that predate nonces never used it, so it must
  /// stay absent.
  package static func claimPrefix(_ level: Level) -> String {
    switch level {
    case .leaf: ".skhdrc.macarchy-keybindings"
    case .directory: ".skhd.macarchy-keybindings"
    }
  }

  /// The claim beside the live item at `level` for one ownership nonce.
  package static func claimName(_ level: Level, nonce: String) -> String {
    "\(claimPrefix(level))-\(nonce)"
  }

  package func claim(_ level: Level, nonce: String) -> URL {
    parent(level).appending(path: Self.claimName(level, nonce: nonce))
  }
}
