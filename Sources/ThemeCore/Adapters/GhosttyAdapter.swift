import Darwin
import Foundation

package struct GhosttyAdapter: Sendable {
  package static let id = "ghostty"
  package static let outputPath = "generated/ghostty.conf"
  package static let bridgePath = "state/adapters/ghostty.conf"
  static let rendererVersion = 1
  package static let liveExecutableURL = URL(
    filePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")

  let root: URL
  let home: URL
  let configurationFiles: [URL]
  let ownedConfigurationURL: URL?
  let ownedLineIndex: Int?
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner
  let processes: GhosttyProcesses

  init(
    root: URL, home: URL, configurationFiles: [URL], ownedConfigurationURL: URL?,
    ownedLineIndex: Int?, executableURL: URL, controlIsAvailable: @escaping @Sendable () -> Bool,
    processRunner: ProcessRunner, processes: GhosttyProcesses = .live
  ) {
    self.root = root
    self.home = home
    self.configurationFiles = configurationFiles
    self.ownedConfigurationURL = ownedConfigurationURL
    self.ownedLineIndex = ownedLineIndex
    // proc_pidpath returns the real executable. Probe this exact resolved bundle path too.
    self.executableURL = executableURL.resolvingSymlinksInPath()
    self.controlIsAvailable = controlIsAvailable
    self.processRunner = processRunner
    self.processes = processes
  }

  enum Failure: Error, CustomStringConvertible {
    case includeDrift
    case outdatedInclude
    case unsafeConfiguration
    case ignoredConfiguration(String)
    case version(String)
    var description: String {
      switch self {
      case .outdatedInclude:
        "The owned Ghostty include is outdated. Tear down or disable the Ghostty preset, then re-enable it to adopt the stable bridge."
      case .includeDrift: "The owned Ghostty config-file line was edited, moved or removed"
      case .unsafeConfiguration:
        "The owned Ghostty configuration is not an ordinary home-contained file"
      case .ignoredConfiguration(let path):
        "The installed Ghostty version does not load the owned configuration: \(path). Disable the preset to restore it before adopting a supported file."
      case .version(let output):
        "Cannot determine Ghostty's reload capability from --version: \(output)"
      }
    }
  }

  private func installedVersion() throws -> [Int] {
    guard controlIsAvailable() else {
      throw AdapterConfigurationError.controlUnavailable("Ghostty", executableURL)
    }
    return try Self.version(executableURL: executableURL, processRunner: processRunner)
  }

  func preflight() throws {
    try preflight(version: installedVersion())
  }

  private func preflight(version: [Int]) throws {
    let files = GhosttyConfiguration.filesRead(in: configurationFiles, version: version)
    let url = try ownedConfigurationURL ?? GhosttyConfiguration.selectedFile(in: files)
    guard files.contains(url) else { throw Failure.ignoredConfiguration(url.path) }
    var metadata = stat()
    if lstat(url.path, &metadata) != 0, errno == ENOENT { throw Failure.includeDrift }
    guard url.path.hasPrefix(home.path + "/"),
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1
    else { throw Failure.unsafeConfiguration }
    // Unlike user includes, the owned file may not redirect through a leaf or ancestor link.
    // Open each parent without following symlinks, then read through that pinned descriptor.
    let data = try PinnedFilesystem.readRegularFile(at: url).data
    guard String(data: data, encoding: .utf8) != nil else {
      throw BoundedRegularFileError.invalidUTF8
    }
    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
    let legacy = GhosttyConfiguration.legacyIncludeDirective(root: root)
    let legacyMatches = lines.indices.filter { lines[$0] == Data(legacy.utf8) }
    if legacyMatches.count == 1, legacyMatches[0] < lines.count - 1,
      ownedLineIndex == nil || legacyMatches.first == ownedLineIndex
    {
      throw Failure.outdatedInclude
    }
    let directive = GhosttyConfiguration.includeDirective(root: root)
    let matching = lines.indices.filter { lines[$0] == Data(directive.utf8) }
    guard matching.count == 1, matching[0] < lines.count - 1,
      ownedLineIndex == nil || matching.first == ownedLineIndex
    else {
      throw Failure.includeDrift
    }
  }

  private func runtime(version: [Int]) -> OrdinaryAdapterRuntime {
    OrdinaryAdapterRuntime(
      .ghostty, preflight: { try preflight(version: version) },
      isIntegrationDrift: {
        if case Failure.includeDrift = $0 { return true }
        if case Failure.outdatedInclude = $0 { return true }
        return false
      })
  }

  func inspection() -> AdapterInspection {
    do {
      let version = try installedVersion()
      return runtime(version: version).inspection(readyMessage: overrideMessage(version: version))
    } catch {
      return AdapterInspection(
        adapterID: Self.id, requirement: .required, status: .failed,
        message: String(describing: error))
    }
  }

  private func overrideMessage(version: [Int]) -> String? {
    let messages = [
      GhosttyConfiguration.ignoredFilesMessage(in: configurationFiles, version: version),
      GhosttyConfiguration.overrideMessage(
        files: GhosttyConfiguration.filesRead(in: configurationFiles, version: version),
        root: root, home: home),
    ].compactMap { $0 }
    return messages.isEmpty ? nil : messages.joined(separator: " ")
  }

  package static func installedVersion() throws -> [Int] {
    try version(
      executableURL: liveExecutableURL.resolvingSymlinksInPath(), processRunner: .live)
  }

  static func version(executableURL: URL, processRunner: ProcessRunner) throws -> [Int] {
    let result = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: ["--version"], timeout: 5))
    guard result.terminationStatus == 0, let version = parseVersion(result.output) else {
      throw Failure.version(result.output)
    }
    return version
  }

  package static func parseVersion(_ output: String) -> [Int]? {
    guard let line = output.split(separator: "\n").first else { return nil }
    let fields = line.split(whereSeparator: { $0.isWhitespace })
    guard fields.count == 2, fields[0].lowercased() == "ghostty" else { return nil }
    let release = fields[1].split(separator: "+", maxSplits: 1)[0]
    let parts = release.split(separator: ".", omittingEmptySubsequences: false)
    let numbers = parts.compactMap { Int($0) }
    guard parts.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
    return numbers
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .required) {
      let version = try installedVersion()
      if let failure = runtime(version: version).preflightFailure() { return failure }
      try ActivationLock(root: root).withLock {
        try StableAdapterBridge.publish(
          Self.activeConfiguration(root: root), root: root, path: Self.bridgePath)
      }
      let running = try processes.matching(executablePath: executableURL.path)
      if running.isEmpty {
        return AdapterOutcome(
          status: .applied,
          message: [
            "Ghostty will use the theme on next launch.", overrideMessage(version: version),
          ].compactMap {
            $0
          }.joined(separator: " "))
      }
      guard !version.lexicographicallyPrecedes([1, 2, 0]) else {
        return AdapterOutcome(
          status: .restartRequired,
          message: [
            "Ghostty versions before 1.2.0: press ⌘⇧, in Ghostty to reload.",
            overrideMessage(version: version),
          ].compactMap { $0 }.joined(separator: " "))
      }
      for identity in running { try processes.reload(identity) }
      return AdapterOutcome(status: .applied, message: overrideMessage(version: version))
    }
  }

  /// Readable pre-Ghostty generations have no artifact. Render their validated palette
  /// without changing the immutable generation or canonical pointer.
  package static func activeConfiguration(root: URL) throws -> Data {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    if manifest.artifacts[outputPath] != nil {
      return try BoundedRegularFile.read(at: manifest.artifactURL(root: root, path: outputPath))
        .data
    }
    let theme = try manifest.normalizedTheme(root: root)
    return Data(render(terminal: theme.terminal, border: theme.semantic.border).utf8)
  }

  static func render(package: ThemePackage) -> String {
    render(terminal: package.terminal, border: package.semantic.border)
  }

  private static func render(terminal: TerminalColors, border: SRGBColor) -> String {
    var lines = [
      "# Generated by Macarchy. Do not edit.",
      "background = \(terminal.background.rawValue)",
      "foreground = \(terminal.foreground.rawValue)",
      "cursor-color = \(terminal.cursor.rawValue)",
      "cursor-text = \(terminal.background.rawValue)",
      "selection-background = \(terminal.selectionBackground.rawValue)",
      "selection-foreground = \(terminal.selectionForeground.rawValue)",
      "split-divider-color = \(border.rawValue)",
    ]
    lines += terminal.ansi.enumerated().map { "palette = \($0.offset)=\($0.element.rawValue)" }
    return lines.joined(separator: "\n") + "\n"
  }
}
