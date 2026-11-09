import Darwin
import Foundation

package struct AlacrittyAdapter: Sendable {
  package static let id = "alacritty"
  package static let outputPath = "generated/alacritty.toml"
  package static let bridgePath = "state/adapters/alacritty.toml"
  static let rendererVersion = 1
  package static let liveExecutableURL = URL(
    filePath: "/Applications/Alacritty.app/Contents/MacOS/alacritty")
  let root: URL
  let home: URL
  let configurationFiles: [URL]
  let ownedConfigurationURL: URL?
  let ownedImportEdit: AlacrittyImportEdit?
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner

  enum Failure: Error, CustomStringConvertible {
    case version(String)
    case unsupported
    case bridgeDrift
    case unsafe(String)
    var description: String {
      switch self {
      case .version(let output): "Cannot determine Alacritty version: \(output)"
      case .unsupported: "Alacritty 0.14.0 or newer is required for general.import"
      case .bridgeDrift:
        "Alacritty's stable theme file does not match the active generation; reconcile alacritty"
      case .unsafe(let path):
        "Alacritty configuration/bridge must be an ordinary home-contained file: \(path)"
      }
    }
  }
  package static func requireSupported(_ version: [Int]) throws {
    guard !version.lexicographicallyPrecedes([0, 14, 0]) else { throw Failure.unsupported }
  }
  package static func parseVersion(_ output: String) -> [Int]? {
    let fields = output.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2, fields[0].lowercased() == "alacritty" else { return nil }
    let parts = fields[1].split(separator: ".")
    let numbers = parts.compactMap { Int($0) }
    return parts.count == 3 && numbers.count == 3 && numbers.allSatisfy { $0 >= 0 } ? numbers : nil
  }
  package static func installedVersion() throws -> [Int] {
    try version(executableURL: liveExecutableURL, runner: .live)
  }
  static func version(executableURL: URL, runner: ProcessRunner) throws -> [Int] {
    let result = try runner.run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: ["--version"], timeout: 5))
    guard result.terminationStatus == 0, let version = parseVersion(result.output) else {
      throw Failure.version(result.output)
    }
    return version
  }
  private func configuration() throws -> (URL, String) {
    let selected = try AlacrittyConfiguration.selectedFile(in: configurationFiles)
    let url = ownedConfigurationURL ?? selected
    guard selected == url, url.path.hasPrefix(home.path + "/") else {
      throw Failure.unsafe(url.path)
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1
    else { throw Failure.unsafe(url.path) }
    let file = try PinnedFilesystem.readRegularFile(at: url)
    guard let text = String(data: file.data, encoding: .utf8) else {
      throw BoundedRegularFileError.invalidUTF8
    }
    if let ownedImportEdit {
      guard ownedImportEdit.themePath == root.appending(path: Self.bridgePath).path else {
        throw AlacrittyImportEdit.Failure.drift
      }
      try ownedImportEdit.validateManaged(file.data)
    } else {
      guard
        try AlacrittyImportEdit.imports(text).filter({
          $0 == root.appending(path: Self.bridgePath).path
        }).count == 1
      else { throw AlacrittyImportEdit.Failure.drift }
    }
    return (url, text)
  }
  func preflight() throws {
    guard controlIsAvailable() else {
      throw AdapterConfigurationError.controlUnavailable("Alacritty", executableURL)
    }
    try Self.requireSupported(Self.version(executableURL: executableURL, runner: processRunner))
    _ = try configuration()
  }
  func inspection() -> AdapterInspection {
    do {
      try preflight()
      do {
        try ActivationLock(root: root).withLock {
          let desired = try Self.activeConfiguration(root: root)
          let url = root.appending(path: Self.bridgePath)
          let current: Data
          do { current = try PinnedFilesystem.readRegularFile(at: url).data } catch let error
            as PinnedFilesystemError where error.code == ENOENT
          {
            throw Failure.bridgeDrift
          }
          guard current == desired else { throw Failure.bridgeDrift }
        }
      } catch ReconciliationStatusError.noActiveGeneration {
        // The owned import can be inspected before first theme activation.
      }
      return AdapterInspection(.alacritty, message: inspectionMessage())
    } catch Failure.unsupported {
      return AdapterInspection(
        .alacritty, status: .unsupported, message: Failure.unsupported.description)
    } catch Failure.bridgeDrift {
      return AdapterInspection(
        .alacritty, status: .drifted, message: Failure.bridgeDrift.description)
    } catch {
      return AdapterInspection(
        .alacritty,
        status: error is AlacrittyImportEdit.Failure ? .drifted : .failed,
        message: String(describing: error))
    }
  }
  private func inspectionMessage() -> String? {
    guard let (url, text) = try? configuration() else { return nil }
    return AlacrittyConfiguration.overrideMessage(
      configuration: text, source: url, root: root, home: home)
  }
  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(.alacritty) {
      do { try preflight() } catch Failure.unsupported {
        return AdapterOutcome(status: .unsupported, message: Failure.unsupported.description)
      } catch let error as AlacrittyImportEdit.Failure {
        return AdapterOutcome(status: .drifted, message: error.description)
      }
      let (url, text) = try configuration()
      let first = try ActivationLock(root: root).withLock {
        try Self.publishBridge(root: root)
      }
      let reload = try AlacrittyConfiguration.reloadState(
        configuration: text, source: url, home: home)
      let boundary =
        !reload.enabled
        ? "Alacritty live_config_reload is false: next_invocation; reopen Alacritty to use the theme."
        : first
          ? "First Alacritty connection: reopen Alacritty to establish its theme-file watcher; later switches reload automatically."
          : "Alacritty watches the stable theme file; live repaint expected when live_config_reload is enabled."
      let overrides = AlacrittyConfiguration.overrideMessage(
        configuration: text, source: url, root: root, home: home)
      return AdapterOutcome(
        status: first || !reload.enabled ? .restartRequired : .applied,
        message: ([boundary, overrides].compactMap { $0 } + reload.notices).joined(separator: " "))
    }
  }
  /// Real parent directories, pinned descriptors and atomic replacement. Never a
  /// generation symlink: Alacritty canonicalizes its watched paths at startup.
  static func publishBridge(root: URL) throws -> Bool {
    let desired = try activeConfiguration(root: root)
    return try withBridgeParent(root: root) { parent, url in
      let first = try bridgeIsAbsent(parent: parent, url: url)
      try PinnedFilesystem.replaceRegularFileAtomically(
        parentDescriptor: parent,
        name: url.lastPathComponent, url: url, data: desired, mode: 0o644)
      return first
    }
  }

  private static func activeConfiguration(root: URL) throws -> Data {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    return try BoundedRegularFile.read(at: manifest.artifactURL(root: root, path: outputPath)).data
  }

  package static func restoreBridge(at url: URL, data: Data?, mode: UInt16?) throws {
    if data == nil {
      guard
        let parent = try PinnedFilesystem.openDirectoryIfPresent(
          at: url.deletingLastPathComponent())
      else { return }
      defer { close(parent) }
      if try bridgeIsAbsent(parent: parent, url: url) { return }
      guard unlinkat(parent, url.lastPathComponent, 0) == 0 else {
        throw PinnedFilesystemError(operation: "remove Alacritty bridge", url: url, code: errno)
      }
    } else if let data {
      let root = url.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      try withBridgeParent(root: root) { parent, target in
        _ = try bridgeIsAbsent(parent: parent, url: target)
        try PinnedFilesystem.replaceRegularFileAtomically(
          parentDescriptor: parent,
          name: target.lastPathComponent, url: target, data: data, mode: mode_t(mode ?? 0o644))
      }
    }
  }

  private static func bridgeIsAbsent(parent: Int32, url: URL) throws -> Bool {
    var metadata = stat()
    let result = fstatat(parent, url.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW)
    let absent = result != 0 && errno == ENOENT
    guard absent || (result == 0 && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_nlink == 1)
    else {
      throw Failure.unsafe(url.path)
    }
    return absent
  }

  private static func withBridgeParent<T>(root: URL, body: (Int32, URL) throws -> T) throws -> T {
    let rootFD = try PinnedFilesystem.openDirectory(at: root)
    defer { close(rootFD) }
    let state = root.appending(path: "state")
    let stateFD = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: rootFD, name: "state", url: state)
    defer { close(stateFD) }
    let directory = state.appending(path: "adapters")
    let parent = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: stateFD, name: "adapters", url: directory)
    defer { close(parent) }
    let url = root.appending(path: bridgePath)
    return try body(parent, url)
  }
  static func render(package: ThemePackage) -> String {
    let terminal = package.terminal
    var lines = [
      "# Generated by Macarchy. Do not edit.", "", "[colors.primary]",
      "background = \"\(terminal.background.rawValue)\"",
      "foreground = \"\(terminal.foreground.rawValue)\"", "", "[colors.cursor]",
      "text = \"\(terminal.background.rawValue)\"", "cursor = \"\(terminal.cursor.rawValue)\"",
      "", "[colors.selection]", "text = \"\(terminal.selectionForeground.rawValue)\"",
      "background = \"\(terminal.selectionBackground.rawValue)\"",
    ]
    let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
    for (table, offset) in [("normal", 0), ("bright", 8)] {
      lines += ["", "[colors.\(table)]"]
      lines += names.enumerated().map {
        "\($0.element) = \"\(terminal.ansi[offset + $0.offset].rawValue)\""
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
