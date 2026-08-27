import Foundation

enum SpicetifyAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case controlUnavailable(URL)
  case invalidConfiguration(URL)
  case processInspectionFailed(String)
  case wrongColorScheme(String)
  case wrongTheme(String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Spicetify configuration at \(url.path)"
    case .controlUnavailable(let url):
      "Spicetify is not executable at \(url.path)"
    case .invalidConfiguration(let url):
      "Spicetify configuration at \(url.path) must be valid provider INI with one [Setting] table and one current_theme and color_scheme key"
    case .processInspectionFailed(let output):
      output.isEmpty ? "Cannot determine whether Spotify is running" : output
    case .wrongColorScheme(let expected):
      "Spicetify color_scheme must be \"\(expected)\""
    case .wrongTheme(let expected):
      "Spicetify current_theme must be \"\(expected)\""
    }
  }
}

package struct SpicetifyAdapter: Sendable {
  static let id = "spicetify"
  package static let outputPath = "generated/spicetify.ini"
  static let rendererVersion = 1
  package static let colorSchemeName = "MacarchyCurrent"
  package static let themeName = "text"
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/spicetify")

  package struct ConfigurationSelection: Equatable, Sendable {
    package let theme: String?
    package let colorScheme: String?
    package let rawTheme: String?
    package let rawColorScheme: String?
  }

  private static let applicationLauncherURL = URL(filePath: "/usr/bin/open")
  private static let processLookupURL = URL(filePath: "/usr/bin/pgrep")
  private static let processCheckAttempts = 20

  let root: URL
  let configurationDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner
  let waitBetweenProcessChecks: @Sendable () async throws -> Void

  init(
    root: URL,
    configurationDirectoryURL: URL,
    executableURL: URL,
    controlIsAvailable: @escaping @Sendable () -> Bool,
    processRunner: ProcessRunner,
    waitBetweenProcessChecks: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(250))
    }
  ) {
    self.root = root
    self.configurationDirectoryURL = configurationDirectoryURL
    self.executableURL = executableURL
    self.controlIsAvailable = controlIsAvailable
    self.processRunner = processRunner
    self.waitBetweenProcessChecks = waitBetweenProcessChecks
  }

  private var configurationURL: URL {
    configurationDirectoryURL.appending(path: "config-xpui.ini")
  }

  private var colorSchemeLink: CanonicalThemeLink {
    CanonicalThemeLink(
      url: configurationDirectoryURL.appending(path: "Themes/\(Self.themeName)/color.ini"),
      destination: root.appending(path: "current/\(Self.outputPath)")
    )
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw SpicetifyAdapterError.controlUnavailable(executableURL)
    }
    try colorSchemeLink.validate()
    let selection = try selectedTheme()
    guard selection.theme == Self.themeName else {
      throw SpicetifyAdapterError.wrongTheme(Self.themeName)
    }
    guard selection.colorScheme == Self.colorSchemeName else {
      throw SpicetifyAdapterError.wrongColorScheme(Self.colorSchemeName)
    }
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .optional,
        message:
          "Spicetify uses the generated palette; applying it restarts a running Spotify client"
      )
    } catch {
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .optional,
        status: Self.isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .optional) {
      try await SpicetifyLock(root: root).withLock {
        try await reconcile()
      }
    }
  }

  private func reconcile() async throws -> AdapterOutcome {
    do {
      try preflight()
    } catch {
      return AdapterOutcome(
        status: Self.isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
    }

    let runningPIDs = try spotifyPIDs()

    let refresh = try processRunner.run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: ["--no-restart", "refresh"],
        timeout: 30
      )
    )
    guard refresh.terminationStatus == 0 else {
      return AdapterOutcome(
        status: .failed,
        message: refresh.output.isEmpty
          ? "Spicetify refresh exited with status \(refresh.terminationStatus)"
          : refresh.output
      )
    }

    guard let runningPIDs else {
      return AdapterOutcome(
        status: .applied,
        message: "Spotify will use the active palette on next launch"
      )
    }

    let restart = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: ["restart"], timeout: 5)
    )
    guard restart.terminationStatus == 0 else {
      return AdapterOutcome(
        status: .failed,
        message: restart.output.isEmpty
          ? "Spicetify could not restart Spotify"
          : restart.output
      )
    }
    let restartedPIDs = try await waitForReplacement(of: runningPIDs)
    if restartedPIDs != nil {
      return AdapterOutcome(
        status: .applied,
        message: "Spicetify refreshed the active palette and restarted Spotify"
      )
    }

    let launch = try processRunner.run(
      ProcessRequest(
        executableURL: Self.applicationLauncherURL,
        arguments: ["-g", "-a", "Spotify"],
        timeout: 2
      )
    )
    guard launch.terminationStatus == 0 else {
      return AdapterOutcome(
        status: .failed,
        message: launch.output.isEmpty ? "Cannot relaunch Spotify" : launch.output
      )
    }
    guard try await waitForSpotifyLaunch() else {
      return AdapterOutcome(
        status: .failed,
        message: "Spicetify refreshed the palette, but Spotify did not relaunch"
      )
    }
    return AdapterOutcome(
      status: .applied,
      message: "Spicetify refreshed the active palette and restarted Spotify"
    )
  }

  private func waitForReplacement(of oldPIDs: Set<Int32>) async throws -> Set<Int32>? {
    var replacementObserved = false
    for attempt in 0..<Self.processCheckAttempts {
      guard let currentPIDs = try spotifyPIDs() else { return nil }
      if currentPIDs.isDisjoint(with: oldPIDs) {
        if replacementObserved { return currentPIDs }
        replacementObserved = true
      } else {
        replacementObserved = false
      }
      if attempt + 1 < Self.processCheckAttempts { try await waitBetweenProcessChecks() }
    }
    if replacementObserved { return nil }
    throw SpicetifyAdapterError.processInspectionFailed(
      "Spicetify did not replace the running Spotify client"
    )
  }

  private func waitForSpotifyLaunch() async throws -> Bool {
    var processObserved = false
    for attempt in 0..<Self.processCheckAttempts {
      if try spotifyPIDs() != nil {
        if processObserved { return true }
        processObserved = true
      } else {
        processObserved = false
      }
      if attempt + 1 < Self.processCheckAttempts { try await waitBetweenProcessChecks() }
    }
    return false
  }

  static func render(package: ThemePackage) -> String {
    let semantic = package.semantic
    return """
      ; Generated by Macarchy. Do not edit.
      [\(colorSchemeName)]
      text = \(color(semantic.text))
      subtext = \(color(semantic.mutedText))
      main = \(color(semantic.background))
      main-elevated = \(color(semantic.surface))
      highlight = \(color(semantic.selection))
      highlight-elevated = \(color(semantic.overlay))
      sidebar = \(color(semantic.background))
      player = \(color(semantic.surface))
      card = \(color(semantic.surface))
      shadow = \(color(semantic.background))
      selected-row = \(color(semantic.selection))
      button = \(color(semantic.accent))
      button-active = \(color(semantic.accent))
      button-disabled = \(color(semantic.mutedText))
      tab-active = \(color(semantic.selection))
      notification = \(color(semantic.info))
      notification-error = \(color(semantic.error))
      misc = \(color(semantic.mutedText))
      accent = \(color(semantic.accent))
      accent-active = \(color(semantic.accent))
      accent-inactive = \(color(semantic.background))
      banner = \(color(semantic.accent))
      border-active = \(color(semantic.accent))
      border-inactive = \(color(semantic.border))
      header = \(color(semantic.overlay))

      """
  }

  private func selectedTheme() throws -> (theme: String, colorScheme: String) {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: configurationURL.resolvingSymlinksInPath()).data
    } catch {
      throw SpicetifyAdapterError.cannotReadConfiguration(configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw SpicetifyAdapterError.cannotReadConfiguration(configurationURL)
    }

    let selection = try Self.configurationSelection(
      in: configuration,
      at: configurationURL
    )
    guard let theme = selection.theme, let colorScheme = selection.colorScheme else {
      throw SpicetifyAdapterError.invalidConfiguration(configurationURL)
    }
    return (theme, colorScheme)
  }

  package static func configurationSelection(
    in configuration: String,
    at configurationURL: URL
  ) throws -> ConfigurationSelection {
    var settingTables = 0
    var sectionName = "DEFAULT"
    var themes = [String]()
    var colorSchemes = [String]()
    var rawThemes = [String]()
    var rawColorSchemes = [String]()
    for (index, rawLine) in configuration.components(separatedBy: "\n").enumerated() {
      var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if index == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
      guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
      if line.hasPrefix("[") {
        guard let closingBracket = line.lastIndex(of: "]") else {
          throw SpicetifyAdapterError.invalidConfiguration(configurationURL)
        }
        sectionName = String(line[line.index(after: line.startIndex)..<closingBracket])
        guard !sectionName.isEmpty else {
          throw SpicetifyAdapterError.invalidConfiguration(configurationURL)
        }
        if sectionName == "Setting" { settingTables += 1 }
        continue
      }
      guard let assignment = configurationAssignment(line) else {
        throw SpicetifyAdapterError.invalidConfiguration(configurationURL)
      }
      guard sectionName == "Setting" else { continue }
      switch assignment.key {
      case "current_theme":
        themes.append(assignment.value)
        rawThemes.append(assignment.rawValue)
      case "color_scheme":
        colorSchemes.append(assignment.value)
        rawColorSchemes.append(assignment.rawValue)
      default: continue
      }
    }
    guard settingTables == 1, themes.count <= 1, colorSchemes.count <= 1 else {
      throw SpicetifyAdapterError.invalidConfiguration(configurationURL)
    }
    return ConfigurationSelection(
      theme: themes.first,
      colorScheme: colorSchemes.first,
      rawTheme: rawThemes.first,
      rawColorScheme: rawColorSchemes.first
    )
  }

  private static func configurationAssignment(
    _ line: String
  ) -> (key: String, value: String, rawValue: String)? {
    let delimiter: String.Index
    let key: String
    if line.hasPrefix("\"\"\"") || line.hasPrefix("\"") || line.hasPrefix("`") {
      let quote = line.hasPrefix("\"\"\"") ? "\"\"\"" : String(line.first!)
      let contentStart = line.index(line.startIndex, offsetBy: quote.count)
      guard let closingRange = line.range(of: quote, range: contentStart..<line.endIndex) else {
        return nil
      }
      let remainder = line[closingRange.upperBound...]
      guard let relativeDelimiter = remainder.firstIndex(where: { $0 == "=" || $0 == ":" })
      else { return nil }
      delimiter = relativeDelimiter
      key = line[contentStart..<closingRange.lowerBound]
        .trimmingCharacters(in: .whitespaces)
    } else {
      guard let firstDelimiter = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
        return nil
      }
      delimiter = firstDelimiter
      key = line[..<delimiter].trimmingCharacters(in: .whitespaces)
    }
    guard !key.isEmpty else { return nil }
    let rawValue = line[line.index(after: delimiter)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = providerConfigurationValue(rawValue) else { return nil }
    return (key, value, rawValue)
  }

  private static func providerConfigurationValue(_ rawValue: String) -> String? {
    if rawValue.hasPrefix("\"\"\"") || rawValue.hasPrefix("`") {
      let quote = rawValue.hasPrefix("\"\"\"") ? "\"\"\"" : "`"
      guard rawValue.count >= quote.count * 2, rawValue.hasSuffix(quote) else { return nil }
      return String(rawValue.dropFirst(quote.count).dropLast(quote.count))
    }
    for quote in ["'", "\""] where rawValue.hasPrefix(quote) && rawValue.hasSuffix(quote) {
      let middle = rawValue.dropFirst().dropLast()
      if !middle.contains(quote) { return String(middle) }
    }
    return rawValue
  }

  private func spotifyPIDs() throws -> Set<Int32>? {
    let process = try processRunner.run(
      ProcessRequest(
        executableURL: Self.processLookupURL,
        arguments: ["-x", "Spotify"],
        timeout: 1
      )
    )
    if process.terminationStatus == 1 { return nil }
    guard process.terminationStatus == 0 else {
      throw SpicetifyAdapterError.processInspectionFailed(process.output)
    }
    let lines = process.output.split(whereSeparator: \.isNewline)
    let pids = lines.compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    guard !pids.isEmpty, pids.count == lines.count else {
      throw SpicetifyAdapterError.processInspectionFailed(process.output)
    }
    return Set(pids)
  }

  private static func color(_ color: SRGBColor) -> Substring {
    color.rawValue.dropFirst()
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case is CanonicalThemeLinkError, SpicetifyAdapterError.wrongColorScheme,
      SpicetifyAdapterError.wrongTheme:
      true
    default:
      false
    }
  }
}
