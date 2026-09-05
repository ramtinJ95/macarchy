import Foundation
import TOMLDecoder

enum HerdrAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case cannotReadDesiredTheme(URL)
  case cannotReadOwnership(URL)
  case controlUnavailable(URL)
  case configurationOverrideUnsupported
  case invalidReloadResponse(String)
  case invalidThemeConfiguration
  case invalidGeneratedTheme
  case invalidVersion(String)
  case invalidOwnership
  case automaticThemeSwitching
  case unsupportedTheme(String)
  case unsupportedVersion(String)
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
    case .configurationOverrideUnsupported:
      "HERDR_CONFIG_PATH is unsupported; Herdr must use ~/.config/herdr/config.toml"
    case .invalidReloadResponse(let value):
      "Herdr returned an ambiguous config reload response: \(value)"
    case .invalidThemeConfiguration:
      "Herdr configuration must contain one canonical [theme] table, at most one canonical [theme.custom] table, and editable owned keys"
    case .invalidGeneratedTheme:
      "Generated Herdr theme is invalid"
    case .invalidVersion(let value):
      "Herdr returned an unparseable version: \(value)"
    case .invalidOwnership:
      "Herdr ownership evidence is invalid"
    case .automaticThemeSwitching:
      "Herdr theme.auto_switch must remain false while Macarchy owns the theme selector"
    case .unsupportedTheme(let name):
      "Herdr theme \"\(name)\" is not allowlisted"
    case .unsupportedVersion(let value):
      "Herdr \(value) is unsupported; version \(HerdrAdapter.minimumVersion) or newer is required"
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

  package let schemaVersion: Int
  package let name: String
  package let custom: [String: String]

  init(name: String, custom: [String: String] = [:]) {
    schemaVersion = Self.currentSchemaVersion
    self.name = name
    self.custom = custom
  }

  package func validated() throws -> Self {
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

package struct HerdrLegacyOwnershipEvidence: Equatable, Sendable {
  package let originalConfiguration: String
  package let currentConfiguration: String
}

package struct HerdrManagedMode: Sendable {
  package let preflight: @Sendable (GeneratedHerdrTheme) throws -> Void
  package let inspect: @Sendable (GeneratedHerdrTheme) throws -> String
  package let reconcile: @Sendable (GeneratedHerdrTheme) throws -> String

  package init(
    preflight: @escaping @Sendable (GeneratedHerdrTheme) throws -> Void,
    inspect: @escaping @Sendable (GeneratedHerdrTheme) throws -> String,
    reconcile: @escaping @Sendable (GeneratedHerdrTheme) throws -> String
  ) {
    self.preflight = preflight
    self.inspect = inspect
    self.reconcile = reconcile
  }
}

package struct HerdrAdapter: Sendable {
  package static let id = "herdr"
  package static let outputPath = "generated/herdr.txt"
  static let rendererVersion = 3
  package static var liveExecutableURL: URL {
    executableURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
  }

  package static func executableURL(homeDirectory: URL) -> URL {
    preferredExternalOrHomebrewExecutableURL(
      homeDirectory: homeDirectory,
      externalRelativePath: ".local/bin/herdr",
      homebrewExecutableName: "herdr"
    )
  }
  package static let minimumVersion = "0.8.0"

  static let supportedThemes = Set([
    "catppuccin", "tokyo-night", "kanagawa",
  ])
  package static let customKeys = [
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
  let managedMode: HerdrManagedMode?
  var faultInjector: @Sendable (HerdrMutationCheckpoint) throws -> Void = { _ in }

  package init(
    root: URL,
    configurationURL: URL,
    executableURL: URL,
    controlIsAvailable: @escaping @Sendable () -> Bool,
    processRunner: ProcessRunner = .live,
    managedMode: HerdrManagedMode? = nil,
    faultInjector: @escaping @Sendable (HerdrMutationCheckpoint) throws -> Void = { _ in }
  ) {
    self.root = root
    self.configurationURL = configurationURL
    self.executableURL = executableURL
    self.controlIsAvailable = controlIsAvailable
    self.processRunner = processRunner
    self.managedMode = managedMode
    self.faultInjector = faultInjector
  }

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
    try requireCanonicalConfigurationPath()
    _ = try supportedVersion()
    if let managedMode, let desired = try currentDesiredTheme() {
      try managedMode.preflight(desired)
      return
    }
    _ = try validatedConfiguration()
  }

  func preflight(package: ThemePackage) throws {
    try requireCanonicalConfigurationPath()
    _ = try supportedVersion()
    let desired = try Self.desiredTheme(for: package)
    if let managedMode {
      try managedMode.preflight(desired)
      return
    }
    let parsed = try validatedConfiguration()
    try verifyTransitionPossible(parsed)
  }

  func inspection(includeRuntimeChecks: Bool = false) -> AdapterInspection {
    // Keep inspection nonmutating; an in-flight ownership record is visible as drift.
    do {
      try requireCanonicalConfigurationPath()
      if includeRuntimeChecks { _ = try supportedVersion() }
      let parsed = try validatedConfiguration()
      guard let desired = try currentDesiredTheme() else {
        return AdapterInspection(
          adapterID: Self.id,
          requirement: .required,
          message: "Herdr configuration is ready for an active theme"
        )
      }
      if let managedMode {
        return AdapterInspection(
          adapterID: Self.id,
          requirement: .required,
          message: try managedMode.inspect(desired)
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
        if let managedMode {
          guard let desired = try currentDesiredTheme() else {
            throw HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
          }
          return AdapterOutcome(
            status: .applied,
            message: try managedMode.reconcile(desired)
          )
        }
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

      let reload = try reloadCurrentConfiguration(checkVersion: false, subject: "theme")
      return AdapterOutcome(
        status: reload.succeeded ? .applied : .failed,
        message: reload.message
      )
    }
  }

  package func reloadCurrentConfiguration(
    checkVersion: Bool = true,
    subject: String = "configuration"
  ) throws -> (succeeded: Bool, message: String) {
    try requireCanonicalConfigurationPath()
    if checkVersion { _ = try supportedVersion() }
    let reload = try processRunner.run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: ["server", "reload-config"],
        timeout: 2
      )
    )
    if reload.terminationStatus == 0, Self.reloadResponseIsUnambiguousSuccess(reload.output) {
      return (true, "Herdr reloaded the active \(subject)")
    }
    if reload.terminationStatus == 0 {
      return (false, String(describing: HerdrAdapterError.invalidReloadResponse(reload.output)))
    }

    let status = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: ["status", "server"], timeout: 1)
    )
    let statusLines = status.output.split(whereSeparator: \Character.isNewline)
    if status.terminationStatus == 0,
      statusLines.count == 1,
      statusLines[0].trimmingCharacters(in: .whitespaces) == "status: stopped"
    {
      return (true, "Herdr will use the active \(subject) on next launch")
    }
    return (
      false,
      reload.output.isEmpty ? "Herdr rejected its config reload" : reload.output
    )
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

  package static func desiredTheme(root: URL) throws -> GeneratedHerdrTheme {
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    let url = root.appending(path: "current/\(outputPath)").resolvingSymlinksInPath()
    let data = try BoundedRegularFile.read(at: url).data
    return try decodeGeneratedTheme(
      data,
      rendererVersion: manifest.rendererVersions[id, default: 0]
    )
  }

  package func legacyOwnershipEvidence() throws -> HerdrLegacyOwnershipEvidence? {
    guard try authenticatedLegacyOwnershipMatchesCurrentGeneration() else { return nil }
    guard let state = try readOwnership() else {
      throw HerdrAdapterError.invalidOwnership
    }
    let current = try readConfiguration()
    let currentParsed = try Self.parseConfiguration(current.text)
    guard currentParsed.surface == state.desired else {
      throw HerdrAdapterError.ownershipConflict(
        "legacy adapter evidence does not authenticate the current theme surface"
      )
    }
    let originalData = try BoundedRegularFile.read(at: backupURL).data
    guard let original = String(data: originalData, encoding: .utf8) else {
      throw HerdrAdapterError.backupUnavailable(backupURL)
    }
    return HerdrLegacyOwnershipEvidence(
      originalConfiguration: original,
      currentConfiguration: current.text
    )
  }

  package func authenticatedLegacyOwnershipMatchesCurrentGeneration() throws -> Bool {
    let hasOwnership = FileManager.default.fileExists(atPath: ownershipURL.path)
    let hasBackup = FileManager.default.fileExists(atPath: backupURL.path)
    guard hasOwnership || hasBackup else { return false }
    guard hasOwnership, hasBackup, let state = try readOwnership(), state.before == nil else {
      throw HerdrAdapterError.ownershipConflict(
        "legacy adapter evidence is incomplete or interrupted"
      )
    }
    try verifyBackup(state.backupDigest)
    let expected = try Self.desiredTheme(root: root)
    guard state.desired.matches(expected) else {
      throw HerdrAdapterError.ownershipConflict(
        "legacy adapter evidence does not match the active generation"
      )
    }
    let originalData = try BoundedRegularFile.read(at: backupURL).data
    guard let original = String(data: originalData, encoding: .utf8) else {
      throw HerdrAdapterError.backupUnavailable(backupURL)
    }
    let originalParsed = try Self.parseConfiguration(original)
    guard originalParsed.selection == Self.importedBaseTheme, originalParsed.custom.isEmpty else {
      throw HerdrAdapterError.ownershipConflict(
        "legacy original is not the authenticated Catppuccin selector boundary"
      )
    }
    return true
  }

  package func discardLegacyOwnershipEvidence() throws {
    for url in [ownershipURL, backupURL] {
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else {
        if errno == ENOENT { continue }
        throw HerdrAdapterError.cannotReadOwnership(url)
      }
      guard metadata.st_mode & S_IFMT == S_IFREG else {
        throw HerdrAdapterError.ownershipConflict(
          "legacy adapter evidence is not a regular file"
        )
      }
      try FileManager.default.removeItem(at: url)
    }
  }

  package static func parseVersion(_ output: String) -> [Int]? {
    AdapterVersionParser.parse(output, executableLabel: "herdr")
  }

  package func supportedVersion() throws -> String {
    let result = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: ["--version"], timeout: 2)
    )
    guard result.terminationStatus == 0, let version = Self.parseVersion(result.output) else {
      throw HerdrAdapterError.invalidVersion(result.output)
    }
    let minimum = Self.parseVersion("herdr \(Self.minimumVersion)")!
    guard !version.lexicographicallyPrecedes(minimum) else {
      throw HerdrAdapterError.unsupportedVersion(result.output)
    }
    return version.map(String.init).joined(separator: ".")
  }

  package static func reloadResponseIsUnambiguousSuccess(_ output: String) -> Bool {
    let requiredFields = ["id", "result", "diagnostics", "status", "type"]
    guard
      requiredFields.allSatisfy({
        output.components(separatedBy: "\"\($0)\"").count == 2
      })
    else { return false }
    guard let data = output.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["id", "result"],
      object["id"] as? String == "cli:server:reload-config",
      let result = object["result"] as? [String: Any],
      Set(result.keys) == ["diagnostics", "status", "type"],
      result["type"] as? String == "config_reload",
      result["status"] as? String == "applied",
      (result["diagnostics"] as? [Any])?.isEmpty == true
    else { return false }
    return true
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

  private func requireCanonicalConfigurationPath() throws {
    guard ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"] == nil else {
      throw HerdrAdapterError.configurationOverrideUnsupported
    }
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

  package struct ManagedSurface: Codable, Equatable, Sendable {
    package let name: String?
    package let custom: [String: String]

    package init(name: String?, custom: [String: String]) {
      self.name = name
      self.custom = custom
    }

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

  package struct ParsedConfiguration {
    package let themeHeaderIndex: Int
    package let customHeaderIndex: Int?
    package let nameIndex: Int?
    package let customIndices: [String: Int]
    package let selection: String?
    package let custom: [String: String]

    package var surface: ManagedSurface {
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

  package static func parseConfiguration(_ configuration: String) throws -> ParsedConfiguration {
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

  package static func replacingManagedSurface(
    in configuration: String,
    parsed: ParsedConfiguration,
    with desired: ManagedSurface
  ) throws -> String {
    guard let name = desired.name else { throw HerdrAdapterError.invalidOwnership }
    let newline =
      tomlPhysicalLines(configuration).first(where: { !$0.terminator.isEmpty })?.terminator
      ?? "\n"
    let replacement = "name = \"\(name)\""
    var updated = configuration
    if let nameIndex = parsed.nameIndex {
      let lines = tomlPhysicalLines(updated)
      guard nameIndex < lines.count else { throw HerdrAdapterError.invalidThemeConfiguration }
      let line = lines[nameIndex]
      let current = String(updated[line.contentRange])
      let indentation = current.prefix { $0 == " " || $0 == "\t" }
      updated.replaceSubrange(
        line.contentRange,
        with: String(indentation) + replacement + commentSuffix(in: current)
      )
    } else {
      let lines = tomlPhysicalLines(updated)
      guard parsed.themeHeaderIndex < lines.count else {
        throw HerdrAdapterError.invalidThemeConfiguration
      }
      let header = lines[parsed.themeHeaderIndex]
      let insertion =
        (header.terminator.isEmpty ? newline : "") + replacement + newline
      updated.insert(contentsOf: insertion, at: header.fullRange.upperBound)
    }

    let afterName = try parseConfiguration(updated)
    let namedLines = tomlPhysicalLines(updated)
    for index in afterName.customIndices.values.sorted(by: >) {
      guard index < namedLines.count else { throw HerdrAdapterError.invalidThemeConfiguration }
      updated.removeSubrange(namedLines[index].fullRange)
    }

    guard !desired.custom.isEmpty else {
      return updated
    }

    let reparsed = try parseConfiguration(updated)
    let customLines =
      customKeys.map { key in
        "\(key) = \"\(desired.custom[key]!)\""
      }.joined(separator: newline) + newline
    if let header = reparsed.customHeaderIndex {
      let lines = tomlPhysicalLines(updated)
      guard header < lines.count else { throw HerdrAdapterError.invalidThemeConfiguration }
      let headerLine = lines[header]
      let insertion = (headerLine.terminator.isEmpty ? newline : "") + customLines
      updated.insert(contentsOf: insertion, at: headerLine.fullRange.upperBound)
      return updated
    }

    if !updated.hasSuffix("\n"), !updated.hasSuffix("\r") { updated.append(newline) }
    if !updated.hasSuffix(newline + newline) { updated.append(newline) }
    updated += "[theme.custom]" + newline + customLines
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
