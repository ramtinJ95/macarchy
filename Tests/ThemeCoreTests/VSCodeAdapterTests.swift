import Foundation
import Synchronization
import TestSupport
import Testing

@testable import ThemeCore

struct VSCodeAdapterTests {
  @Test(arguments: ["--list-extensions", "--install-extension", "--uninstall-extension"])
  func everyCLIInvocationStripsInheritedRedirection(flag: String) throws {
    let inherited = [
      "VSCODE_EXTENSIONS": "/foreign/extensions", "VSCODE_APPDATA": "/foreign/profile",
      "VSCODE_PORTABLE": "/foreign/portable", "VSCODE_CLI_REMOTE_ENV": "foreign",
      "VSCODE_IPC_HOOK_CLI": "/foreign/socket", "ELECTRON_RUN_AS_NODE": "1",
      "VSCODE_DEV": "1", "NODE_OPTIONS": "--require=/foreign/code.js", "HOME": "/foreign",
      "PATH": "/usr/bin:/bin",
    ]
    _ = try VSCodeAdapter.command(
      VSCodeEditor.vscode.installations[0].cli, [flag],
      runner: ProcessRunner { request in
        #expect(request.isolatedProcessGroup)
        #expect(request.timeout == 120)
        #expect(request.environmentRemovals.isSuperset(of: inherited.keys.filter { $0 != "PATH" }))
        #expect(!request.environmentRemovals.contains("PATH"))
        #expect(request.environmentOverrides.isEmpty)
        return .init(terminationStatus: 0, output: "")
      }, environment: inherited)
  }

