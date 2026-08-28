import Foundation
import TOMLDecoder

enum HerdrAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case cannotReadDesiredTheme(URL)
  case cannotReadOwnership(URL)
  case controlUnavailable(URL)
  case invalidThemeConfiguration
  case invalidGeneratedTheme
  case invalidOwnership
  case automaticThemeSwitching
  case unsupportedTheme(String)
  case ownershipConflict(String)
  case backupUnavailable(URL)
  case wrongThemeSelection(expected: String, actual: String?)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Herdr configuration at \(url.path)"
    case .cannotReadDesiredTheme(let url):
      "Cannot read generated Herdr theme at \(url.path)"
    case .cannotReadOwnership(let url):
      "Cannot read Herdr ownership evidence at \(url.path)"
    case .controlUnavailable(let url):
      "Herdr is not executable at \(url.path)"
    case .invalidThemeConfiguration:
      "Herdr configuration must contain one canonical [theme] table, at most one canonical [theme.custom] table, and editable owned keys"
    case .invalidGeneratedTheme:
      "Generated Herdr theme is invalid"
    case .invalidOwnership:
      "Herdr ownership evidence is invalid"
    case .automaticThemeSwitching:
      "Herdr theme.auto_switch must remain false while Macarchy owns the theme selector"
    case .unsupportedTheme(let name):
      "Herdr 0.8 theme \"\(name)\" is not allowlisted"
    case .ownershipConflict(let reason):
      "Herdr theme ownership conflict: \(reason)"
    case .backupUnavailable(let url):
      "Herdr's first-import backup is missing or does not match ownership evidence at \(url.path)"
    case .wrongThemeSelection(let expected, let actual):
      "Herdr theme is \(actual.map { "\"\($0)\"" } ?? "unset"); expected \"\(expected)\""
    }
  }
}

package struct GeneratedHerdrTheme: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let name: String
  let custom: [String: String]

  init(name: String, custom: [String: String] = [:]) {
    schemaVersion = Self.currentSchemaVersion
    self.name = name
    self.custom = custom
  }

  func validated() throws -> Self {
    guard schemaVersion == Self.currentSchemaVersion,
      HerdrAdapter.supportedThemes.contains(name),
      custom.isEmpty || Set(custom.keys) == HerdrAdapter.customKeySet,
      custom.values.allSatisfy({ SRGBColor(rawValue: $0) != nil })
    else {
      throw HerdrAdapterError.invalidGeneratedTheme
    }
    return self
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case name, custom
  }
}

package enum HerdrMutationCheckpoint: Equatable, Sendable {
  case ownershipPrepared
  case configurationWritten
}

