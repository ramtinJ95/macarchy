import Darwin
import Foundation

package struct VSCodeAdapter: Sendable {
  package static let extensionID = "macarchy.macarchy-theme"
  package let editor: VSCodeEditor
  package let root: URL
  package let home: URL
  package var discover: @Sendable (VSCodeEditor) throws -> VSCodeEditor.Installation = {
    try $0.discover()
  }
  package var runner: ProcessRunner = .live
  package var validateOwnership: @Sendable (VSCodeEditor, URL) throws -> Void

  package init(
    editor: VSCodeEditor, root: URL, home: URL,
    discover: @escaping @Sendable (VSCodeEditor) throws -> VSCodeEditor.Installation = {
      try $0.discover()
    },
    runner: ProcessRunner = .live,
    validateOwnership: @escaping @Sendable (VSCodeEditor, URL) throws -> Void
  ) {
    self.editor = editor
    self.root = root
    self.home = home
    self.discover = discover
    self.runner = runner
    self.validateOwnership = validateOwnership
  }

  package enum Failure: Error, CustomStringConvertible {
    case blocked(String)
    case drift
    package var description: String {
      switch self {
      case .blocked(let message): message
      case .drift: "The owned VS Code-family settings or extension drifted."
      }
    }
  }

  package static func command(
    _ cli: URL, _ arguments: [String], runner: ProcessRunner,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws
    -> String
  {
    // Also covers readback and teardown of an already-owned installation: portable
    // data can have appeared since discovery/adoption.
    try VSCodeEditor.refusePortableCLI(cli)
    let result = try runner.run(
      ProcessRequest(
        executableURL: cli, arguments: arguments, timeout: 120,
        environmentRemovals: environmentRemovals(environment), isolatedProcessGroup: true))
    guard result.terminationStatus == 0 else {
      throw Failure.blocked(
        "\(cli.path) \(arguments.first ?? "") failed (\(result.terminationStatus)): \(result.output.prefix(1000))"
      )
    }
    return result.output
  }

  package static func environmentRemovals(_ environment: [String: String]) -> Set<String> {
    // VS Code's bootstrap accepts relocation and remote CLI controls. The wrapper
    // also forwards NODE_OPTIONS into VSCODE_NODE_OPTIONS. Preserve neither family.
    // Removing HOME makes Node use the account home, matching the default profile.
    Set(environment.keys.filter { $0.hasPrefix("VSCODE_") || $0.hasPrefix("ELECTRON_") })
      .union([
        "VSCODE_EXTENSIONS", "VSCODE_APPDATA", "VSCODE_PORTABLE", "VSCODE_DEV",
        "VSCODE_CLI", "VSCODE_IPC_HOOK_CLI", "VSCODE_CWD", "ELECTRON_RUN_AS_NODE",
        "HOME", "NODE_OPTIONS", "NODE_PATH", "NODE_REPL_EXTERNAL_MODULE",
      ])
  }

  package static func installedVersion(cli: URL, runner: ProcessRunner = .live) throws -> String? {
    let output = try command(cli, ["--list-extensions", "--show-versions"], runner: runner)
    let matches = output.split(whereSeparator: \.isNewline).filter {
      $0.lowercased().hasPrefix(extensionID + "@")
    }
    guard matches.count <= 1 else { throw Failure.drift }
    guard let match = matches.first else { return nil }
    let version = String(match.dropFirst(extensionID.count + 1))
    guard !version.isEmpty else { throw Failure.drift }
    return version
  }

  package struct Publication: Codable {
    let cli: String
    let settings: String
    let version: String
    let digest: String
  }

  private var receiptURL: URL { root.appending(path: "state/\(editor.rawValue)-extension.json") }

  package func authenticate(
    version: String?, installation: VSCodeEditor.Installation, initialVersion: String
  ) throws {
    guard let version else { return }
    if version == initialVersion { return }
    if let data = try receiptData() {
      guard let receipt = try? JSONDecoder().decode(Publication.self, from: data),
        receipt.cli == installation.cli.path,
        receipt.settings == installation.settings(home: home).path,
        isSHA256Digest(receipt.digest)
      else { throw Failure.blocked("Invalid \(editor.label) extension publication receipt") }
      if version == receipt.version { return }
    }
    // Retry after an install whose publication receipt could not be persisted.
    if try version == VSCodeTheme.active(root: root).version { return }
    throw Failure.drift
  }

  private func receiptData() throws -> Data? {
    do { return try PinnedFilesystem.readRegularFile(at: receiptURL).data } catch let error
      as PinnedFilesystemError where error.code == ENOENT
    { return nil }
  }

  private func publish(_ theme: VSCodeTheme, installation: VSCodeEditor.Installation) throws {
    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    let state = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: parent, name: "state", url: receiptURL.deletingLastPathComponent(),
      mode: 0o700)
    defer { Darwin.close(state) }
    try StateFile.write(
      Publication(
        cli: installation.cli.path, settings: installation.settings(home: home).path,
        version: theme.version, digest: sha256Digest(theme.package + theme.theme)),
      parentDescriptor: state, name: receiptURL.lastPathComponent, url: receiptURL)
  }

  package static func profiles(installation: VSCodeEditor.Installation, home: URL) throws
    -> [String]
  {
    let directory = installation.settings(home: home).deletingLastPathComponent().appending(
      path: "profiles")
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { FileManager.default.fileExists(atPath: $0.appending(path: "settings.json").path) }
    .map(\.lastPathComponent).sorted()
  }

  func preflight() throws {
    let installation = try discover(editor)
    try validateOwnership(editor, installation.settings(home: home))
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      let installation = try discover(editor)
      let profiles = try Self.profiles(installation: installation, home: home)
      return AdapterInspection(
        editor.runtimeKind,
        message:
          "\(editor.label): selected \(installation.application).app. Default profile only; workspace settings can override."
          + (profiles.isEmpty
            ? "" : " Non-default profiles with settings: \(profiles.joined(separator: ", "))."))
    } catch Failure.drift {
      return AdapterInspection(
        editor.runtimeKind, status: .drifted, message: Failure.drift.description)
    } catch {
      return AdapterInspection(
        editor.runtimeKind, status: .failed, message: String(describing: error))
    }
  }

  func reconciliation() -> AdapterReconciliation {
    OrdinaryAdapterRuntime(
      editor.runtimeKind, preflight: preflight,
      isIntegrationDrift: {
        if case Failure.drift = $0 { return true }
        return false
      }
    ).reconciliation {
      let installation = try discover(editor)
      let theme = try VSCodeTheme.active(root: root)
      if try Self.installedVersion(cli: installation.cli, runner: runner) != theme.version {
        try Self.withVSIX(theme: theme, runner: runner) { vsix in
          _ = try Self.command(
            installation.cli, ["--install-extension", vsix.path, "--force"], runner: runner)
        }
      }
      guard try Self.installedVersion(cli: installation.cli, runner: runner) == theme.version else {
        throw Failure.blocked(
          "\(editor.label) did not report the installed Macarchy extension version")
      }
      try publish(theme, installation: installation)
      try validateOwnership(editor, installation.settings(home: home))
      let profiles = try Self.profiles(installation: installation, home: home)
      let repaint =
        editor == .vscode
        ? "Run Developer: Reload Window to display an updated palette; first adoption can repaint live."
        : "Reload Window or next launch may be needed; this editor's live boundary is unqualified."
      return AdapterOutcome(
        status: .restartRequired,
        message:
          "\(editor.label): selected \(installation.application).app; extension installed. \(repaint) Macarchy never reloads the editor. Default profile only; workspace settings can override."
          + (profiles.isEmpty
            ? "" : " Non-default profiles with settings: \(profiles.joined(separator: ", ")).")
      )
    }
  }

  package static func uninstall(
    installation: VSCodeEditor.Installation, runner: ProcessRunner = .live
  ) throws {
    guard try installedVersion(cli: installation.cli, runner: runner) != nil else { return }
    _ = try command(installation.cli, ["--uninstall-extension", extensionID], runner: runner)
    guard try installedVersion(cli: installation.cli, runner: runner) == nil else {
      throw Failure.blocked(
        "\(installation.application) still reports the Macarchy extension after uninstall")
    }
  }

  package static func withVSIX<T>(
    theme: VSCodeTheme, runner: ProcessRunner = .live, body: (URL) throws -> T
  ) throws -> T {
    var template = Array(
      FileManager.default.temporaryDirectory.appending(path: "macarchy-vsix-XXXXXX").path
        .utf8CString)
    guard let path = mkdtemp(&template) else {
      throw Failure.blocked("Cannot create private VSIX directory")
    }
    let temporary = URL(filePath: String(cString: path))
    defer { try? FileManager.default.removeItem(at: temporary) }
    let payload = temporary.appending(path: "payload")
    let themes = payload.appending(path: "extension/themes")
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    try theme.package.write(to: payload.appending(path: "extension/package.json"))
    try theme.theme.write(to: themes.appending(path: "macarchy-color-theme.json"))
    let manifest = """
      <?xml version="1.0" encoding="utf-8"?>
      <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
        <Metadata><Identity Language="en-US" Id="macarchy-theme" Version="\(theme.version)" Publisher="macarchy"/><DisplayName>Macarchy</DisplayName><Description xml:space="preserve">Macarchy active palette</Description><Tags>theme</Tags><Categories>Themes</Categories><GalleryFlags>Public</GalleryFlags><Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.50.0"/></Properties></Metadata>
        <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation><Dependencies/>
        <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
      </PackageManifest>
      """
    try Data(manifest.utf8).write(to: payload.appending(path: "extension.vsixmanifest"))
    try Data(
      """
      <?xml version="1.0" encoding="utf-8"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="vsixmanifest" ContentType="text/xml"/></Types>
      """.utf8
    ).write(to: payload.appending(path: "[Content_Types].xml"))
    let vsix = temporary.appending(path: "macarchy.vsix")
    _ = try command(
      URL(filePath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", payload.path, vsix.path],
      runner: runner)
    return try body(vsix)
  }
}
