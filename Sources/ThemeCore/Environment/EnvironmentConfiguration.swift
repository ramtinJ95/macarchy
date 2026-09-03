import Darwin
import Foundation
import TOMLDecoder

package struct EnvironmentConfigurationArtifact: Equatable, Sendable {
  package let path: String
  package let data: Data
  package let digest: String

  package init(path: String, contents: String) {
    self.init(path: path, data: Data(contents.utf8))
  }

  package init(path: String, data: Data) {
    self.path = path
    self.data = data
    digest = sha256Digest(data)
  }

  package var textContents: String? {
    String(data: data, encoding: .utf8)
  }
}

package struct EnvironmentComposition: Equatable, Sendable {
  package let profile: EnvironmentProfile
  package let artifacts: [EnvironmentConfigurationArtifact]
  package let kittyOverrideURL: URL?
  package let zshHookURL: URL?
  package let zshHookDigest: String?
  package let starshipBehaviorURL: URL?
  package let atuinConfigurationURL: URL?
  package let neovimConfigurationURL: URL?
  package let renderedDigest: String
  package let inputDigest: String
}

package enum EnvironmentConfigurationError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL, String)
  case invalid(URL, String)
  case unsafeOverride(URL, String)

  package var description: String {
    switch self {
    case .cannotRead(let source, let reason):
      source.path + ": cannot read environment configuration: " + reason
    case .invalid(let source, let reason):
      source.path + ": invalid environment configuration: " + reason
    case .unsafeOverride(let source, let reason):
      source.path + ": unsafe Kitty override: " + reason
    }
  }

  package var sourceURL: URL {
    switch self {
    case .cannotRead(let source, _), .invalid(let source, _), .unsafeOverride(let source, _):
      source
    }
  }
}

