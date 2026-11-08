import Darwin
import Foundation
import ThemeCore

/// Standard application paths remain user-owned; this validates only their declared seams.
enum EnvironmentStandardNativeConfiguration {
  static func validate(
    _ provider: EnvironmentNativeSeed.Provider, homeDirectory: URL, stateRoot: URL,
    sourceURL: URL? = nil, ownsKittyThemeInclude: Bool = true
  ) throws {
    let source = sourceURL ?? provider.standardURL(homeDirectory: homeDirectory)
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
      guard
        EnvironmentNativeSource.targetIsAllowed(
          source.path, homeDirectory: homeDirectory, stateRoot: stateRoot,
          userOwnedPublicEntry: provider.entryID)
      else {
        throw EnvironmentLifecycleError.blocked(
          "The standard \(provider.rawValue) configuration must not resolve into Macarchy state or another provider entry"
        )
      }
      let resolved = source.resolvingSymlinksInPath()
      let data = try BoundedRegularFile.read(at: resolved).data
      guard access(resolved.path, R_OK | W_OK) == 0,
        let text = String(data: data, encoding: .utf8)
      else {
        throw EnvironmentLifecycleError.blocked(
          "The standard \(provider.rawValue) configuration must be writable UTF-8")
      }
      if provider == .kitty && ownsKittyThemeInclude {
        let lines = text.split(whereSeparator: \.isNewline)
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let include = KittyAdapter.includeDirective(stateRoot: stateRoot)
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
    case .zsh: path = ConsumerHomePath.shellConfiguration
    case .kitty: path = ConsumerHomePath.kittyConfiguration
    case .atuin: path = ConsumerHomePath.atuinConfiguration
    case .starship: path = ConsumerHomePath.starshipConfiguration
    case .neovim: path = ConsumerHomePath.neovimDirectory
    }
    return homeDirectory.appending(path: path).standardizedFileURL
  }
}
