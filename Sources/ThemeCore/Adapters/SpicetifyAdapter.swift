import Foundation

enum SpicetifyAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case controlUnavailable(URL)
  case invalidRuntimeEvidence(String)
  case invalidSpotifyVersion(String)
  case invalidVersion(String)
  case invalidConfiguration(URL)
  case processInspectionFailed(String)
  case unsupportedVersion(String)
  case wrongColorScheme(String)
  case wrongTheme(String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Spicetify configuration at \(url.path)"
    case .controlUnavailable(let url):
      "Spicetify is not executable at \(url.path)"
    case .invalidRuntimeEvidence(let reason):
      "Spicetify runtime evidence is invalid: \(reason)"
    case .invalidSpotifyVersion(let value):
      "Spotify bundle version '\(value)' is not parseable"
    case .invalidVersion(let value):
      "Spicetify version '\(value)' is not a parseable X.Y.Z triplet"
    case .invalidConfiguration(let url):
      "Spicetify configuration at \(url.path) must be valid provider INI with one [Setting] table and one current_theme and color_scheme key"
    case .processInspectionFailed(let output):
      output.isEmpty ? "Cannot determine whether Spotify is running" : output
    case .unsupportedVersion(let value):
      "Spicetify \(value) is unsupported; version \(SpicetifyAdapter.minimumVersion) or newer is required"
    case .wrongColorScheme(let expected):
      "Spicetify color_scheme must be \"\(expected)\""
    case .wrongTheme(let expected):
      "Spicetify current_theme must be \"\(expected)\""
    }
  }
}

