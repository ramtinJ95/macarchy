import Darwin
import Foundation

package struct GhosttyAdapter: Sendable {
  package static let id = "ghostty"
  package static let outputPath = "generated/ghostty.conf"
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
    case version(String)
    var description: String {
      switch self {
      case .includeDrift: "The owned Ghostty config-file line was edited, moved or removed"
      case .version(let output):
        "Cannot determine Ghostty's reload capability from --version: \(output)"
      }
    }
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw AdapterConfigurationError.controlUnavailable("Ghostty", executableURL)
    }
    let url = try ownedConfigurationURL ?? GhosttyConfiguration.selectedFile(in: configurationFiles)
    var metadata = stat()
    if lstat(url.path, &metadata) != 0, errno == ENOENT { throw Failure.includeDrift }
    let data = Data(try GhosttyConfiguration.read(url).utf8)
    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
    let directive = GhosttyConfiguration.includeDirective(root: root)
    let matching = lines.indices.filter { lines[$0] == Data(directive.utf8) }
    guard matching.count == 1, matching[0] < lines.count - 1,
      ownedLineIndex == nil || matching.first == ownedLineIndex
    else {
      throw Failure.includeDrift
    }
  }

  private var runtime: OrdinaryAdapterRuntime {
    OrdinaryAdapterRuntime(
      .ghostty, preflight: preflight,
      isIntegrationDrift: {
        if case Failure.includeDrift = $0 { return true }
        return false
      })
  }

  func inspection() -> AdapterInspection {
    runtime.inspection(readyMessage: overrideMessage())
  }

  private func overrideMessage() -> String? {
    GhosttyConfiguration.overrideMessage(files: configurationFiles, root: root, home: home)
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
    runtime.reconciliation {
      // An optional include must not hide a missing generated artifact (for example, a theme
      // activated by an older Macarchy build). Re-select the theme to generate it.
      _ = try GhosttyConfiguration.read(
        StateLayout(root: root).currentThemeArtifact(Self.outputPath))
      let running = try processes.matching(executablePath: executableURL.path)
      if running.isEmpty {
        return AdapterOutcome(
          status: .applied,
          message: ["Ghostty will use the theme on next launch.", overrideMessage()].compactMap {
            $0
          }.joined(separator: " "))
      }
      let result = try processRunner.run(
        ProcessRequest(executableURL: executableURL, arguments: ["--version"], timeout: 5))
      guard result.terminationStatus == 0, let version = Self.parseVersion(result.output) else {
        throw Failure.version(result.output)
      }
      guard !version.lexicographicallyPrecedes([1, 2, 0]) else {
        return AdapterOutcome(
          status: .restartRequired,
          message: [
            "Ghostty versions before 1.2.0: press ⌘⇧, in Ghostty to reload.", overrideMessage(),
          ].compactMap { $0 }.joined(separator: " "))
      }
      for identity in running { try processes.reload(identity) }
      return AdapterOutcome(status: .applied, message: overrideMessage())
    }
  }

  static func render(package: ThemePackage) -> String {
    let terminal = package.terminal
    var lines = [
      "# Generated by Macarchy. Do not edit.",
      "background = \(terminal.background.rawValue)",
      "foreground = \(terminal.foreground.rawValue)",
      "cursor-color = \(terminal.cursor.rawValue)",
      "cursor-text = \(terminal.background.rawValue)",
      "selection-background = \(terminal.selectionBackground.rawValue)",
      "selection-foreground = \(terminal.selectionForeground.rawValue)",
      "split-divider-color = \(package.semantic.border.rawValue)",
    ]
    lines += terminal.ansi.enumerated().map { "palette = \($0.offset)=\($0.element.rawValue)" }
    return lines.joined(separator: "\n") + "\n"
  }
}
