import Foundation

enum HerdrAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadDesiredTheme(URL)
  case cannotReadOwnership(URL)
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
    case .cannotReadDesiredTheme(let url):
      "Cannot read generated Herdr theme at \(url.path)"
    case .cannotReadOwnership(let url):
      "Cannot read Herdr ownership evidence at \(url.path)"
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

package enum HerdrMutationCheckpoint: Equatable, Sendable {
  case ownershipPrepared
  case configurationWritten
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
  static let rendererVersion = 4
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
  package static let minimumVersion = "0.8.2"

  let root: URL
  let configurationURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner
  let managedMode: HerdrManagedMode?
  let faultInjector: @Sendable (HerdrMutationCheckpoint) throws -> Void

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
    StateLayout(root: root).currentThemeArtifact(Self.outputPath)
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
          .herdr,
          message: "Herdr configuration is ready for an active theme"
        )
      }
      if let managedMode {
        return AdapterInspection(
          .herdr,
          message: try managedMode.inspect(desired)
        )
      }
      try verifyCurrentTheme(desired, parsed: parsed)
      return AdapterInspection(
        .herdr,
        message: desired.custom.isEmpty
          ? "Herdr uses the active mapped theme and supports live config reload"
          : "Herdr uses the complete active custom palette and supports live config reload"
      )
    } catch {
      return AdapterInspection(
        .herdr,
        status: Self.isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
    }
  }

  private var runtime: OrdinaryAdapterRuntime {
    OrdinaryAdapterRuntime(
      .herdr,
      preflight: preflight,
      isIntegrationDrift: Self.isIntegrationDrift
    )
  }

  func reconciliation() -> AdapterReconciliation {
    runtime.reconciliation {
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
      ProcessRequest(
        executableURL: executableURL, arguments: ["status", "server", "--json"], timeout: 1)
    )
    if status.terminationStatus == 0,
      Self.serverStatusIsConfirmedStopped(
        status.output,
        expectedSocket: configurationURL.deletingLastPathComponent().appending(path: "herdr.sock")
          .path)
    {
      return (true, "Herdr will use the active \(subject) on next launch")
    }
    return (
      false,
      reload.output.isEmpty ? "Herdr rejected its config reload" : reload.output
    )
  }

  private func currentDesiredTheme() throws -> GeneratedHerdrTheme? {
    guard FileManager.default.fileExists(atPath: StateLayout(root: root).currentTheme.path) else {
      return nil
    }
    let active = try Self.activeGeneratedTheme(root: root) { _ in
      HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
    }

    do {
      return try Self.decodeGeneratedTheme(active.data, rendererVersion: active.rendererVersion)
    } catch {
      throw HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
    }
  }

  func readConfiguration() throws -> (data: Data, text: String) {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: configurationURL.resolvingSymlinksInPath()).data
    } catch {
      throw AdapterConfigurationError.cannotReadConfiguration(
        "Herdr configuration", configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw AdapterConfigurationError.cannotReadConfiguration(
        "Herdr configuration", configurationURL)
    }
    return (data, configuration)
  }

  private func validatedConfiguration() throws -> ParsedConfiguration {
    guard controlIsAvailable() else {
      throw AdapterConfigurationError.controlUnavailable("Herdr", executableURL)
    }
    let configuration = try readConfiguration()
    return try Self.parseConfiguration(configuration.text)
  }

  private func requireCanonicalConfigurationPath() throws {
    guard ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"] == nil else {
      throw HerdrAdapterError.configurationOverrideUnsupported
    }
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
