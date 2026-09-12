import Darwin
import Foundation
import ThemeCore

/// Standard application paths remain user-owned; this validates only their declared seams.
enum EnvironmentStandardNativeConfiguration {
  static func validate(
    _ provider: EnvironmentNativeSeed.Provider, homeDirectory: URL, stateRoot: URL,
    sourceURL: URL? = nil
  ) throws {
    let source = sourceURL ?? provider.standardURL(homeDirectory: homeDirectory)
    guard
      EnvironmentNativeSource.targetIsAllowed(
        source.path, homeDirectory: homeDirectory, stateRoot: stateRoot,
        userOwnedPublicEntry: provider.entryID)
    else {
      throw EnvironmentLifecycleError.blocked(
        "The standard \(provider.rawValue) configuration must not resolve into Macarchy state or another provider entry"
      )
    }
    switch provider {
    case .atuin, .starship:
      try EnvironmentNativeFileMigration(
        provider: provider == .atuin ? .atuin : .starship,
        homeDirectory: homeDirectory, stateRoot: stateRoot
      ).validateNativeFile(at: source, userOwnedPublicEntry: true)
    case .neovim:
      try EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .validateNativeTree(at: source, userOwnedPublicEntry: true)
    case .zsh, .kitty:
      let resolved = source.resolvingSymlinksInPath()
      let data = try BoundedRegularFile.read(at: resolved).data
      guard access(resolved.path, R_OK | W_OK) == 0,
        let text = String(data: data, encoding: .utf8)
      else {
        throw EnvironmentLifecycleError.blocked(
          "The standard \(provider.rawValue) configuration must be writable UTF-8")
      }
      if provider == .kitty {
        let lines = text.split(whereSeparator: \.isNewline)
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let include = "include " + stateRoot.appending(path: KittyAdapter.bridgePath).path
        guard lines.last == include, lines.filter({ $0 == include }).count == 1 else {
          throw EnvironmentLifecycleError.drift(
            "Kitty's standard configuration must end with exactly one '\(include)' directive")
        }
      }
    }
  }
}

extension EnvironmentNativeSeed.Provider {
  func standardURL(homeDirectory: URL) -> URL {
    let path: String
    switch self {
    case .zsh: path = ".zshrc"
    case .kitty: path = ".config/kitty/kitty.conf"
    case .atuin: path = ".config/atuin/config.toml"
    case .starship: path = ".config/starship.toml"
    case .neovim: path = ".config/nvim"
    }
    return homeDirectory.appending(path: path).standardizedFileURL
  }
}
