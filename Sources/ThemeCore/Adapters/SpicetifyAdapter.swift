import Darwin
import Dispatch
import Foundation

enum SpicetifyAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case controlUnavailable(URL)
  case invalidConfiguration(URL)
  case processInspectionFailed(String)
  case reconciliationLock(operation: String, code: Int32)
  case wrongColorScheme(String)
  case wrongTheme(String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Spicetify configuration at \(url.path)"
    case .controlUnavailable(let url):
      "Spicetify is not executable at \(url.path)"
    case .invalidConfiguration(let url):
      "Spicetify configuration at \(url.path) must contain one [Setting] table with one current_theme and color_scheme key"
    case .processInspectionFailed(let output):
      output.isEmpty ? "Cannot determine whether Spotify is running" : output
    case .reconciliationLock(let operation, let code):
      "Cannot \(operation) Spicetify reconciliation lock (errno \(code)): \(String(cString: strerror(code)))"
    case .wrongColorScheme(let expected):
      "Spicetify color_scheme must be \"\(expected)\""
    case .wrongTheme(let expected):
      "Spicetify current_theme must be \"\(expected)\""
    }
  }
}

struct SpicetifyAdapter: Sendable {
  static let id = "spicetify"
  static let outputPath = "generated/spicetify.ini"
  static let rendererVersion = 1
  static let colorSchemeName = "MacarchyCurrent"
  static let themeName = "text"
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/spicetify")

  private static let applicationLauncherURL = URL(filePath: "/usr/bin/open")
  private static let processLookupURL = URL(filePath: "/usr/bin/pgrep")
  private static let reconciliationSemaphore = DispatchSemaphore(value: 1)
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
      try await withReconciliationLock {
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

  private func withReconciliationLock(
    _ operation: () async throws -> AdapterOutcome
  ) async throws -> AdapterOutcome {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        Self.reconciliationSemaphore.wait()
        continuation.resume()
      }
    }
    defer { Self.reconciliationSemaphore.signal() }
    try Task.checkCancellation()

    let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let lockURL = runDirectory.appending(path: "spicetify.lock")
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
      throw SpicetifyAdapterError.reconciliationLock(operation: "open", code: errno)
    }
    defer { Darwin.close(descriptor) }

    while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
      if errno == EINTR { continue }
      throw SpicetifyAdapterError.reconciliationLock(operation: "acquire", code: errno)
    }
    return try await operation()
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

    var settingTables = 0
    var inSettings = false
    var themes = [String]()
    var colorSchemes = [String]()
    for rawLine in configuration.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
      if line.hasPrefix("[") {
        inSettings = line == "[Setting]"
        if inSettings { settingTables += 1 }
        continue
      }
      guard inSettings else { continue }
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2 else {
        throw SpicetifyAdapterError.invalidConfiguration(configurationURL)
      }
      switch parts[0] {
      case "current_theme": themes.append(parts[1])
      case "color_scheme": colorSchemes.append(parts[1])
      default: continue
      }
    }
    guard settingTables == 1, themes.count == 1, colorSchemes.count == 1 else {
      throw SpicetifyAdapterError.invalidConfiguration(configurationURL)
    }
    return (themes[0], colorSchemes[0])
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
