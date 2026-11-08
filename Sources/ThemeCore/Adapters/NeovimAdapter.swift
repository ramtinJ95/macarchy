import Darwin
import Foundation

enum NeovimAdapterError: Error, CustomStringConvertible, Sendable {
  case invalidMapping(String)
  case missingIntegration(String)
  case unexpectedThemeLink(URL, expected: URL)
  case runtimeValidationFailed(String)

  var description: String {
    switch self {
    case .invalidMapping(let mapping):
      "Neovim mapping '\(mapping)' must be a colorscheme name"
    case .missingIntegration(let directive):
      "Neovim theme configuration must contain '\(directive)'"
    case .unexpectedThemeLink(let url, let expected):
      "Neovim theme link at \(url.path) must point to \(expected.path)"
    case .runtimeValidationFailed(let message):
      message
    }
  }
}

package struct NeovimAdapter: Sendable {
  static let id = "neovim"
  package static let integrationDirective = "local current = macarchy.watch()"
  package static let backgroundAwareWatcherDirective =
    "if same_theme(state.theme, theme) then"
  package static let importedColorscheme = "macarchy-imported"
  package static let importedColorschemeDirective =
    "require(\"config.macarchy-theme\").apply_imported()"
  package static let aetherRepositoryDirective = "\"omacom-io/aether.nvim\","
  package static let aetherBranchDirective = "branch = \"v3\","
  package static let aetherCommit = "567efb778534e11ee1072d4fe27178f705a27d8a"
  package static let aetherCommitDirective = "commit = \"\(aetherCommit)\","
  package static let outputPath = "generated/neovim.lua"
  // Theme files inside the Neovim configuration directory.
  static let importedColorschemePath = "colors/\(importedColorscheme).lua"
  static let watcherPath = "lua/config/macarchy-theme.lua"
  static let themeLinkPath = "lua/macarchy/current.lua"
  static let configurationPath = "lua/plugins/colorscheme.lua"
  package static let managedThemePaths = [
    importedColorschemePath, watcherPath, themeLinkPath, configurationPath,
  ]
  static let rendererVersion = 4
  package static let liveExecutableURL = ExternalTool.neovim

  let root: URL
  let configurationDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner

  private var configurationURL: URL {
    configurationDirectoryURL.appending(path: Self.configurationPath)
  }

  private var importedColorschemeURL: URL {
    configurationDirectoryURL.appending(path: Self.importedColorschemePath)
  }

  private var watcherURL: URL {
    configurationDirectoryURL.appending(path: Self.watcherPath)
  }

  private var themeLink: CanonicalThemeLink {
    CanonicalThemeLink(
      url: configurationDirectoryURL.appending(path: Self.themeLinkPath),
      destination: StateLayout(root: root).currentThemeArtifact(Self.outputPath)
    )
  }

  private var runtime: OrdinaryAdapterRuntime {
    OrdinaryAdapterRuntime(
      .neovim,
      preflight: preflight,
      isIntegrationDrift: Self.isIntegrationDrift
    )
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw AdapterConfigurationError.controlUnavailable("Neovim", executableURL)
    }
    let usesManagedThemeLoader = try validateThemeLoader()
    guard Self.containsIntegrationDirective(in: try readConfiguration(at: configurationURL)) else {
      throw NeovimAdapterError.missingIntegration(Self.integrationDirective)
    }
    guard
      containsExactLine(
        Self.backgroundAwareWatcherDirective, in: try readConfiguration(at: watcherURL))
    else {
      throw NeovimAdapterError.missingIntegration(Self.backgroundAwareWatcherDirective)
    }
    if usesManagedThemeLoader {
      let watcherRoot = Self.managedWatcherRootDirective(root: root)
      guard containsExactLine(watcherRoot, in: try readConfiguration(at: watcherURL))
      else {
        throw NeovimAdapterError.missingIntegration(watcherRoot)
      }
    }
  }

  private func validateThemeLoader() throws -> Bool {
    var metadata = stat()
    if lstat(themeLink.url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFLNK {
      let destination = try FileManager.default.destinationOfSymbolicLink(
        atPath: themeLink.url.path)
      let managedLoader = StateLayout(root: root).environmentArtifact(
        "neovim/lua/macarchy/current.lua")
      if destination != managedLoader.path {
        try themeLink.validate()
        return false
      }
      // Native migration links to the managed loader, not directly to theme data.
      // Its bytes and watcher root must pass the same checks as the inline loader.
    }
    let directive = Self.managedThemeLoaderDirective(root: root)
    guard containsExactLine(directive, in: try readConfiguration(at: themeLink.url)) else {
      throw NeovimAdapterError.missingIntegration(directive)
    }
    return true
  }

  func preflight(package: ThemePackage) throws {
    try preflight()
    guard package.mappings[Self.id] == nil else { return }
    try preflightImportedSupport()
  }

  private func preflightImportedSupport() throws {
    let configuration = try readConfiguration(at: configurationURL)
    for directive in [
      Self.aetherRepositoryDirective,
      Self.aetherBranchDirective,
      Self.aetherCommitDirective,
    ] where !containsExactLine(directive, in: configuration) {
      throw NeovimAdapterError.missingIntegration(directive)
    }
    let colorscheme = try readConfiguration(at: importedColorschemeURL)
    guard containsExactLine(Self.importedColorschemeDirective, in: colorscheme) else {
      throw NeovimAdapterError.missingIntegration(Self.importedColorschemeDirective)
    }
  }

  func inspection(includeRuntimeChecks: Bool = false) -> AdapterInspection {
    runtime.inspection(
      readyMessage: includeRuntimeChecks
        ? "Neovim validated the active colorscheme and canonical-pointer watcher"
        : "Neovim watches the canonical theme pointer for live colorscheme changes"
    ) {
      if includeRuntimeChecks {
        try preflightActiveSupport()
        try validateRuntime()
      }
    }
  }

  func reconciliation() -> AdapterReconciliation {
    runtime.reconciliation {
      do {
        try preflightActiveSupport()
        try validateRuntime()
      } catch {
        return AdapterOutcome(status: .failed, message: String(describing: error))
      }
      return AdapterOutcome(
        status: .applied,
        message:
          "Neovim validated the active colorscheme; running sessions repaint through the pointer watcher"
      )
    }
  }

  private func validateRuntime() throws {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    let marker = "MACARCHY_THEME=\(manifest.generationID):\(manifest.themeID)"
    let result = try processRunner.run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: [
          "--headless",
          "+lua local ok, theme = pcall(require('config.macarchy-theme').verify); if ok then io.write('MACARCHY_THEME=' .. theme.generation_id .. ':' .. theme.theme_id) else io.stderr:write(theme); vim.cmd.cquit() end",
          "+qa",
        ],
        timeout: 5
      )
    )
    guard result.terminationStatus == 0, result.output.contains(marker) else {
      throw NeovimAdapterError.runtimeValidationFailed(
        result.output.isEmpty
          ? "Neovim rejected the active colorscheme configuration" : result.output
      )
    }
  }

  private func preflightActiveSupport() throws {
    let generated = try readConfiguration(at: themeLink.destination)
    guard containsExactLine("colorscheme = \"\(Self.importedColorscheme)\",", in: generated)
    else { return }
    try preflightImportedSupport()
  }

  static func render(package: ThemePackage, generationID: String) throws -> String {
    guard let mapping = package.mappings[id] else {
      return renderImportedPalette(package: package, generationID: generationID)
    }
    guard
      !mapping.isEmpty,
      mapping.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
      })
    else {
      throw NeovimAdapterError.invalidMapping(mapping)
    }
    return """
      -- Generated by Macarchy. Do not edit.
      return {
        generation_id = "\(generationID)",
        theme_id = "\(package.id)",
        colorscheme = "\(mapping)",
      }

      """
  }

  private static func renderImportedPalette(
    package: ThemePackage,
    generationID: String
  ) -> String {
    let semantic = package.semantic
    let terminal = package.terminal
    let palette: [(String, SRGBColor)] = [
      ("accent", semantic.accent),
      ("cursor", terminal.cursor),
      ("foreground", terminal.foreground),
      ("background", terminal.background),
      ("selection_foreground", terminal.selectionForeground),
      ("selection_background", terminal.selectionBackground),
      ("bg", semantic.background),
      ("lighter_bg", semantic.surface),
      ("selection", semantic.selection),
      ("muted", semantic.border),
      ("dark_fg", semantic.mutedText),
      ("fg", semantic.text),
      ("light_fg", terminal.ansi[7]),
      ("bright_fg", terminal.ansi[15]),
      ("red", terminal.ansi[1]),
      ("yellow", terminal.ansi[3]),
      ("orange", semantic.warning),
      ("green", terminal.ansi[2]),
      ("cyan", terminal.ansi[6]),
      ("blue", terminal.ansi[4]),
      ("purple", terminal.ansi[5]),
      ("brown", semantic.mutedText),
      ("dark_bg", semantic.background),
      ("darker_bg", semantic.background),
      ("bright_red", terminal.ansi[9]),
      ("bright_yellow", terminal.ansi[11]),
      ("bright_green", terminal.ansi[10]),
      ("bright_cyan", terminal.ansi[14]),
      ("bright_blue", terminal.ansi[12]),
      ("bright_purple", terminal.ansi[13]),
    ]
    let entries = palette.map { "    \($0.0) = \"\($0.1.rawValue)\"," }.joined(separator: "\n")
    return """
      -- Generated by Macarchy. Do not edit.
      return {
        generation_id = "\(generationID)",
        theme_id = "\(package.id)",
        colorscheme = "\(importedColorscheme)",
        palette = {
      \(entries)
        },
      }

      """
  }

  private func readConfiguration(at url: URL) throws -> String {
    if let path = Self.managedThemePaths.first(where: {
      configurationDirectoryURL.appending(path: $0) == url
    }) {
      let managed = StateLayout(root: root).environmentArtifact("neovim/\(path)")
      return try AdapterConfigurationFile.readUTF8(
        at: url, managedDestination: managed,
        tooLarge: AdapterConfigurationError.configurationTooLarge(
          "Neovim theme configuration", url),
        unreadable: AdapterConfigurationError.cannotReadConfiguration(
          "Neovim theme configuration", url),
        unexpectedLink: { _ in NeovimAdapterError.unexpectedThemeLink(url, expected: managed) })
    }
    return try AdapterConfigurationFile.readUTF8(
      at: url,
      tooLarge: AdapterConfigurationError.configurationTooLarge("Neovim theme configuration", url),
      unreadable: AdapterConfigurationError.cannotReadConfiguration(
        "Neovim theme configuration", url)
    )
  }

  package static func containsIntegrationDirective(in text: String) -> Bool {
    containsExactLine(integrationDirective, in: text)
  }

  package static func managedThemeLoaderDirective(root: URL) -> String {
    let literal = luaStringLiteral(root.standardizedFileURL.path)
    return "loadfile(\(literal) .. \"/current/\(outputPath)\")"
  }

  package static func managedWatcherRootDirective(root: URL) -> String {
    "local root = \(luaStringLiteral(root.standardizedFileURL.path))"
  }

  package static func luaStringLiteral(_ value: String) -> String {
    var escaped = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22:
        escaped += "\\\""
      case 0x5C:
        escaped += "\\\\"
      case 0x0A:
        escaped += "\\n"
      case 0x0D:
        escaped += "\\r"
      case 0x09:
        escaped += "\\t"
      case 0..<0x20, 0x7F:
        escaped += String(format: "\\%03d", scalar.value)
      default:
        escaped.unicodeScalars.append(scalar)
      }
    }
    escaped += "\""
    return escaped
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case is CanonicalThemeLinkError, NeovimAdapterError.missingIntegration,
      NeovimAdapterError.unexpectedThemeLink:
      true
    default:
      false
    }
  }
}