package struct HerdrAdapter: Sendable {
  static let id = "herdr"
  static let outputPath = "generated/herdr.txt"
  static let rendererVersion = 3
  static var liveExecutableURL: URL {
    preferredExternalOrHomebrewExecutableURL(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      externalRelativePath: ".local/bin/herdr",
      homebrewExecutableName: "herdr"
    )
  }

  static let supportedThemes = Set([
    "catppuccin", "tokyo-night", "kanagawa",
  ])
  static let customKeys = [
    "accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1",
    "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach",
  ]
  static let customKeySet = Set(customKeys)
  private static let importedBaseTheme = "catppuccin"

  let root: URL
  let configurationURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner
  var faultInjector: @Sendable (HerdrMutationCheckpoint) throws -> Void = { _ in }

  private var desiredThemeURL: URL {
    root.appending(path: "current/\(Self.outputPath)")
  }

  private var backupURL: URL {
    root.appending(path: "state/adapters/herdr-config.toml.backup")
  }

  private var ownershipURL: URL {
    root.appending(path: "state/adapters/herdr-theme-ownership.json")
  }

  func preflight() throws {
    _ = try validatedConfiguration()
  }

  func preflight(package: ThemePackage) throws {
    let parsed = try validatedConfiguration()
    _ = try Self.desiredTheme(for: package)
    try verifyTransitionPossible(parsed)
  }

  func inspection() -> AdapterInspection {
    // Keep inspection nonmutating; an in-flight ownership record is visible as drift.
    do {
      let parsed = try validatedConfiguration()
      guard let desired = try currentDesiredTheme() else {
        return AdapterInspection(
          adapterID: Self.id,
          requirement: .required,
          message: "Herdr configuration is ready for an active theme"
        )
      }
      try verifyCurrentTheme(desired, parsed: parsed)
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message: desired.custom.isEmpty
          ? "Herdr uses the active mapped theme and supports live config reload"
          : "Herdr uses the complete active custom palette and supports live config reload"
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
      do {
        try preflight()
      } catch {
        return AdapterOutcome(
          status: Self.isIntegrationDrift(error) ? .drifted : .failed,
          message: String(describing: error)
        )
      }

      do {
        try ActivationLock(root: root).withLock {
          guard let desired = try currentDesiredTheme() else {
            throw HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
          }
          try transition(to: desired)
        }
      } catch {
        return AdapterOutcome(
          status: Self.isIntegrationDrift(error) ? .drifted : .failed,
          message: String(describing: error)
        )
      }

      let reload = try processRunner.run(
        ProcessRequest(
          executableURL: executableURL,
          arguments: ["server", "reload-config"],
          timeout: 2
        )
      )
      if reload.terminationStatus == 0 {
        return AdapterOutcome(status: .applied, message: "Herdr reloaded the active theme")
      }

      let status = try processRunner.run(
        ProcessRequest(executableURL: executableURL, arguments: ["status", "server"], timeout: 1)
      )
      if status.terminationStatus == 0,
        status.output.split(separator: "\n").contains("status: stopped")
      {
        return AdapterOutcome(
          status: .applied,
          message: "Herdr will use the active theme on next launch"
        )
      }
      return AdapterOutcome(
        status: .failed,
        message: reload.output.isEmpty ? "Herdr rejected its config reload" : reload.output
      )
    }
  }

  static func render(package: ThemePackage) throws -> String {
    let desired = try desiredTheme(for: package)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(desired)
    data.append(0x0a)
    return String(decoding: data, as: UTF8.self)
  }

  package static func validateConfiguration(_ configuration: String) throws {
    _ = try parseConfiguration(configuration)
  }

  private static func desiredTheme(for package: ThemePackage) throws -> GeneratedHerdrTheme {
    if let mapping = package.mappings[id] {
      guard supportedThemes.contains(mapping) else {
        throw HerdrAdapterError.unsupportedTheme(mapping)
      }
      return GeneratedHerdrTheme(name: mapping)
    }

    let semantic = package.semantic
    let terminal = package.terminal
    return GeneratedHerdrTheme(
      name: importedBaseTheme,
      custom: [
        "accent": semantic.accent.rawValue,
        "panel_bg": semantic.background.rawValue,
        "surface0": semantic.surface.rawValue,
        "surface1": semantic.overlay.rawValue,
        "surface_dim": semantic.background.rawValue,
        "overlay0": semantic.border.rawValue,
        "overlay1": semantic.mutedText.rawValue,
        "text": semantic.text.rawValue,
        "subtext0": semantic.mutedText.rawValue,
        "mauve": terminal.ansi[5].rawValue,
        "green": terminal.ansi[2].rawValue,
        "yellow": terminal.ansi[3].rawValue,
        "red": terminal.ansi[1].rawValue,
        "blue": terminal.ansi[4].rawValue,
        "teal": terminal.ansi[6].rawValue,
        "peach": semantic.warning.rawValue,
      ]
    )
  }

  private func currentDesiredTheme() throws -> GeneratedHerdrTheme? {
    guard FileManager.default.fileExists(atPath: root.appending(path: "current").path) else {
      return nil
    }
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: desiredThemeURL.resolvingSymlinksInPath()).data
    } catch {
      throw HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
    }

    do {
      return try Self.decodeGeneratedTheme(
        data,
        rendererVersion: manifest.rendererVersions[Self.id, default: 0]
      )
    } catch {
      throw HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
    }
  }

  package static func decodeGeneratedTheme(
    _ data: Data,
    rendererVersion: Int
  ) throws -> GeneratedHerdrTheme {
    if rendererVersion == 2 {
      guard
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        Self.supportedThemes.contains(value)
      else {
        throw HerdrAdapterError.invalidGeneratedTheme
      }
      return GeneratedHerdrTheme(name: value)
    }

    guard rendererVersion == Self.rendererVersion,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["schema_version", "name", "custom"])
    else {
      throw HerdrAdapterError.invalidGeneratedTheme
    }
    return try JSONDecoder().decode(GeneratedHerdrTheme.self, from: data).validated()
  }

  private func readConfiguration() throws -> (data: Data, text: String) {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: configurationURL.resolvingSymlinksInPath()).data
    } catch {
      throw HerdrAdapterError.cannotReadConfiguration(configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw HerdrAdapterError.cannotReadConfiguration(configurationURL)
    }
    return (data, configuration)
  }

  private func validatedConfiguration() throws -> ParsedConfiguration {
    guard controlIsAvailable() else {
      throw HerdrAdapterError.controlUnavailable(executableURL)
    }
    let configuration = try readConfiguration()
    return try Self.parseConfiguration(configuration.text)
  }

  private func verifyTransitionPossible(_ parsed: ParsedConfiguration) throws {
    guard let state = try readOwnership() else {
      guard parsed.custom.isEmpty else {
        throw HerdrAdapterError.ownershipConflict(
          "pre-existing [theme.custom] colors are not Macarchy-managed"
        )
      }
      return
    }

    try verifyBackup(state.backupDigest)
    if let before = state.before {
      guard parsed.surface == before || parsed.surface == state.desired else {
        throw HerdrAdapterError.ownershipConflict(
          "interrupted transaction no longer matches its before or desired state"
        )
      }
    } else {
      guard parsed.surface == state.desired else {
        throw HerdrAdapterError.ownershipConflict("managed selector or custom colors drifted")
      }
    }
  }

  private func verifyCurrentTheme(
    _ desired: GeneratedHerdrTheme,
    parsed: ParsedConfiguration
  ) throws {
    if let state = try readOwnership() {
      guard state.before == nil else {
        throw HerdrAdapterError.ownershipConflict(
          "an interrupted theme transaction must be reconciled"
        )
      }
      guard parsed.surface == state.desired else {
        throw HerdrAdapterError.ownershipConflict("managed selector or custom colors drifted")
      }
      try verifyBackup(state.backupDigest)
      guard state.desired.matches(desired) else {
        throw HerdrAdapterError.ownershipConflict(
          "managed values do not match the active generation"
        )
      }
      return
    }

    guard parsed.custom.isEmpty else {
      throw HerdrAdapterError.ownershipConflict(
        "pre-existing [theme.custom] colors are not Macarchy-managed"
      )
    }
    guard parsed.selection == desired.name else {
      throw HerdrAdapterError.wrongThemeSelection(
        expected: desired.name,
        actual: parsed.selection
      )
    }
    guard desired.custom.isEmpty else {
      throw HerdrAdapterError.ownershipConflict("the active custom palette has not been adopted")
    }
  }

  private func transition(to desired: GeneratedHerdrTheme) throws {
    var configuration = try readConfiguration()
    var parsed = try Self.parseConfiguration(configuration.text)
    var state = try readOwnership()

    if let existing = state {
      if existing.before != nil {
        try ensureBackup(existing.backupDigest, currentData: configuration.data)
      } else {
        try verifyBackup(existing.backupDigest)
      }
      if let before = existing.before {
        if parsed.surface == existing.desired {
          let committed = existing.committed()
          try writeOwnership(committed)
          state = committed
        } else if parsed.surface != before {
          throw HerdrAdapterError.ownershipConflict(
            "interrupted transaction no longer matches its before or desired state"
          )
        }
      } else {
        guard parsed.surface == existing.desired else {
          throw HerdrAdapterError.ownershipConflict("managed selector or custom colors drifted")
        }
      }
    } else {
      guard parsed.custom.isEmpty else {
        throw HerdrAdapterError.ownershipConflict(
          "pre-existing [theme.custom] colors are not Macarchy-managed"
        )
      }
      if desired.custom.isEmpty {
        let target = ManagedSurface(
          name: desired.name,
          custom: [:]
        )
        guard parsed.surface != target else { return }
        let updated = try Self.replacingManagedSurface(
          in: configuration.text,
          parsed: parsed,
          with: target
        )
        try FileManager.default.createDirectory(
          at: backupURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data(configuration.text.utf8).write(to: backupURL, options: .atomic)
        try writeConfiguration(updated)
        return
      }
    }

    let target = ManagedSurface(
      name: desired.name,
      custom: desired.custom
    )
    if state?.before == nil, parsed.surface == target { return }

    let backupDigest: String
    if let state {
      backupDigest = state.backupDigest
    } else {
      backupDigest = sha256Digest(configuration.data)
    }
    let pending = HerdrOwnershipState(
      before: parsed.surface,
      desired: target,
      backupDigest: backupDigest
    )
    try writeOwnership(pending)
    try faultInjector(.ownershipPrepared)
    try ensureBackup(backupDigest, currentData: configuration.data)

    let updated = try Self.replacingManagedSurface(
      in: configuration.text,
      parsed: parsed,
      with: target
    )
    let verified = try Self.parseConfiguration(updated)
    guard verified.surface == target else {
      throw HerdrAdapterError.invalidThemeConfiguration
    }
    try writeConfiguration(updated)
    try faultInjector(.configurationWritten)
    try writeOwnership(pending.committed())

    configuration = try readConfiguration()
    parsed = try Self.parseConfiguration(configuration.text)
    guard parsed.surface == target else {
      throw HerdrAdapterError.ownershipConflict("the published config does not match ownership")
    }
  }

  private func writeConfiguration(_ configuration: String) throws {
    let target = configurationURL.resolvingSymlinksInPath()
    try Data(configuration.utf8).write(to: target, options: .atomic)
  }

  private func ensureBackup(_ digest: String, currentData: Data) throws {
    if backupMatches(digest) { return }
    guard sha256Digest(currentData) == digest else {
      throw HerdrAdapterError.backupUnavailable(backupURL)
    }
    try FileManager.default.createDirectory(
      at: backupURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try currentData.write(to: backupURL, options: .atomic)
  }

  private func verifyBackup(_ digest: String) throws {
    guard backupMatches(digest) else {
      throw HerdrAdapterError.backupUnavailable(backupURL)
    }
  }

  private func backupMatches(_ digest: String) -> Bool {
    guard let backup = try? BoundedRegularFile.read(at: backupURL) else { return false }
    return sha256Digest(backup.data) == digest
  }

  private struct ManagedSurface: Codable, Equatable, Sendable {
    let name: String?
    let custom: [String: String]

    func matches(_ desired: GeneratedHerdrTheme) -> Bool {
      name == desired.name && custom == desired.custom
    }

  }

  private struct HerdrOwnershipState: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let before: ManagedSurface?
    let desired: ManagedSurface
    let backupDigest: String

    init(
      before: ManagedSurface?,
      desired: ManagedSurface,
      backupDigest: String
    ) {
      schemaVersion = Self.currentSchemaVersion
      self.before = before
      self.desired = desired
      self.backupDigest = backupDigest
    }

    func validated() throws -> Self {
      guard schemaVersion == Self.currentSchemaVersion,
        backupDigest.count == 71,
        backupDigest.hasPrefix("sha256:"),
        backupDigest.dropFirst(7).allSatisfy({ $0.isHexDigit && $0.isASCII }),
        desired.name.map(HerdrAdapter.supportedThemes.contains) == true,
        desired.custom.isEmpty || Set(desired.custom.keys) == HerdrAdapter.customKeySet,
        desired.custom.values.allSatisfy({ SRGBColor(rawValue: $0) != nil }),
        before.map({
          $0.custom.isEmpty || Set($0.custom.keys) == HerdrAdapter.customKeySet
        }) != false,
        before?.custom.values.allSatisfy({ SRGBColor(rawValue: $0) != nil }) != false
      else {
        throw HerdrAdapterError.invalidOwnership
      }
      return self
    }

    func committed() -> Self {
      HerdrOwnershipState(
        before: nil,
        desired: desired,
        backupDigest: backupDigest
      )
    }

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case before, desired
      case backupDigest = "backup_digest"
    }
  }

  private func readOwnership() throws -> HerdrOwnershipState? {
    guard FileManager.default.fileExists(atPath: ownershipURL.path) else { return nil }
    do {
      let data = try BoundedRegularFile.read(at: ownershipURL).data
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw HerdrAdapterError.invalidOwnership
      }
      let hasBefore = object["before"] != nil
      let expected =
        hasBefore
        ? Set(["schema_version", "before", "desired", "backup_digest"])
        : Set(["schema_version", "desired", "backup_digest"])
      guard Set(object.keys) == expected,
        Self.hasExactSurfaceShape(object["desired"], requiresName: true),
        !hasBefore || Self.hasExactSurfaceShape(object["before"], requiresName: false)
      else {
        throw HerdrAdapterError.invalidOwnership
      }
      return try JSONDecoder().decode(HerdrOwnershipState.self, from: data).validated()
    } catch let error as HerdrAdapterError {
      throw error
    } catch {
      throw HerdrAdapterError.cannotReadOwnership(ownershipURL)
    }
  }

  private static func hasExactSurfaceShape(_ value: Any?, requiresName: Bool) -> Bool {
    guard let surface = value as? [String: Any] else { return false }
    let keys = Set(surface.keys)
    let complete = Set(["name", "custom"])
    return requiresName
      ? keys == complete
      : keys == complete || keys == complete.subtracting(["name"])
  }

  private func writeOwnership(_ state: HerdrOwnershipState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(state)
    data.append(0x0a)
    try FileManager.default.createDirectory(
      at: ownershipURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: ownershipURL, options: .atomic)
  }

  private struct ParsedConfiguration {
    let themeHeaderIndex: Int
    let customHeaderIndex: Int?
    let nameIndex: Int?
    let customIndices: [String: Int]
    let selection: String?
    let custom: [String: String]

    var surface: ManagedSurface {
      ManagedSurface(
        name: selection,
        custom: custom
      )
    }
  }

  private struct ConfigurationDocument: Decodable {
    let theme: ThemeConfiguration
  }

  private struct ThemeConfiguration: Decodable {
    let name: String?
    let autoSwitch: Bool?
    let custom: [String: String]?

    enum CodingKeys: String, CodingKey {
      case name, custom
      case autoSwitch = "auto_switch"
    }
  }

  private enum ConfigurationSection {
    case theme
    case custom
    case other
  }

  private static func parseConfiguration(_ configuration: String) throws -> ParsedConfiguration {
    let document: ConfigurationDocument
    do {
      document = try TOMLDecoder().decode(ConfigurationDocument.self, from: configuration)
    } catch {
      throw HerdrAdapterError.invalidThemeConfiguration
    }
    guard document.theme.autoSwitch != true else {
      throw HerdrAdapterError.automaticThemeSwitching
    }

    let lines = configuration.components(separatedBy: "\n")
    var arrayDepth = 0
    var multilineQuote: TOMLMultilineQuote?
    var section = ConfigurationSection.other
    var themeHeaders = [Int]()
    var customHeaders = [Int]()
    var nameIndices = [Int]()
    var customIndices = [String: Int]()
    var customValues = [String: String]()

    for (index, rawLine) in lines.enumerated() {
      let startsAtTopLevel = arrayDepth == 0 && multilineQuote == nil
      let line = scanTOMLLine(
        rawLine,
        arrayDepth: &arrayDepth,
        multilineQuote: &multilineQuote
      ).trimmingCharacters(in: .whitespacesAndNewlines)

      if startsAtTopLevel, line.hasPrefix("[") {
        switch line {
        case "[theme]":
          section = .theme
          themeHeaders.append(index)
        case "[theme.custom]":
          section = .custom
          customHeaders.append(index)
        default:
          section = .other
        }
        continue
      }
      guard startsAtTopLevel, !line.isEmpty else { continue }

      switch section {
      case .theme:
        let parts = line.split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.first == "name" {
          guard parseEditableStringAssignment(rawLine, expectedKey: "name") != nil else {
            throw HerdrAdapterError.invalidThemeConfiguration
          }
          nameIndices.append(index)
        }
      case .custom:
        guard let assignment = parseEditableStringAssignment(rawLine),
          customKeySet.contains(assignment.key),
          SRGBColor(rawValue: assignment.value) != nil,
          customIndices[assignment.key] == nil
        else {
          throw HerdrAdapterError.invalidThemeConfiguration
        }
        customIndices[assignment.key] = index
        customValues[assignment.key] = assignment.value.lowercased()
      case .other:
        continue
      }
    }

    guard themeHeaders.count == 1,
      customHeaders.count <= 1,
      nameIndices.count <= 1,
      document.theme.name == nil || nameIndices.count == 1,
      (document.theme.custom != nil) == (customHeaders.count == 1),
      (document.theme.custom ?? [:]).mapValues({ $0.lowercased() }) == customValues
    else {
      throw HerdrAdapterError.invalidThemeConfiguration
    }

    return ParsedConfiguration(
      themeHeaderIndex: themeHeaders[0],
      customHeaderIndex: customHeaders.first,
      nameIndex: nameIndices.first,
      customIndices: customIndices,
      selection: document.theme.name,
      custom: customValues
    )
  }

  private static func parseEditableStringAssignment(
    _ rawLine: String,
    expectedKey: String? = nil
  ) -> (key: String, value: String)? {
    var arrayDepth = 0
    var multilineQuote: TOMLMultilineQuote?
    let line = scanTOMLLine(
      rawLine,
      arrayDepth: &arrayDepth,
      multilineQuote: &multilineQuote
    )
    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let key = parts[0].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty,
      key.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
      }),
      expectedKey == nil || key == expectedKey
    else { return nil }

    let value = parts[1].trimmingCharacters(in: .whitespaces)
    guard value.first == "\"" else { return nil }
    let contentAndTail = value.dropFirst()
    guard let closingQuote = contentAndTail.firstIndex(of: "\"") else { return nil }
    let content = contentAndTail[..<closingQuote]
    guard !content.contains("\\") else { return nil }
    let tail = contentAndTail[contentAndTail.index(after: closingQuote)...]
      .trimmingCharacters(in: .whitespaces)
    guard tail.isEmpty else { return nil }
    return (key, String(content))
  }

  private static func replacingManagedSurface(
    in configuration: String,
    parsed: ParsedConfiguration,
    with desired: ManagedSurface
  ) throws -> String {
    var lines = configuration.components(separatedBy: "\n")
    guard let name = desired.name else { throw HerdrAdapterError.invalidOwnership }
    let replacement = "name = \"\(name)\""
    if let nameIndex = parsed.nameIndex {
      let current = lines[nameIndex]
      let indentation = current.prefix { $0 == " " || $0 == "\t" }
      lines[nameIndex] = String(indentation) + replacement + commentSuffix(in: current)
    } else {
      lines.insert(replacement, at: parsed.themeHeaderIndex + 1)
    }

    let afterName = try parseConfiguration(lines.joined(separator: "\n"))
    for index in afterName.customIndices.values.sorted(by: >) {
      lines.remove(at: index)
    }

    guard !desired.custom.isEmpty else {
      return lines.joined(separator: "\n")
    }

    let reparsed = try parseConfiguration(lines.joined(separator: "\n"))
    let customLines = customKeys.map { key in
      "\(key) = \"\(desired.custom[key]!)\""
    }
    if let header = reparsed.customHeaderIndex {
      lines.insert(contentsOf: customLines, at: header + 1)
      return lines.joined(separator: "\n")
    }

    var updated = lines.joined(separator: "\n")
    if !updated.hasSuffix("\n") { updated.append("\n") }
    if !updated.hasSuffix("\n\n") { updated.append("\n") }
    updated += "[theme.custom]\n" + customLines.joined(separator: "\n") + "\n"
    return updated
  }

  private static func commentSuffix(in line: String) -> String {
    guard let equals = line.firstIndex(of: "=") else { return "" }
    let value = line[line.index(after: equals)...]
    guard let opening = value.firstIndex(of: "\"") else { return "" }
    let tail = value[value.index(after: opening)...]
    guard let closing = tail.firstIndex(of: "\"") else { return "" }
    let remainder = tail[tail.index(after: closing)...]
    guard let comment = remainder.firstIndex(of: "#") else { return "" }
    return " " + remainder[comment...]
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case HerdrAdapterError.automaticThemeSwitching,
      HerdrAdapterError.ownershipConflict,
      HerdrAdapterError.wrongThemeSelection:
      true
    default:
      false
    }
  }
}