package struct EnvironmentConfigurationComposer: Sendable {
  private struct NeovimNativeTree {
    var artifacts: [EnvironmentConfigurationArtifact]
    var hasLegacyThemeLink: Bool
  }

  private static let maximumOverrideEntries = 128
  private static let maximumOverrideBytes = 4 * 1_048_576
  private static let maximumNeovimEntries = 512
  private static let maximumNeovimBytes = 8 * 1_048_576
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

  package init() {}

  package func compose(
    resourcesRoot: URL,
    profile: PortableProfile,
    stateRoot: URL
  ) throws -> EnvironmentComposition {
    var artifacts: [EnvironmentConfigurationArtifact] = []
    let options = profile.environment
    var kittyOverrideArtifacts: [EnvironmentConfigurationArtifact] = []

    var neovimConfigurationURL: URL?
    if options.editor == .neovim {
      let packaged = resourcesRoot.appending(
        path: "neovim/default",
        directoryHint: .isDirectory
      )
      let source = options.neovim.configurationDirectoryURL ?? packaged
      neovimConfigurationURL = source
      artifacts.append(
        contentsOf: try readNeovimConfiguration(
          at: source,
          themeRoot: resourcesRoot.appending(
            path: "neovim/theme",
            directoryHint: .isDirectory
          ),
          stateRoot: stateRoot
        )
      )
    }

    if options.tools.bat {
      let source = resourcesRoot.appending(path: "bat/config")
      artifacts.append(
        EnvironmentConfigurationArtifact(
          path: "bat/config",
          contents: terminated(try readText(at: source))
        )
      )
    }

    if options.tools.btop {
      let source = resourcesRoot.appending(path: "btop/btop.conf")
      var configuration = try readText(at: source)
      if let vimKeys = options.btop.vimKeys {
        configuration = try replacingBtopValue(
          "vim_keys",
          with: vimKeys ? "True" : "False",
          in: configuration,
          source: source
        )
      }
      artifacts.append(
        EnvironmentConfigurationArtifact(
          path: "btop/btop.conf",
          contents: terminated(configuration)
        )
      )
    }

    if options.terminal == .kitty {
      let source = resourcesRoot.appending(path: "kitty/defaults.conf")
      var configuration = try readText(at: source)
      configuration = appendKittyOptions(options.kitty, to: configuration)
      if let overrideURL = options.kitty.overrideDirectoryURL {
        kittyOverrideArtifacts = try readKittyOverride(at: overrideURL)
        configuration = appendLine("include override/kitty.conf", to: configuration)
      }
      configuration = appendLine(
        "include " + stateRoot.appending(path: KittyAdapter.bridgePath).path,
        to: configuration
      )
      artifacts.append(
        EnvironmentConfigurationArtifact(path: "kitty/kitty.conf", contents: configuration)
      )
      artifacts.append(contentsOf: kittyOverrideArtifacts)
    }

    let zshHook: (text: String, digest: String)?
    if options.shell == .zsh {
      let defaults = resourcesRoot.appending(path: "zsh/defaults.zsh")
      var configuration = try readText(at: defaults)
      if let editor = options.zsh.editor {
        configuration = appendLine("export EDITOR=\"\(editor)\"", to: configuration)
        configuration = appendLine("export VISUAL=\"$EDITOR\"", to: configuration)
      }
      if options.tools.eza {
        configuration = appendSection(
          try readText(at: resourcesRoot.appending(path: "eza/defaults.zsh")),
          to: configuration
        )
      }
      if options.tools.yazi {
        configuration = appendSection(
          try readText(at: resourcesRoot.appending(path: "yazi/defaults.zsh")),
          to: configuration
        )
      }
      if options.history == .atuin {
        configuration = appendLine(
          "MACARCHY_ATUIN_INIT=\"$(atuin init zsh)\" || return 1",
          to: configuration
        )
        configuration = appendLine(
          "eval \"$MACARCHY_ATUIN_INIT\" || return 1",
          to: configuration
        )
        configuration = appendLine(
          "unset MACARCHY_ATUIN_INIT",
          to: configuration
        )
      }
      if options.prompt == .starship {
        configuration = appendLine(
          "MACARCHY_STARSHIP_INIT=\"$(starship init zsh)\" || return 1",
          to: configuration
        )
        configuration = appendLine(
          "eval \"$MACARCHY_STARSHIP_INIT\" || return 1",
          to: configuration
        )
        configuration = appendLine(
          "unset MACARCHY_STARSHIP_INIT",
          to: configuration
        )
      }
      configuration = appendLine("export MACARCHY_MANAGED_SESSION=1", to: configuration)
      if let hookURL = options.zsh.hookURL {
        let text = try readText(at: hookURL)
        zshHook = (text, sha256Digest(Data(text.utf8)))
        configuration = appendSection(text, to: configuration)
      } else {
        zshHook = nil
      }
      artifacts.append(
        EnvironmentConfigurationArtifact(path: "zsh/.zshrc", contents: configuration)
      )
    } else {
      zshHook = nil
    }

    var starshipBehaviorURL: URL?
    if options.prompt == .starship {
      let source =
        options.starship.behaviorURL
        ?? resourcesRoot.appending(path: "starship/behavior.toml")
      starshipBehaviorURL = source
      let behavior = try readText(at: source)
      try validateStarship(behavior, source: source)
      artifacts.append(
        EnvironmentConfigurationArtifact(
          path: "starship/behavior.toml",
          contents: terminated(behavior)
        )
      )
    }

    var atuinConfigurationURL: URL?
    if options.history == .atuin {
      let source =
        options.atuin.configurationURL
        ?? resourcesRoot.appending(path: "atuin/config.toml")
      atuinConfigurationURL = source
      var configuration = try readText(at: source)
      try validateAtuin(configuration, source: source)
      configuration = try applyAtuinOptions(
        options.atuin,
        to: configuration,
        source: source
      )
      try validateEffectiveAtuin(configuration, source: source)
      configuration = appendSection(
        "[theme]\nname = \"\(AtuinAdapter.themeName)\"\n",
        to: configuration
      )
      try validateTOML(configuration, source: source, role: "Atuin")
      artifacts.append(
        EnvironmentConfigurationArtifact(path: "atuin/config.toml", contents: configuration)
      )
    }

    if options.tools.yazi {
      let behaviorSource = resourcesRoot.appending(path: "yazi/yazi.toml")
      var behavior = try readText(at: behaviorSource)
      if let showHidden = options.yazi.showHidden {
        behavior = setTOMLValue(
          String(showHidden),
          table: "mgr",
          key: "show_hidden",
          in: behavior
        )
      }
      try validateTOML(behavior, source: behaviorSource, role: "Yazi")
      let themeSource = resourcesRoot.appending(path: "yazi/theme.toml")
      let theme = try readText(at: themeSource)
      try validateTOML(theme, source: themeSource, role: "Yazi theme")
      artifacts.append(
        EnvironmentConfigurationArtifact(
          path: "yazi/theme.toml",
          contents: terminated(theme)
        )
      )
      artifacts.append(
        EnvironmentConfigurationArtifact(
          path: "yazi/yazi.toml",
          contents: terminated(behavior)
        )
      )
    }

    artifacts.sort { $0.path < $1.path }
    let renderedDigest = Self.artifactDigest(artifacts)
    let identity = EnvironmentInputIdentity(
      schemaVersion: 1,
      terminal: options.terminal.rawValue,
      shell: options.shell.rawValue,
      prompt: options.prompt.rawValue,
      history: options.history.rawValue,
      editor: options.editor.rawValue,
      tools: [
        "bat": options.tools.bat,
        "btop": options.tools.btop,
        "eza": options.tools.eza,
        "yazi": options.tools.yazi,
      ],
      presets: [
        "codex": options.presets.codex,
        "herdr": options.presets.herdr,
        "pi": options.presets.pi,
        "tuicr": options.presets.tuicr,
      ],
      artifacts: Dictionary(uniqueKeysWithValues: artifacts.map { ($0.path, $0.digest) })
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return EnvironmentComposition(
      profile: options,
      artifacts: artifacts,
      kittyOverrideURL: options.kitty.overrideDirectoryURL,
      zshHookURL: options.zsh.hookURL,
      zshHookDigest: zshHook?.digest,
      starshipBehaviorURL: starshipBehaviorURL,
      atuinConfigurationURL: atuinConfigurationURL,
      neovimConfigurationURL: neovimConfigurationURL,
      renderedDigest: renderedDigest,
      inputDigest: sha256Digest(try encoder.encode(identity))
    )
  }

  private func appendKittyOptions(
    _ options: KittyProfileOptions,
    to configuration: String
  ) -> String {
    var result = configuration
    if let value = options.fontFamily { result = appendLine("font_family \(value)", to: result) }
    if let value = options.fontSize { result = appendLine("font_size \(value)", to: result) }
    if let value = options.backgroundOpacity {
      result = appendLine("background_opacity \(value)", to: result)
    }
    if let value = options.backgroundBlur {
      result = appendLine("background_blur \(value)", to: result)
    }
    return result
  }

  private func readKittyOverride(
    at root: URL
  ) throws -> [EnvironmentConfigurationArtifact] {
    let rootDescriptor: Int32
    do {
      rootDescriptor = try PinnedFilesystem.openDirectory(at: root)
    } catch {
      throw EnvironmentConfigurationError.unsafeOverride(root, "must be a symlink-free directory")
    }
    defer { Darwin.close(rootDescriptor) }
    var files: [(relative: String, source: URL, text: String)] = []
    var entries = 0
    var bytes = 0
    try walkKittyOverride(
      root: root,
      directory: root,
      directoryDescriptor: rootDescriptor,
      relativeDirectory: "",
      files: &files,
      entries: &entries,
      bytes: &bytes
    )
    let paths = Set(files.map(\.relative))
    guard paths.contains("kitty.conf") else {
      throw EnvironmentConfigurationError.unsafeOverride(root, "kitty.conf is missing")
    }
    for file in files {
      try validateKittyIncludes(file, inventory: paths)
    }
    return files.map {
      EnvironmentConfigurationArtifact(path: "kitty/override/\($0.relative)", contents: $0.text)
    }
  }

  private func readNeovimConfiguration(
    at source: URL,
    themeRoot: URL,
    stateRoot: URL
  ) throws -> [EnvironmentConfigurationArtifact] {
    let packagedTheme = try readNativeTree(
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
    let nativeTree = try readNativeTree(
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

  private func readNativeTree(
    at root: URL,
    targetRoot: String,
    allowLegacyThemeLink: Bool
  ) throws -> NeovimNativeTree {
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: root)
    } catch {
      throw EnvironmentConfigurationError.cannotRead(root, String(describing: error))
    }
    defer { Darwin.close(descriptor) }
    var artifacts: [EnvironmentConfigurationArtifact] = []
    var entries = 0
    var bytes = 0
    var hasLegacyThemeLink = false
    try walkNativeTree(
      root: root,
      directory: root,
      descriptor: descriptor,
      relativeDirectory: "",
      targetRoot: targetRoot,
      allowLegacyThemeLink: allowLegacyThemeLink,
      artifacts: &artifacts,
      entries: &entries,
      bytes: &bytes,
      hasLegacyThemeLink: &hasLegacyThemeLink
    )
    return NeovimNativeTree(
      artifacts: artifacts,
      hasLegacyThemeLink: hasLegacyThemeLink
    )
  }

  private func walkNativeTree(
    root: URL,
    directory: URL,
    descriptor: Int32,
    relativeDirectory: String,
    targetRoot: String,
    allowLegacyThemeLink: Bool,
    artifacts: inout [EnvironmentConfigurationArtifact],
    entries: inout Int,
    bytes: inout Int,
    hasLegacyThemeLink: inout Bool
  ) throws {
    let listing = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor,
      url: directory,
      limit: max(0, Self.maximumNeovimEntries - entries)
    )
    guard !listing.truncated else {
      throw EnvironmentConfigurationError.invalid(
        root,
        "Neovim configuration contains more than \(Self.maximumNeovimEntries) entries"
      )
    }
    for name in listing.entries {
      entries += 1
      guard entries <= Self.maximumNeovimEntries else {
        throw EnvironmentConfigurationError.invalid(
          root,
          "Neovim configuration contains more than \(Self.maximumNeovimEntries) entries"
        )
      }
      let child = directory.appending(path: name)
      let metadata = try PinnedFilesystem.metadata(
        parentDescriptor: descriptor,
        name: name,
        url: child
      )
      let relative =
        relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR:
        let childDescriptor = try PinnedFilesystem.openDirectory(
          parentDescriptor: descriptor,
          name: name,
          url: child
        )
        do {
          defer { Darwin.close(childDescriptor) }
          try walkNativeTree(
            root: root,
            directory: child,
            descriptor: childDescriptor,
            relativeDirectory: relative,
            targetRoot: targetRoot,
            allowLegacyThemeLink: allowLegacyThemeLink,
            artifacts: &artifacts,
            entries: &entries,
            bytes: &bytes,
            hasLegacyThemeLink: &hasLegacyThemeLink
          )
        }
      case S_IFREG:
        let data = try PinnedFilesystem.readRegularFile(
          parentDescriptor: descriptor,
          name: name,
          url: child,
          maximumSize: BoundedRegularFile.maximumSize
        ).data
        bytes += data.count
        guard bytes <= Self.maximumNeovimBytes else {
          throw EnvironmentConfigurationError.invalid(
            root,
            "Neovim configuration exceeds \(Self.maximumNeovimBytes) bytes"
          )
        }
        artifacts.append(
          EnvironmentConfigurationArtifact(
            path: "\(targetRoot)/\(relative)",
            data: data
          )
        )
      case S_IFLNK
      where
        allowLegacyThemeLink && relative == "lua/macarchy/current.lua":
        let destination = try PinnedFilesystem.symlinkDestination(
          parentDescriptor: descriptor,
          name: name,
          url: child
        )
        guard destination.hasPrefix("/"),
          destination.hasSuffix("/.config/macarchy/current/generated/neovim.lua")
        else {
          throw EnvironmentConfigurationError.invalid(
            root,
            "reserved Neovim theme link has an unexpected destination"
          )
        }
        hasLegacyThemeLink = true
      case S_IFLNK:
        throw EnvironmentConfigurationError.invalid(
          root,
          "Neovim configuration contains symbolic link \(relative)"
        )
      default:
        throw EnvironmentConfigurationError.invalid(
          root,
          "Neovim configuration contains unsupported entry \(relative)"
        )
      }
    }
  }

  private func walkKittyOverride(
    root: URL,
    directory: URL,
    directoryDescriptor: Int32,
    relativeDirectory: String,
    files: inout [(relative: String, source: URL, text: String)],
    entries: inout Int,
    bytes: inout Int
  ) throws {
    let names: [String]
    do {
      let listing = try PinnedFilesystem.directoryEntries(
        descriptor: directoryDescriptor,
        url: directory,
        limit: max(0, Self.maximumOverrideEntries - entries)
      )
      guard !listing.truncated else {
        throw EnvironmentConfigurationError.unsafeOverride(
          root,
          "contains more than \(Self.maximumOverrideEntries) entries"
        )
      }
      names = listing.entries
    } catch {
      if let error = error as? EnvironmentConfigurationError { throw error }
      throw EnvironmentConfigurationError.cannotRead(directory, String(describing: error))
    }
    for name in names {
      entries += 1
      guard entries <= Self.maximumOverrideEntries else {
        throw EnvironmentConfigurationError.unsafeOverride(
          root,
          "contains more than \(Self.maximumOverrideEntries) entries"
        )
      }
      let child = directory.appending(path: name)
      let metadata: stat
      do {
        metadata = try PinnedFilesystem.metadata(
          parentDescriptor: directoryDescriptor,
          name: name,
          url: child
        )
      } catch {
        throw EnvironmentConfigurationError.cannotRead(child, String(describing: error))
      }
      let relative =
        relativeDirectory.isEmpty
        ? name : relativeDirectory + "/" + name
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR:
        let childDescriptor: Int32
        do {
          childDescriptor = try PinnedFilesystem.openDirectory(
            parentDescriptor: directoryDescriptor,
            name: name,
            url: child
          )
        } catch {
          throw EnvironmentConfigurationError.cannotRead(child, String(describing: error))
        }
        defer { Darwin.close(childDescriptor) }
        try walkKittyOverride(
          root: root,
          directory: child,
          directoryDescriptor: childDescriptor,
          relativeDirectory: relative,
          files: &files,
          entries: &entries,
          bytes: &bytes
        )
      case S_IFREG:
        let file: BoundedRegularFile
        do {
          file = try PinnedFilesystem.readRegularFile(
            parentDescriptor: directoryDescriptor,
            name: name,
            url: child
          )
        } catch {
          throw EnvironmentConfigurationError.cannotRead(child, String(describing: error))
        }
        guard let text = String(data: file.data, encoding: .utf8) else {
          throw EnvironmentConfigurationError.cannotRead(
            child,
            String(describing: BoundedRegularFileError.invalidUTF8)
          )
        }
        bytes += text.utf8.count
        guard bytes <= Self.maximumOverrideBytes else {
          throw EnvironmentConfigurationError.unsafeOverride(root, "exceeds the 4 MiB limit")
        }
        files.append((relative, child, terminated(text)))
      case S_IFLNK:
        throw EnvironmentConfigurationError.unsafeOverride(
          root,
          "\(relative) is a symbolic link"
        )
      default:
        throw EnvironmentConfigurationError.unsafeOverride(
          root,
          "\(relative) is not a regular file"
        )
      }
    }
  }

  private func validateKittyIncludes(
    _ file: (relative: String, source: URL, text: String),
    inventory: Set<String>
  ) throws {
    for rawLine in file.text.split(whereSeparator: \Character.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard let directive = parts.first.map(String.init) else { continue }
      if ["globinclude", "envinclude", "geninclude"].contains(directive) {
        throw EnvironmentConfigurationError.unsafeOverride(
          file.source,
          "only exact relative include directives are supported"
        )
      }
      guard directive == "include" else { continue }
      guard parts.count == 2 else {
        throw EnvironmentConfigurationError.unsafeOverride(
          file.source,
          "include paths must be exact profile-relative files"
        )
      }
      let value = String(parts[1])
      guard !value.contains(where: \.isWhitespace), !NSString(string: value).isAbsolutePath,
        !value.contains(where: { "~$*?[]{}".contains($0) })
      else {
        throw EnvironmentConfigurationError.unsafeOverride(
          file.source,
          "include paths must be exact profile-relative files"
        )
      }
      let base = (file.relative as NSString).deletingLastPathComponent
      let candidate = (base.isEmpty ? value : "\(base)/\(value)") as NSString
      let normalized = candidate.standardizingPath
      guard normalized != "..", !normalized.hasPrefix("../"), inventory.contains(normalized) else {
        throw EnvironmentConfigurationError.unsafeOverride(
          file.source,
          "include '\(value)' does not resolve to an override file"
        )
      }
    }
  }

  private func validateStarship(_ text: String, source: URL) throws {
    let document: StarshipThemeOwnership
    do {
      document = try TOMLDecoder().decode(StarshipThemeOwnership.self, from: text)
    } catch {
      throw EnvironmentConfigurationError.invalid(source, "Starship behavior is not valid TOML")
    }
    guard document.palette == nil, document.palettes == nil else {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Starship behavior must not define palette or palettes"
      )
    }
  }

  private func validateAtuin(_ text: String, source: URL) throws {
    let document: AtuinThemeOwnership
    do {
      document = try TOMLDecoder().decode(AtuinThemeOwnership.self, from: text)
    } catch {
      throw EnvironmentConfigurationError.invalid(source, "Atuin behavior is not valid TOML")
    }
    guard document.theme == nil else {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Atuin behavior must not define the theme table"
      )
    }
  }

  private func validateEffectiveAtuin(_ text: String, source: URL) throws {
    let settings: AtuinEffectiveSettings
    do {
      settings = try TOMLDecoder().decode(AtuinEffectiveSettings.self, from: text)
    } catch {
      throw EnvironmentConfigurationError.invalid(source, "Atuin behavior is not valid TOML")
    }
    if settings.searchMode == "daemon-fuzzy", settings.daemon?.enabled != true {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Atuin daemon-fuzzy search requires daemon.enabled = true"
      )
    }
  }

  private func applyAtuinOptions(
    _ options: AtuinProfileOptions,
    to text: String,
    source: URL
  ) throws -> String {
    let values: [(table: String?, key: String, value: String)] = [
      options.searchMode.map { (nil, "search_mode", "\"\($0)\"") },
      options.keymapMode.map { (nil, "keymap_mode", "\"\($0)\"") },
      options.enterAccept.map { (nil, "enter_accept", String($0)) },
      options.daemon.map { ("daemon", "enabled", String($0)) },
      options.daemon.map { ("daemon", "autostart", String($0)) },
    ].compactMap { $0 }
    guard !values.isEmpty else { return terminated(text) }
    do {
      _ = try TOMLSourceIndex(text: text, file: source, syntaxRole: "Atuin behavior")
    } catch {
      throw EnvironmentConfigurationError.invalid(source, String(describing: error))
    }
    var result = text
    for value in values {
      result = setTOMLValue(value.value, table: value.table, key: value.key, in: result)
    }
    try validateTOML(result, source: source, role: "Atuin")
    return terminated(result)
  }

  private func setTOMLValue(
    _ value: String,
    table: String?,
    key: String,
    in text: String
  ) -> String {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
      .map(String.init)
    var currentTable: String?
    var inArrayTable = false
    var tableFound = false
    var nextTableLine: Int?
    for index in lines.indices {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[[") {
        if !inArrayTable, currentTable == table, nextTableLine == nil {
          nextTableLine = index
        }
        currentTable = nil
        inArrayTable = true
        continue
      }
      if trimmed.hasPrefix("["), let closing = trimmed.firstIndex(of: "]") {
        if !inArrayTable, currentTable == table, nextTableLine == nil {
          nextTableLine = index
        }
        let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
          .trimmingCharacters(in: .whitespaces)
        currentTable = name
        inArrayTable = false
        if currentTable == table { tableFound = true }
        continue
      }
      guard !inArrayTable, currentTable == table,
        let equals = lines[index].firstIndex(of: "=")
      else { continue }
      let candidate = lines[index][..<equals].trimmingCharacters(in: .whitespaces)
      if candidate == key {
        lines[index] = "\(key) = \(value)"
        return terminated(lines.joined(separator: "\n"))
      }
    }
    if table == nil {
      let insertion =
        lines.firstIndex {
          $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }
        ?? lines.endIndex
      lines.insert("\(key) = \(value)", at: insertion)
    } else if tableFound {
      lines.insert("\(key) = \(value)", at: nextTableLine ?? lines.endIndex)
    } else if let table {
      if lines.last?.isEmpty == false { lines.append("") }
      lines.append("[\(table)]")
      lines.append("\(key) = \(value)")
    }
    return terminated(lines.joined(separator: "\n"))
  }

  private func validateTOML(_ text: String, source: URL, role: String) throws {
    do {
      _ = try TOMLDecoder().decode(TOMLValidationDocument.self, from: text)
    } catch {
      throw EnvironmentConfigurationError.invalid(source, "\(role) behavior is not valid TOML")
    }
  }

  private func replacingBtopValue(
    _ key: String,
    with value: String,
    in text: String,
    source: URL
  ) throws -> String {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
      .map(String.init)
    let matches = lines.indices.filter { index in
      let content = lines[index].split(separator: "#", maxSplits: 1).first ?? ""
      guard let equals = content.firstIndex(of: "=") else { return false }
      return content[..<equals].trimmingCharacters(in: .whitespaces) == key
    }
    guard matches.count == 1, let index = matches.first else {
      throw EnvironmentConfigurationError.invalid(
        source,
        "btop baseline must define exactly one \(key) value"
      )
    }
    lines[index] = "\(key) = \(value)"
    return lines.joined(separator: "\n")
  }

  private func readText(at source: URL) throws -> String {
    let parent = source.deletingLastPathComponent()
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: parent)
    } catch {
      throw EnvironmentConfigurationError.cannotRead(source, String(describing: error))
    }
    defer { Darwin.close(descriptor) }
    do {
      let file = try PinnedFilesystem.readRegularFile(
        parentDescriptor: descriptor,
        name: source.lastPathComponent,
        url: source
      )
      guard let text = String(data: file.data, encoding: .utf8) else {
        throw BoundedRegularFileError.invalidUTF8
      }
      return text
    } catch {
      throw EnvironmentConfigurationError.cannotRead(source, String(describing: error))
    }
  }

  private func appendLine(_ line: String, to text: String) -> String {
    appendSection(line + "\n", to: text)
  }

  private func appendSection(_ section: String, to text: String) -> String {
    terminated(text).trimmingCharacters(in: .newlines) + "\n\n" + terminated(section)
  }

  private func terminated(_ text: String) -> String {
    text.hasSuffix("\n") ? text : text + "\n"
  }

  private static func artifactDigest(_ artifacts: [EnvironmentConfigurationArtifact]) -> String {
    let canonical = artifacts.map { "\($0.path)\u{0}\($0.digest)\n" }.joined()
    return sha256Digest(Data(canonical.utf8))
  }

}

private struct EnvironmentInputIdentity: Encodable {
  let schemaVersion: Int
  let terminal: String
  let shell: String
  let prompt: String
  let history: String
  let editor: String
  let tools: [String: Bool]
  let presets: [String: Bool]
  let artifacts: [String: String]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case terminal, shell, prompt, history, editor, tools, presets, artifacts
  }
}

private struct StarshipThemeOwnership: Decodable {
  let palette: String?
  let palettes: [String: [String: String]]?
}

private struct AtuinThemeOwnership: Decodable {
  let theme: ThemeMarker?
}

private struct AtuinEffectiveSettings: Decodable {
  let searchMode: String?
  let daemon: AtuinDaemonSettings?

  enum CodingKeys: String, CodingKey {
    case searchMode = "search_mode"
    case daemon
  }
}

private struct AtuinDaemonSettings: Decodable {
  let enabled: Bool?
}

private struct ThemeMarker: Decodable {}
private struct TOMLValidationDocument: Decodable {}