package struct SpicetifyAdapter: Sendable {
  package static let id = "spicetify"
  package static let outputPath = "generated/spicetify.ini"
  static let rendererVersion = 1
  package static let colorSchemeName = "MacarchyCurrent"
  package static let themeName = "text"
  package static let minimumVersion = "2.44.0"
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/spicetify")
  package static let liveSpotifyBundleURL = URL(filePath: "/Applications/Spotify.app")

  package struct ConfigurationSelection: Equatable, Sendable {
    package let theme: String?
    package let colorScheme: String?
    package let rawTheme: String?
    package let rawColorScheme: String?
  }

  private static let processLookupURL = URL(filePath: "/usr/bin/pgrep")

  let root: URL
  let configurationDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner
  let spicetifyVersionProvider: @Sendable () throws -> String
  let spotifyVersionProvider: @Sendable () throws -> String

  init(
    root: URL,
    configurationDirectoryURL: URL,
    executableURL: URL,
    controlIsAvailable: @escaping @Sendable () -> Bool,
    processRunner: ProcessRunner,
    spicetifyVersionProvider: @escaping @Sendable () throws -> String = {
      SpicetifyAdapter.minimumVersion
    },
    spotifyVersionProvider: @escaping @Sendable () throws -> String = { "1.2.97" }
  ) {
    self.root = root
    self.configurationDirectoryURL = configurationDirectoryURL
    self.executableURL = executableURL
    self.controlIsAvailable = controlIsAvailable
    self.processRunner = processRunner
    self.spicetifyVersionProvider = spicetifyVersionProvider
    self.spotifyVersionProvider = spotifyVersionProvider
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
    _ = try supportedVersion()
    _ = try supportedSpotifyVersion()
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
        requirement: .required,
        message:
          "Spicetify and Spotify are compatible and the generated palette seam is exact"
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
    AdapterReconciliation(id: Self.id, requirement: .required) {
      try SpicetifyLock(root: root).withLock {
        try reconcile()
      }
    }
  }

  private func reconcile() throws -> AdapterOutcome {
    do {
      try preflight()
    } catch {
      return AdapterOutcome(
        status: Self.isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
    }

    let spicetifyVersion = try supportedVersion()
    let spotifyVersion = try supportedSpotifyVersion()
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    guard let colorDigest = manifest.artifacts[Self.outputPath] else {
      throw SpicetifyAdapterError.invalidRuntimeEvidence(
        "the active generation has no \(Self.outputPath) digest"
      )
    }
    let running = try spotifyPIDs() != nil
    let desired = SpicetifyRuntimeEvidence(
      generationID: manifest.generationID,
      colorDigest: colorDigest,
      spicetifyVersion: spicetifyVersion,
      spotifyVersion: spotifyVersion,
      result: running ? .restartRequired : .applied
    )
    if try readRuntimeEvidence() == desired {
      return AdapterOutcome(
        status: desired.result.adapterStatus,
        message: desired.result.message(noChange: true)
      )
    }

    try refresh()
    try writeRuntimeEvidence(desired)
    return AdapterOutcome(status: desired.result.adapterStatus, message: desired.result.message())
  }

  package func refreshRestoredConfiguration(
    clearRuntimeEvidence: Bool
  ) throws -> SpicetifyRuntimeResult {
    try SpicetifyLock(root: root).withLock {
      guard controlIsAvailable() else {
        throw SpicetifyAdapterError.controlUnavailable(executableURL)
      }
      let spicetifyVersion = try supportedVersion()
      let spotifyVersion = try supportedSpotifyVersion()
      let running = try spotifyPIDs() != nil
      try refresh()
      let result: SpicetifyRuntimeResult = running ? .restartRequired : .applied
      if clearRuntimeEvidence {
        try removeRuntimeEvidence()
      } else {
        let manifest = try ReconciliationStatusStore(root: root).activeManifest()
        guard let colorDigest = manifest.artifacts[Self.outputPath] else {
          throw SpicetifyAdapterError.invalidRuntimeEvidence(
            "the active generation has no \(Self.outputPath) digest"
          )
        }
        try writeRuntimeEvidence(
          SpicetifyRuntimeEvidence(
            generationID: manifest.generationID,
            colorDigest: colorDigest,
            spicetifyVersion: spicetifyVersion,
            spotifyVersion: spotifyVersion,
            result: result
          )
        )
      }
      return result
    }
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

  package func supportedVersion() throws -> String {
    let value = try spicetifyVersionProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = Self.parseTriplet(value) else {
      throw SpicetifyAdapterError.invalidVersion(value)
    }
    guard parsed >= Self.parseTriplet(Self.minimumVersion)! else {
      throw SpicetifyAdapterError.unsupportedVersion(value)
    }
    return parsed.description
  }

  package func supportedSpotifyVersion() throws -> String {
    let value = try spotifyVersionProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.parseSpotifyVersion(value) != nil else {
      throw SpicetifyAdapterError.invalidSpotifyVersion(value)
    }
    return value
  }

  package static func commandVersion(
    executableURL: URL = liveExecutableURL,
    processRunner: ProcessRunner = .live
  ) throws -> String {
    let result = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: ["--version"], timeout: 2)
    )
    guard result.terminationStatus == 0 else {
      throw SpicetifyAdapterError.invalidVersion(result.output)
    }
    return result.output
  }

  package static func spotifyBundleVersion(
    bundleURL: URL = liveSpotifyBundleURL
  ) throws -> String {
    let plistURL = bundleURL.appending(path: "Contents/Info.plist")
    let data = try BoundedRegularFile.read(at: plistURL, maximumSize: 1_048_576).data
    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let dictionary = value as? [String: Any],
      let version = dictionary["CFBundleShortVersionString"] as? String
        ?? dictionary["CFBundleVersion"] as? String,
      parseSpotifyVersion(version) != nil
    else { throw SpicetifyAdapterError.invalidSpotifyVersion(plistURL.path) }
    return version
  }

  private func refresh() throws {
    let result = try processRunner.run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: ["--no-restart", "refresh"],
        timeout: 30
      )
    )
    guard result.terminationStatus == 0 else {
      throw SpicetifyAdapterError.invalidRuntimeEvidence(
        result.output.isEmpty
          ? "refresh exited with status \(result.terminationStatus)" : result.output
      )
    }
  }

  private var runtimeEvidenceURL: URL {
    root.appending(path: "state/spicetify.json")
  }

  private func readRuntimeEvidence() throws -> SpicetifyRuntimeEvidence? {
    do {
      let data = try BoundedRegularFile.read(at: runtimeEvidenceURL, maximumSize: 16_384).data
      let evidence = try JSONDecoder().decode(SpicetifyRuntimeEvidence.self, from: data)
      guard evidence.hasValidShape else {
        throw SpicetifyAdapterError.invalidRuntimeEvidence("receipt has an invalid shape")
      }
      return evidence
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT) {
      return nil
    } catch let error as SpicetifyAdapterError {
      throw error
    } catch {
      throw SpicetifyAdapterError.invalidRuntimeEvidence(String(describing: error))
    }
  }

  private func writeRuntimeEvidence(_ evidence: SpicetifyRuntimeEvidence) throws {
    let directory = runtimeEvidenceURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(evidence)
    data.append(0x0a)
    try data.write(to: runtimeEvidenceURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: runtimeEvidenceURL.path)
  }

  private func removeRuntimeEvidence() throws {
    do { try FileManager.default.removeItem(at: runtimeEvidenceURL) } catch CocoaError
      .fileNoSuchFile
    { return }
  }

  private static func parseSpotifyVersion(_ value: String) -> [Int]? {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    let parsed = components.compactMap { Int($0) }
    guard components.count >= 3,
      components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
      parsed.count == components.count
    else { return nil }
    return parsed
  }

  private static func parseTriplet(_ value: String) -> SpicetifyVersion? {
    let candidate = value.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? value
    let normalized = candidate.hasPrefix("v") ? String(candidate.dropFirst()) : candidate
    let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2])
    else { return nil }
    return SpicetifyVersion(major: major, minor: minor, patch: patch)
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

private struct SpicetifyVersion: Comparable {
  let major: Int
  let minor: Int
  let patch: Int

  var description: String { "\(major).\(minor).\(patch)" }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    return lhs.patch < rhs.patch
  }
}

package enum SpicetifyRuntimeResult: String, Codable {
  case applied
  case restartRequired = "restart_required"

  package var adapterStatus: AdapterStatus {
    self == .applied ? .applied : .restartRequired
  }

  package func message(noChange: Bool = false) -> String {
    switch self {
    case .applied:
      noChange
        ? "Spicetify runtime evidence already matches; Spotify will use the palette on next launch"
        : "Spicetify refreshed the palette; Spotify will use it on next launch"
    case .restartRequired:
      noChange
        ? "Spicetify runtime evidence already matches; restart running Spotify manually to repaint"
        : "Spicetify refreshed without restarting Spotify; restart the running client manually to repaint"
    }
  }
}

private struct SpicetifyRuntimeEvidence: Codable, Equatable {
  let schemaVersion = 1
  let generationID: String
  let colorDigest: String
  let spicetifyVersion: String
  let spotifyVersion: String
  let result: SpicetifyRuntimeResult

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case colorDigest = "color_digest"
    case spicetifyVersion = "spicetify_version"
    case spotifyVersion = "spotify_version"
    case result
  }

  var hasValidShape: Bool {
    schemaVersion == 1 && isGenerationID(generationID) && isSHA256Digest(colorDigest)
      && !spicetifyVersion.isEmpty && !spotifyVersion.isEmpty
  }
}
