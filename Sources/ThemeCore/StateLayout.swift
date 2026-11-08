import Foundation

/// Where Macarchy keeps its state. `--state-root` overrides the root; everything else is relative
/// to whichever root is in use.
package enum StateLayout {
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
}
