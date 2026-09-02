import Darwin
import Foundation
import TOMLDecoder

package struct EnvironmentConfigurationArtifact: Equatable, Sendable {
  package let path: String
  package let contents: String
  package let digest: String

  package init(path: String, contents: String) {
    self.path = path
    self.contents = contents
    digest = sha256Digest(Data(contents.utf8))
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

  package func compose(
    resourcesRoot: URL,
    profile: PortableProfile,
    stateRoot: URL
  ) throws -> EnvironmentComposition {
    var artifacts: [EnvironmentConfigurationArtifact] = []
    let options = profile.environment
    var kittyOverrideArtifacts: [EnvironmentConfigurationArtifact] = []

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
      tools: [
        "bat": options.tools.bat,
        "btop": options.tools.btop,
        "eza": options.tools.eza,
        "yazi": options.tools.yazi,
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
  let tools: [String: Bool]
  let artifacts: [String: String]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case terminal, shell, prompt, history, tools, artifacts
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