  @Test(arguments: VSCodeEditor.allCases)
  func portableInstallationsAreRefusedIncludingForkOverrides(editor: VSCodeEditor) throws {
    for installation in editor.installations {
      for override in [false, true] {
        let name = override ? "custom-portable" : "editor-portable-data"
        let product = try JSONSerialization.data(
          withJSONObject:
            override
            ? ["applicationName": "editor", "portable": name] : ["applicationName": "editor"])
        #expect(throws: VSCodeAdapter.Failure.self) {
          try VSCodeEditor.refusePortableCLI(
            installation.cli,
            exists: { $0 == installation.applicationURL || $0.lastPathComponent == name },
            product: { _ in product })
        }
        try VSCodeEditor.refusePortableCLI(
          installation.cli, exists: { $0 == installation.applicationURL }, product: { _ in product }
        )
      }
    }
  }

  @Test func unreadablePortableMetadataBlocksRatherThanGuessing() {
    #expect(throws: (any Error).self) {
      try VSCodeEditor.refusePortableCLI(
        VSCodeEditor.vscode.installations[0].cli, exists: { _ in true }, product: { _ in Data() })
    }
  }

  @Test(arguments: ["catppuccin-mocha", "tokyo-night", "kanagawa-wave"])
  func renderMapsSemanticTerminalAndTokens(name: String) throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(name)"))
    let result = try VSCodeTheme.render(package: package)
    let object = try #require(
      try JSONSerialization.jsonObject(with: result.theme) as? [String: Any])
    let colors = try #require(object["colors"] as? [String: String])
    #expect(colors["editor.background"] == package.semantic.background.rawValue)
    #expect(colors["terminal.background"] == package.terminal.background.rawValue)
    #expect(colors["terminal.ansiBrightBlue"] == package.terminal.ansi[12].rawValue)
    #expect(colors.keys.filter { $0.hasPrefix("terminal.ansi") }.count == 16)
    #expect((object["tokenColors"] as? [Any])?.count == 8)
    let digestPrefix = sha256Digest(result.theme).dropFirst("sha256:".count).prefix(8)
    #expect(result.version == "1.0.\(UInt32(digestPrefix, radix: 16)!)")
    #expect(try VSCodeTheme.render(package: package).package == result.package)
    let manifest = try #require(
      try JSONSerialization.jsonObject(with: result.package) as? [String: Any])
    #expect(manifest["version"] as? String == result.version)
    #expect(manifest["main"] == nil)
    #expect(manifest["publisher"] as? String == "macarchy")
    let contributes = try #require(manifest["contributes"] as? [String: [[String: String]]])
    #expect(
      contributes["themes"]?.first?["uiTheme"] == (package.appearance == .dark ? "vs-dark" : "vs"))
  }

  @Test(arguments: VSCodeEditor.allCases)
  func discoveryUsesOnlyPairedBundledCLI(editor: VSCodeEditor) throws {
    for installation in editor.installations {
      let result = try editor.discover(
        exists: { $0 == installation.applicationURL }, executable: { $0 == installation.cli })
      #expect(result == installation)
      #expect(
        result.settings(home: URL(filePath: "/chosen")).path.hasPrefix(
          "/chosen/Library/Application Support/"))
      #expect(throws: AdapterConfigurationError.self) {
        try editor.discover(
          exists: { $0 == installation.applicationURL }, executable: { _ in false })
      }
    }
    #expect(throws: AdapterConfigurationError.self) { try editor.discover(exists: { _ in false }) }
    #expect(!ConsumerCatalog.shared.defaultEnabledAdapterIDs.contains(editor.rawValue))
    #expect(editor.runtimeKind.requirement == .required)
    #expect(editor.runtimeKind.repaint == (editor == .vscode ? .reloadWindow : .nextLaunch))
  }

  @Test func ambiguousWindsurfInstallationsBlock() {
    #expect(throws: VSCodeAdapter.Failure.self) {
      try VSCodeEditor.windsurf.discover(exists: { _ in true }, executable: { _ in true })
    }
  }

  @Test func archiveContainsOnlyTheThemeExtensionLayout() throws {
    let theme = try VSCodeTheme.render(
      package: ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")))
    var removed: URL?
    try VSCodeAdapter.withVSIX(theme: theme) { url in
      removed = url
      let result = try ProcessRunner.live.run(
        .init(
          executableURL: URL(filePath: "/usr/bin/unzip"), arguments: ["-Z1", url.path], timeout: 10)
      )
      #expect(result.terminationStatus == 0)
      let files = Set(
        result.output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") })
      #expect(
        files == [
          "extension/package.json", "extension/themes/macarchy-color-theme.json",
          "extension.vsixmanifest", "[Content_Types].xml",
        ])
      for (path, expected) in [
        ("extension/package.json", theme.package),
        ("extension/themes/macarchy-color-theme.json", theme.theme),
      ] {
        let output = try ProcessRunner.live.run(
          .init(
            executableURL: URL(filePath: "/usr/bin/unzip"), arguments: ["-p", url.path, path],
            timeout: 10))
        #expect(output.output + "\n" == String(decoding: expected, as: UTF8.self))
      }
    }
    #expect(!FileManager.default.fileExists(atPath: try #require(removed).path))
  }

  @Test func reconcileInstallsOnlyChangedVersionsAndUninstallsWithReadback() async throws {
    try await withTemporaryRoot(named: "vscode-cli") { root in
      let package = try ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))
      _ = try ThemeActivator(root: root).activate(package: package)
      let theme = try VSCodeTheme.active(root: root)
      let fake = FakeCLI(version: theme.version)
      let adapter = VSCodeAdapter(
        editor: .vscode, root: root, home: root,
        discover: { $0.installations[0] }, runner: fake.runner, validateOwnership: { _, _ in })
      let first = try await adapter.reconciliation().run()
      #expect(first.status == .restartRequired)
      #expect(first.message?.contains("Developer: Reload Window") == true)
      #expect(fake.state.withLock { $0.installs } == 1)
      #expect(try await adapter.reconciliation().run().status == .restartRequired)
      #expect(fake.state.withLock { $0.installs } == 1)
      let next = try ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
      _ = try ThemeActivator(root: root).activate(package: next)
      let nextVersion = try VSCodeTheme.render(package: next).version
      fake.state.withLock { $0.next = nextVersion }
      #expect(try await adapter.reconciliation().run().status == .restartRequired)
      #expect(fake.state.withLock { $0.installs } == 2)
      try adapter.authenticate(
        version: fake.state.withLock { $0.installed },
        installation: .init(
          application: "Visual Studio Code", cliName: "code", supportDirectory: "Code"),
        initialVersion: theme.version)
      try VSCodeAdapter.uninstall(
        installation: VSCodeEditor.vscode.installations[0], runner: fake.runner)
      #expect(fake.state.withLock { $0.installed } == nil)
    }
  }

  @Test(arguments: ["--list-extensions", "--install-extension", "--uninstall-extension"])
  func cliFailureIsNotSuccess(flag: String) async throws {
    try await withTemporaryRoot(named: "vscode-failure") { root in
      _ = try ThemeActivator(root: root).activate(
        package: ThemePackageLoader().load(
          packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")))
      let fake = FakeCLI(version: try VSCodeTheme.active(root: root).version)
      fake.state.withLock {
        $0.fail = flag
        if flag == "--uninstall-extension" { $0.installed = $0.next }
      }
      if flag == "--uninstall-extension" {
        #expect(throws: VSCodeAdapter.Failure.self) {
          try VSCodeAdapter.uninstall(
            installation: VSCodeEditor.vscode.installations[0], runner: fake.runner)
        }
        #expect(fake.state.withLock { $0.installed } != nil)
      } else {
        let adapter = VSCodeAdapter(
          editor: .vscode, root: root, home: root, discover: { $0.installations[0] },
          runner: fake.runner, validateOwnership: { _, _ in })
        await #expect(throws: VSCodeAdapter.Failure.self) {
          try await adapter.reconciliation().run()
        }
      }
    }
  }

  @Test func legacyGenerationRendersWithoutMutationAndPublicationSurvivesCollection() async throws {
    try await withTemporaryRoot(named: "vscode-legacy") { root in
      let package = try ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))
      let current = try ThemeActivator(root: root).activate(package: package)
      let generation = root.appending(path: "generations/\(current.generationID)")
      let manifestURL = generation.appending(path: "manifest.json")
      var object = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
      var versions = try #require(object["renderer_versions"] as? [String: Int])
      var artifacts = try #require(object["artifacts"] as? [String: String])
      versions.removeValue(forKey: "vscode")
      for path in VSCodeTheme.paths { artifacts.removeValue(forKey: path) }
      object["renderer_versions"] = versions
      object["artifacts"] = artifacts
      for path in VSCodeTheme.paths {
        let artifact = generation.appending(path: path)
        let parent = artifact.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        try FileManager.default.removeItem(at: artifact)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
      let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      try legacy.write(to: manifestURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444], ofItemAtPath: manifestURL.path)
      #expect(
        try VSCodeTheme.active(root: root).theme == VSCodeTheme.render(package: package).theme)
      #expect(try Data(contentsOf: manifestURL) == legacy)
      for path in VSCodeTheme.paths {
        #expect(!FileManager.default.fileExists(atPath: generation.appending(path: path).path))
      }
      let initial = try VSCodeTheme.active(root: root).version
      let next = try ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
      let nextManifest = try ThemeActivator(root: root).activate(package: next)
      let nextTheme = try VSCodeTheme.active(root: root)
      let fake = FakeCLI(version: nextTheme.version)
      let adapter = VSCodeAdapter(
        editor: .vscode, root: root, home: root, discover: { $0.installations[0] },
        runner: fake.runner, validateOwnership: { _, _ in })
      #expect(try await adapter.reconciliation().run().status == .restartRequired)
      let third = try ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/kanagawa-wave"))
      // Pointer changed; the adapter was not run.
      _ = try ThemeActivator(root: root).activate(package: third)
      _ = try ThemeActivator(root: root).activate(package: package)
      #expect(
        !FileManager.default.fileExists(
          atPath: root.appending(path: "generations/\(nextManifest.generationID)").path))
      try adapter.authenticate(
        version: nextTheme.version, installation: VSCodeEditor.vscode.installations[0],
        initialVersion: initial)
      #expect(throws: VSCodeAdapter.Failure.self) {
        try adapter.authenticate(
          version: "9.9.9", installation: VSCodeEditor.vscode.installations[0],
          initialVersion: initial)
      }
    }
  }

  @Test func profileSettingsAreReportedWithoutMutation() throws {
    try withTemporaryRoot(named: "vscode-profiles") { root in
      let install = VSCodeEditor.vscode.installations[0]
      let settings = install.settings(home: root).deletingLastPathComponent().appending(
        path: "profiles/user/settings.json")
      try FileManager.default.createDirectory(
        at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: settings)
      #expect(try VSCodeAdapter.profiles(installation: install, home: root) == ["user"])
      let adapter = VSCodeAdapter(
        editor: .vscode, root: root, home: root, discover: { $0.installations[0] },
        validateOwnership: { _, _ in })
      #expect(adapter.inspection().message?.contains("user") == true)
      #expect(try Data(contentsOf: settings) == Data("{}".utf8))
    }
  }

  private final class FakeCLI: Sendable {
    struct State {
      var installed: String?
      var next: String
      var installs = 0
      var fail: String?
    }
    let state: Mutex<State>
    init(version: String) { state = Mutex(State(next: version)) }
    var runner: ProcessRunner {
      ProcessRunner { [self] request in
        if request.executableURL.path == "/usr/bin/ditto" {
          return try ProcessRunner.live.run(request)
        }
        #expect(request.isolatedProcessGroup)
        #expect(
          request.environmentRemovals.isSuperset(of: [
            "VSCODE_EXTENSIONS", "VSCODE_APPDATA", "VSCODE_PORTABLE",
          ]))
        return state.withLock { value in
          let flag = request.arguments[0]
          if value.fail == flag { return .init(terminationStatus: 1, output: "injected failure") }
          switch flag {
          case "--list-extensions":
            return .init(
              terminationStatus: 0,
              output: value.installed.map { "macarchy.macarchy-theme@\($0)" } ?? "")
          case "--install-extension":
            value.installs += 1
            value.installed = value.next
          case "--uninstall-extension": value.installed = nil
          default: Issue.record("Unexpected CLI request: \(request)")
          }
          return .init(terminationStatus: 0, output: "")
        }
      }
    }
  }
}
