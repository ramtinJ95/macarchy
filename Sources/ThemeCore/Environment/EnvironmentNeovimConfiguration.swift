import Foundation

struct EnvironmentNeovimConfiguration {
  private static let neovimStateRootPlaceholder = "__MACARCHY_STATE_ROOT_LUA__"
  // Opaque digests recognize only the approved ADR-0027 personal seam without
  // shipping those legacy bytes as package defaults.
  private static let legacyNeovimThemeArtifactDigests = [
    "neovim/colors/macarchy-imported.lua":
      "sha256:745b13db920f25e2bd60465601db2ee42c859824a5612727ecfbcd783b31b0d3",
    "neovim/lua/config/macarchy-theme.lua":
      "sha256:23935f4b2d4e660d96a6f6b37feba3ba1b85c06fc4bfe3f6f0cbbf9e48bd6d1f",
    "neovim/lua/plugins/colorscheme.lua":
      "sha256:4d9099e154b158a8d06e1970be3b2dffc77dcceb4608e4b7c37049619e0ed443",
  ]

  func compose(
    resourcesRoot: URL,
    configurationDirectoryURL: URL?,
    stateRoot: URL
  ) throws -> (source: URL, artifacts: [EnvironmentConfigurationArtifact]) {
    let packaged = resourcesRoot.appending(
      path: "neovim/default",
      directoryHint: .isDirectory
    )
    let source = configurationDirectoryURL ?? packaged
    let artifacts = try readNeovimConfiguration(
      at: source,
      themeRoot: resourcesRoot.appending(
        path: "neovim/theme",
        directoryHint: .isDirectory
      ),
      stateRoot: stateRoot
    )
    return (source, artifacts)
  }

  private func readNeovimConfiguration(
    at source: URL,
    themeRoot: URL,
    stateRoot: URL
  ) throws -> [EnvironmentConfigurationArtifact] {
    let packagedTheme = try EnvironmentNativeTreeReader().read(
      at: themeRoot,
      targetRoot: "neovim",
      allowLegacyThemeLink: false
    )
    let theme = try renderNeovimTheme(
      packagedTheme.artifacts,
      source: themeRoot,
      stateRoot: stateRoot
    )
    let reserved = Dictionary(uniqueKeysWithValues: theme.map { ($0.path, $0) })
    let nativeTree = try EnvironmentNativeTreeReader().read(
      at: source,
      targetRoot: "neovim",
      allowLegacyThemeLink: true
    )
    var configuration = nativeTree.artifacts
    let reservedArtifacts = configuration.filter { reserved[$0.path] != nil }
    let legacyPaths = Set(Self.legacyNeovimThemeArtifactDigests.keys)
    let exactLegacyPaths = Set(
      reservedArtifacts.lazy.filter(recognizedLegacyNeovimThemeArtifact).map(\.path)
    )
    let hasReservedSeam = nativeTree.hasLegacyThemeLink || !reservedArtifacts.isEmpty
    let hasCompleteLegacySeam =
      nativeTree.hasLegacyThemeLink
      && reservedArtifacts.count == legacyPaths.count
      && exactLegacyPaths == legacyPaths
    if hasReservedSeam && !hasCompleteLegacySeam {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Neovim configuration has a partial or conflicting reserved theme seam"
      )
    }
    if hasCompleteLegacySeam {
      configuration.removeAll { legacyPaths.contains($0.path) }
    }
    guard configuration.contains(where: { $0.path == "neovim/init.lua" }) else {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Neovim configuration must contain init.lua"
      )
    }
    guard configuration.contains(where: { $0.path == "neovim/lazy-lock.json" }) else {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Neovim configuration must provide lazy-lock.json"
      )
    }
    var effective = configuration + theme
    try pinNeovimThemePlugins(
      in: &effective,
      source: source,
      packagedLock: themeRoot.deletingLastPathComponent()
        .appending(path: "default/lazy-lock.json")
    )
    return effective
  }

  private func renderNeovimTheme(
    _ artifacts: [EnvironmentConfigurationArtifact],
    source: URL,
    stateRoot: URL
  ) throws -> [EnvironmentConfigurationArtifact] {
    let renderedPaths = [
      "neovim/lua/config/macarchy-theme.lua",
      "neovim/lua/macarchy/current.lua",
    ]
    let replacement = NeovimAdapter.luaStringLiteral(stateRoot.standardizedFileURL.path)
    var rendered = artifacts
    for path in renderedPaths {
      guard let index = rendered.firstIndex(where: { $0.path == path }),
        let text = rendered[index].textContents
      else {
        throw EnvironmentConfigurationError.invalid(
          source,
          "packaged Neovim theme is missing renderable artifact \(path)"
        )
      }
      let pieces = text.components(separatedBy: Self.neovimStateRootPlaceholder)
      guard pieces.count == 2 else {
        throw EnvironmentConfigurationError.invalid(
          source,
          "packaged Neovim theme artifact \(path) must contain exactly one state-root placeholder"
        )
      }
      rendered[index] = EnvironmentConfigurationArtifact(
        path: path,
        contents: pieces.joined(separator: replacement)
      )
    }
    if let unresolved = rendered.first(where: {
      $0.textContents?.contains(Self.neovimStateRootPlaceholder) == true
    }) {
      throw EnvironmentConfigurationError.invalid(
        source,
        "packaged Neovim theme has an unexpected state-root placeholder in \(unresolved.path)"
      )
    }
    return rendered
  }

  private func pinNeovimThemePlugins(
    in artifacts: inout [EnvironmentConfigurationArtifact],
    source: URL,
    packagedLock: URL
  ) throws {
    guard let index = artifacts.firstIndex(where: { $0.path == "neovim/lazy-lock.json" })
    else { return }
    let packaged = try readJSONDictionary(
      try BoundedRegularFile.read(at: packagedLock).data,
      source: packagedLock
    )
    var selected = try readJSONDictionary(artifacts[index].data, source: source)
    for plugin in ["aether", "catppuccin", "kanagawa.nvim", "tokyonight.nvim"] {
      guard let pin = packaged[plugin] else {
        throw EnvironmentConfigurationError.invalid(
          packagedLock,
          "packaged Neovim lock is missing \(plugin)"
        )
      }
      selected[plugin] = pin
    }
    let data =
      try JSONSerialization.data(
        withJSONObject: selected,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ) + Data([0x0A])
    artifacts[index] = EnvironmentConfigurationArtifact(
      path: "neovim/lazy-lock.json",
      data: data
    )
  }

  private func readJSONDictionary(_ data: Data, source: URL) throws -> [String: Any] {
    do {
      guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        throw EnvironmentConfigurationError.invalid(
          source,
          "Neovim lazy-lock.json must contain an object"
        )
      }
      return value
    } catch let error as EnvironmentConfigurationError {
      throw error
    } catch {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Neovim lazy-lock.json is invalid JSON"
      )
    }
  }

  private func recognizedLegacyNeovimThemeArtifact(
    _ artifact: EnvironmentConfigurationArtifact
  ) -> Bool {
    Self.legacyNeovimThemeArtifactDigests[artifact.path] == artifact.digest
  }
}
