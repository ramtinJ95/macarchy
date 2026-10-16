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

  private static let maximumOverrideEntries = 128
  private static let maximumOverrideBytes = 4 * 1_048_576

  package init() {}

  package static func nativeZshDefaultsSource(stateRoot: URL) -> String {
    let path = stateRoot.appending(path: "environment/current/zsh/defaults.zsh").path
    return "source '" + path.replacingOccurrences(of: "'", with: "'\\''") + "' || return 1"
  }

  /// Narrow first-run classification, not ownership of arbitrary native behavior.
  package func matchesCuratedNeovimStarter(
    at source: URL, resourcesRoot: URL, stateRoot: URL
  ) throws -> Bool {
    let expected = try compose(
      resourcesRoot: resourcesRoot, profile: .defaults, stateRoot: stateRoot
    ).artifacts.filter { $0.path.hasPrefix("neovim/") }
    let links = Dictionary(
      uniqueKeysWithValues: NeovimAdapter.managedThemePaths.map {
        ($0, stateRoot.appending(path: "environment/current/neovim/\($0)").path)
      })
    // A different/unsupported personal tree is deliberately not bootstrap authority.
    // Its normal native connection remains responsible for its own validation.
    guard
      let tree = try? EnvironmentNativeTreeReader().read(
        at: source, targetRoot: "neovim", allowLegacyThemeLink: false,
        allowedThemeLinks: links)
    else { return false }
    let behavior = expected.filter {
      !NeovimAdapter.managedThemePaths.contains(String($0.path.dropFirst("neovim/".count)))
    }
    return Dictionary(uniqueKeysWithValues: tree.artifacts.map { ($0.path, $0.data) })
      == Dictionary(uniqueKeysWithValues: behavior.map { ($0.path, $0.data) })
  }

  package static func nativeKittyWrapper(source: URL, stateRoot: URL) -> String {
    "include " + source.path + "\n\ninclude "
      + stateRoot.appending(path: KittyAdapter.bridgePath).path + "\n"
  }

  /// Shared by publication and connection verification; never execute the wrapper
  /// to infer which personal source it loads.
  package static func nativeZshWrapper(source: URL, stateRoot: URL) -> String {
    let quote: (String) -> String = {
      "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return """
      # User-owned live configuration; Macarchy never rewrites this source.
      export MACARCHY_ZSH_DEFAULTS=\(quote(stateRoot.appending(path: "environment/current/zsh/defaults.zsh").path))
      source \(quote(source.path)) || return 1
      export MACARCHY_MANAGED_SESSION=1
      """ + "\n"
  }

  package func compose(
    resourcesRoot: URL,
    profile: PortableProfile,
    stateRoot: URL,
    proposedNativeFiles: [URL: Data] = [:]
  ) throws -> EnvironmentComposition {
    try compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: stateRoot,
      proposedNativeFiles: proposedNativeFiles, scope: nil)
  }

  private func compose(
    resourcesRoot: URL, profile: PortableProfile, stateRoot: URL,
    proposedNativeFiles: [URL: Data], scope: String?
  ) throws -> EnvironmentComposition {
    var artifacts: [EnvironmentConfigurationArtifact] = []
    let options = profile.environment
    var kittyOverrideArtifacts: [EnvironmentConfigurationArtifact] = []
    /// A native source's proposed bytes when supplied, else its current contents.
    func nativeText(_ source: URL) throws -> String {
      try proposedNativeFiles[source].map { String(decoding: $0, as: UTF8.self) }
        ?? readText(at: source.resolvingSymlinksInPath())
    }

    if scope == nil, options.focusRing != .disabled {
      // Lean retains this inert artifact so an already-owned Borders entry can
      // stay reversible while its service is suspended. Fresh lean owns no Borders entry.
      artifacts.append(
        EnvironmentConfigurationArtifact(
          path: BordersConfiguration.artifactPath,
          contents: BordersConfiguration.contents(stateRoot: stateRoot)
        ))
    }

    var neovimConfigurationURL: URL?
    if scope == nil, options.editor == .neovim {
      let neovim = try EnvironmentNeovimConfiguration().compose(
        resourcesRoot: resourcesRoot,
        configurationDirectoryURL: options.neovim.configurationDirectoryURL,
        stateRoot: stateRoot,
        nativeConfigurationDirectoryURL: options.neovim.nativeConfigurationDirectoryURL,
        proposedNativeFiles: proposedNativeFiles
      )
      neovimConfigurationURL = neovim.source
      artifacts.append(contentsOf: neovim.artifacts)
    }

    if scope == nil, options.tools.bat {
      let source = resourcesRoot.appending(path: "bat/config")
      artifacts.append(
        EnvironmentConfigurationArtifact(
          path: "bat/config",
          contents: terminated(try readText(at: source))
        )
      )
    }

    if scope == nil, options.tools.btop {
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

    if scope == nil || scope == "kitty", options.terminal == .kitty {
      let source = resourcesRoot.appending(path: "kitty/defaults.conf")
      var configuration = try readText(at: source)
      configuration = appendKittyOptions(options.kitty, to: configuration)
      if let nativeSource = options.kitty.configurationURL {
        guard options.kitty.overrideDirectoryURL == nil else {
          throw EnvironmentConfigurationError.invalid(
            nativeSource, "kitty.configuration and kitty.override are mutually exclusive")
        }
        _ = try nativeText(nativeSource)
        guard !nativeSource.path.contains("$"),
          !nativeSource.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
          throw EnvironmentConfigurationError.invalid(
            nativeSource,
            "kitty.configuration must not contain control characters or environment expansion")
        }
        artifacts.append(
          EnvironmentConfigurationArtifact(path: "kitty/defaults.conf", contents: configuration)
        )
        configuration = Self.nativeKittyWrapper(source: nativeSource, stateRoot: stateRoot)
      } else {
        if let overrideURL = options.kitty.overrideDirectoryURL {
          kittyOverrideArtifacts = try readKittyOverride(at: overrideURL)
          configuration = appendLine("include override/kitty.conf", to: configuration)
        }
        configuration = appendLine(
          "include " + stateRoot.appending(path: KittyAdapter.bridgePath).path,
          to: configuration)
      }
      artifacts.append(
        EnvironmentConfigurationArtifact(path: "kitty/kitty.conf", contents: configuration)
      )
      artifacts.append(contentsOf: kittyOverrideArtifacts)
    }

    let zshHookDigest: String?
    if scope == nil || scope == "zsh", options.shell == .zsh {
      if let source = options.zsh.configurationURL, options.zsh.hookURL != nil {
        throw EnvironmentConfigurationError.invalid(
          source, "zsh.configuration and zsh.hook are mutually exclusive"
        )
      }
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
        configuration = appendSection(
          """
          # Match the supported external-before-Homebrew Atuin installation order.
          # Its generated widgets also need the executable on the session PATH.
          if [[ -x "$HOME/.atuin/bin/atuin" ]]; then
            path=("$HOME/.atuin/bin" $path)
            export PATH
          fi
          """,
          to: configuration
        )
        configuration = appendInitialization(of: "atuin", to: configuration)
      }
      if options.prompt == .starship {
        configuration = appendInitialization(of: "starship", to: configuration)
      }
      configuration = appendSection(
        """
        if [[ -o interactive ]]; then
          source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh || return 1
        fi
        """,
        to: configuration
      )
      configuration = appendLine("export MACARCHY_MANAGED_SESSION=1", to: configuration)
      if let hookURL = options.zsh.hookURL {
        let text = try readText(at: hookURL)
        zshHookDigest = sha256Digest(Data(text.utf8))
        configuration = appendSection(text, to: configuration)
      } else {
        zshHookDigest = nil
      }
      if let source = options.zsh.configurationURL {
        // Validate availability without making writable behavior part of generation identity.
        // The source decides whether and where curated initialization runs.
        _ = try nativeText(source)
        let entry = stateRoot.appending(path: "environment/current/zsh/.zshrc")
        guard source.resolvingSymlinksInPath() != entry.resolvingSymlinksInPath() else {
          throw EnvironmentConfigurationError.invalid(
            source, "zsh.configuration resolves to the managed entry point")
        }
        artifacts.append(
          EnvironmentConfigurationArtifact(path: "zsh/defaults.zsh", contents: configuration)
        )
        configuration = Self.nativeZshWrapper(source: source, stateRoot: stateRoot)
      }
      artifacts.append(
        EnvironmentConfigurationArtifact(path: "zsh/.zshrc", contents: configuration)
      )
    } else {
      zshHookDigest = nil
    }

    var starshipBehaviorURL: URL?
    if scope == nil || scope == "starship", options.prompt == .starship {
      if let source = options.starship.nativeConfigurationURL {
        guard options.starship.behaviorURL == nil else {
          throw EnvironmentConfigurationError.invalid(
            source, "starship.native_configuration cannot be combined with starship.behavior")
        }
        let native = StarshipNativeConfiguration(url: source.resolvingSymlinksInPath())
        let data = try proposedNativeFiles[source] ?? native.read()
        _ = try native.replacingPalette(in: data, with: String(decoding: data, as: UTF8.self))
        starshipBehaviorURL = source
        let encodedPath = try JSONEncoder().encode(source.path)
        artifacts.append(
          EnvironmentConfigurationArtifact(
            path: "starship/behavior.toml",
            contents: "# Native source: " + String(decoding: encodedPath, as: UTF8.self) + "\n"))
      } else {
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
    }

    var atuinConfigurationURL: URL?
    if scope == nil || scope == "atuin", options.history == .atuin {
      if let source = options.atuin.nativeConfigurationURL {
        guard options.atuin.configurationURL == nil,
          options.atuin.searchMode == nil, options.atuin.keymapMode == nil,
          options.atuin.enterAccept == nil, options.atuin.daemon == nil
        else {
          throw EnvironmentConfigurationError.invalid(
            source,
            "atuin.native_configuration cannot be combined with copied Atuin behavior options")
        }
        let text = try nativeText(source)
        guard AtuinAdapter.selectsTheme(in: text) else {
          throw EnvironmentConfigurationError.invalid(
            source, "atuin.native_configuration must select the Macarchy theme")
        }
        atuinConfigurationURL = source
        // Only the connection contributes to generation identity, never personal settings.
        let encodedPath = try JSONEncoder().encode(source.path)
        artifacts.append(
          EnvironmentConfigurationArtifact(
            path: "atuin/config.toml",
            contents: "# Native source: " + String(decoding: encodedPath, as: UTF8.self)
              + "\n[theme]\nname = \"\(AtuinAdapter.themeName)\"\n"))
      } else {
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
    }

    if scope == nil, options.tools.yazi {
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
      focusRing: options.focusRing.rawValue,
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
    return EnvironmentComposition(
      profile: options,
      artifacts: artifacts,
      kittyOverrideURL: options.kitty.overrideDirectoryURL,
      zshHookURL: options.zsh.hookURL,
      zshHookDigest: zshHookDigest,
      starshipBehaviorURL: starshipBehaviorURL,
      atuinConfigurationURL: atuinConfigurationURL,
      neovimConfigurationURL: neovimConfigurationURL,
      renderedDigest: renderedDigest,
      inputDigest: try canonicalJSONDigest(identity)
    )
  }

  /// A reviewed Neovim connection preserves every other provider's validated
  /// artifact bytes. Its digest deliberately does not claim full-profile apply.
  package func composeNeovimConnection(
    resourcesRoot: URL, source: URL, stateRoot: URL,
    retaining previous: [EnvironmentConfigurationArtifact], previousInputDigest: String?
  ) throws -> EnvironmentComposition {
    let neovim = try EnvironmentNeovimConfiguration().compose(
      resourcesRoot: resourcesRoot, configurationDirectoryURL: nil, stateRoot: stateRoot,
      nativeConfigurationDirectoryURL: source)
    let artifacts = (previous.filter { !$0.path.hasPrefix("neovim/") } + neovim.artifacts)
      .sorted { $0.path < $1.path }
    let rendered = Self.artifactDigest(artifacts)
    let identity = try JSONEncoder().encode([
      "neovim_connection_v1", previousInputDigest ?? "absent", source.path, rendered,
    ])
    return EnvironmentComposition(
      profile: PortableProfile.defaults.environment, artifacts: artifacts,
      kittyOverrideURL: nil, zshHookURL: nil, zshHookDigest: nil,
      starshipBehaviorURL: nil, atuinConfigurationURL: nil,
      neovimConfigurationURL: source, renderedDigest: rendered,
      inputDigest: sha256Digest(identity))
  }

  /// Compose only the selected native provider. In particular zsh still sees
  /// the declared prompt/history/tool choices, without reading or publishing
  /// those providers' inputs. This is not full-profile convergence.
  package func composeNativeConnection(
    provider: String, resourcesRoot: URL, profile: PortableProfile, source: URL,
    stateRoot: URL, retaining previous: [EnvironmentConfigurationArtifact],
    previousInputDigest: String?
  ) throws -> EnvironmentComposition {
    guard ["kitty", "zsh", "starship", "atuin"].contains(provider) else {
      throw EnvironmentConfigurationError.invalid(source, "unsupported native connection provider")
    }
    let scoped = try compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: stateRoot,
      proposedNativeFiles: [:], scope: provider)
    guard !scoped.artifacts.isEmpty,
      scoped.artifacts.allSatisfy({ $0.path.hasPrefix(provider + "/") })
    else {
      throw EnvironmentConfigurationError.invalid(source, "native connection provider is disabled")
    }
    let identity = EnvironmentConfigurationArtifact(
      path: provider + "/native-source.txt", data: try JSONEncoder().encode(source.path))
    let artifacts =
      (previous.filter { !$0.path.hasPrefix(provider + "/") }
      + scoped.artifacts + [identity]).sorted { $0.path < $1.path }
    let rendered = Self.artifactDigest(artifacts)
    return EnvironmentComposition(
      profile: scoped.profile, artifacts: artifacts,
      kittyOverrideURL: nil, zshHookURL: nil, zshHookDigest: nil,
      starshipBehaviorURL: scoped.starshipBehaviorURL,
      atuinConfigurationURL: scoped.atuinConfigurationURL, neovimConfigurationURL: nil,
      renderedDigest: rendered,
      inputDigest: sha256Digest(
        try JSONEncoder().encode([
          "native_connection_v1", provider, previousInputDigest ?? "absent", source.path, rendered,
        ])))
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

  private func walkKittyOverride(
    root: URL,
    directory: URL,
    directoryDescriptor: Int32,
    relativeDirectory: String,
    files: inout [(relative: String, source: URL, text: String)],
    entries: inout Int,
    bytes: inout Int
  ) throws {
    let listing: (entries: [String], truncated: Bool)
    do {
      listing = try PinnedFilesystem.directoryEntries(
        descriptor: directoryDescriptor,
        url: directory,
        limit: max(0, Self.maximumOverrideEntries - entries)
      )
    } catch {
      throw EnvironmentConfigurationError.cannotRead(directory, String(describing: error))
    }
    guard !listing.truncated else {
      throw EnvironmentConfigurationError.unsafeOverride(
        root,
        "contains more than \(Self.maximumOverrideEntries) entries"
      )
    }
    for name in listing.entries {
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
    let document = try decodeTOML(
      StarshipThemeOwnership.self, from: text, source: source, role: "Starship")
    guard document.palette == nil, document.palettes == nil else {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Starship behavior must not define palette or palettes"
      )
    }
  }

  private func validateAtuin(_ text: String, source: URL) throws {
    let document = try decodeTOML(
      AtuinThemeOwnership.self, from: text, source: source, role: "Atuin")
    guard document.theme == nil else {
      throw EnvironmentConfigurationError.invalid(
        source,
        "Atuin behavior must not define the theme table"
      )
    }
  }

  private func validateEffectiveAtuin(_ text: String, source: URL) throws {
    let settings = try decodeTOML(
      AtuinEffectiveSettings.self, from: text, source: source, role: "Atuin")
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
    _ = try decodeTOML(TOMLValidationDocument.self, from: text, source: source, role: role)
  }

  private func decodeTOML<Document: Decodable>(
    _ type: Document.Type, from text: String, source: URL, role: String
  ) throws -> Document {
    do {
      return try TOMLDecoder().decode(type, from: text)
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
    do {
      let file = try PinnedFilesystem.readRegularFile(at: source)
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

  /// Evaluates `<tool> init zsh`, failing the session setup when it fails.
  private func appendInitialization(of tool: String, to text: String) -> String {
    let variable = "MACARCHY_\(tool.uppercased())_INIT"
    return [
      "\(variable)=\"$(\(tool) init zsh)\" || return 1",
      "eval \"$\(variable)\" || return 1",
      "unset \(variable)",
    ].reduce(text) { appendLine($1, to: $0) }
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

struct EnvironmentNativeTreeReader {
  struct Tree {
    var artifacts: [EnvironmentConfigurationArtifact]
    var hasLegacyThemeLink: Bool
  }

  private static let maximumNeovimEntries = 512
  private static let maximumNeovimBytes = 8 * 1_048_576

  func read(
    at root: URL,
    targetRoot: String,
    allowLegacyThemeLink: Bool,
    allowedThemeLinks: [String: String] = [:]
  ) throws -> Tree {
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
      allowedThemeLinks: allowedThemeLinks,
      artifacts: &artifacts,
      entries: &entries,
      bytes: &bytes,
      hasLegacyThemeLink: &hasLegacyThemeLink
    )
    return Tree(
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
    allowedThemeLinks: [String: String],
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
            allowedThemeLinks: allowedThemeLinks,
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
      case S_IFLNK where allowedThemeLinks[relative] != nil:
        guard
          try PinnedFilesystem.symlinkDestination(
            parentDescriptor: descriptor, name: name, url: child) == allowedThemeLinks[relative]
        else {
          throw EnvironmentConfigurationError.invalid(root, "unexpected native theme link")
        }
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
}

private struct EnvironmentInputIdentity: Encodable {
  let schemaVersion: Int
  let focusRing: String
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
    case focusRing = "focus_ring"
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
