import Foundation

enum NeovimAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case configurationTooLarge(URL)
  case controlUnavailable(URL)
  case invalidMapping(String)
  case missingIntegration(String)
  case runtimeValidationFailed(String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Neovim theme configuration at \(url.path)"
    case .configurationTooLarge(let url):
      "Neovim theme configuration at \(url.path) exceeds 1 MiB"
    case .controlUnavailable(let url):
      "Neovim is not executable at \(url.path)"
    case .invalidMapping(let mapping):
      "Neovim mapping '\(mapping)' must be a colorscheme name"
    case .missingIntegration(let directive):
      "Neovim theme configuration must contain '\(directive)'"
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
  static let rendererVersion = 4
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/nvim")

  let root: URL
  let configurationDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner

  private var configurationURL: URL {
    configurationDirectoryURL.appending(path: "lua/plugins/colorscheme.lua")
  }

  private var importedColorschemeURL: URL {
    configurationDirectoryURL.appending(path: "colors/\(Self.importedColorscheme).lua")
  }

  private var watcherURL: URL {
    configurationDirectoryURL.appending(path: "lua/config/macarchy-theme.lua")
  }

  private var activeThemeURL: URL {
    root.appending(path: "current/\(Self.outputPath)")
  }

  private var themeLink: CanonicalThemeLink {
    CanonicalThemeLink(
      url: configurationDirectoryURL.appending(path: "lua/macarchy/current.lua"),
      destination: root.appending(path: "current/\(Self.outputPath)")
    )
  }

  private var runtime: OrdinaryAdapterRuntime {
    OrdinaryAdapterRuntime(
      adapterID: Self.id,
      requirement: .required,
      preflight: preflight,
      isIntegrationDrift: Self.isIntegrationDrift
    )
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw NeovimAdapterError.controlUnavailable(executableURL)
    }
    try themeLink.validate()
    guard Self.containsIntegrationDirective(in: try readConfiguration()) else {
      throw NeovimAdapterError.missingIntegration(Self.integrationDirective)
    }
    guard
      Self.contains(
        directive: Self.backgroundAwareWatcherDirective,
        in: try readConfiguration(at: watcherURL)
      )
    else {
      throw NeovimAdapterError.missingIntegration(Self.backgroundAwareWatcherDirective)
    }
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
    ] where !Self.contains(directive: directive, in: configuration) {
      throw NeovimAdapterError.missingIntegration(directive)
    }
    let colorscheme = try readConfiguration(at: importedColorschemeURL)
    guard Self.contains(directive: Self.importedColorschemeDirective, in: colorscheme) else {
      throw NeovimAdapterError.missingIntegration(Self.importedColorschemeDirective)
    }
  }

  func inspection(includeRuntimeChecks: Bool = false) -> AdapterInspection {
    do {
      try preflight()
      if includeRuntimeChecks {
        try preflightActiveSupport()
        try validateRuntime()
      }
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message: includeRuntimeChecks
          ? "Neovim validated the active colorscheme and canonical-pointer watcher"
          : "Neovim watches the canonical theme pointer for live colorscheme changes"
      )
    } catch {
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        status: Self.isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
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
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
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
    let generated = try readConfiguration(at: activeThemeURL)
    guard
      Self.contains(
        directive: "colorscheme = \"\(Self.importedColorscheme)\",", in: generated)
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

  private func readConfiguration() throws -> String {
    try readConfiguration(at: configurationURL)
  }

  private func readConfiguration(at url: URL) throws -> String {
    try AdapterConfigurationFile.readUTF8(
      at: url,
      tooLarge: NeovimAdapterError.configurationTooLarge(url),
      unreadable: NeovimAdapterError.cannotReadConfiguration(url)
    )
  }

  package static func containsIntegrationDirective(in text: String) -> Bool {
    contains(directive: integrationDirective, in: text)
  }

  private static func contains(directive: String, in text: String) -> Bool {
    containsExactLine(directive, in: text)
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case is CanonicalThemeLinkError, NeovimAdapterError.missingIntegration:
      true
    default:
      false
    }
  }
}
