import Foundation
import Synchronization
import TestSupport
import Testing

@testable import ThemeCore

struct GhosttyAdapterTests {
  @Test(arguments: ["catppuccin-mocha", "tokyo-night", "kanagawa-wave"])
  func renderingCoversTheTerminalPaletteAndBorder(theme: String) throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(theme)"))
    let text = GhosttyAdapter.render(package: package)
    let assignments = GhosttyConfiguration.assignments(text)
    #expect(assignments.count == 23)
    #expect(
      assignments.filter { $0.key == "palette" }.map(\.value)
        == package.terminal.ansi.enumerated().map { "\($0.offset)=\($0.element.rawValue)" })
    #expect(text.contains("split-divider-color = \(package.semantic.border.rawValue)\n"))
    #expect(text.contains("cursor-text = \(package.terminal.background.rawValue)\n"))
    #expect(ConsumerCatalog.shared.rendererVersions[GhosttyAdapter.id] == 1)
    #expect(!ConsumerCatalog.shared.defaultEnabledAdapterIDs.contains(GhosttyAdapter.id))
    #expect(RuntimeAdapterKind.ghostty.repaint == .live)
  }

  @Test(arguments: ["Ghostty 1.2.0", "Ghostty 1.4.0\n\nVersion information", "Ghostty 2.0.0+build"])
  func parsesReleasedVersions(output: String) {
    #expect(GhosttyAdapter.parseVersion(output) != nil)
  }

  @Test(arguments: [
    "", "1.4.0", "Ghostty unknown", "Ghostty 1.2", "Ghostty 1.2.bad", "Ghostty 1.2.0 extra",
    "Ghostty 1.2.0-dev",
  ])
  func unknownVersionsAreNotPretendedSupported(output: String) {
    #expect(GhosttyAdapter.parseVersion(output) == nil)
  }

  @Test func defaultFileOrderAndCustomXDG() throws {
    try withTemporaryRoot(named: "ghostty-paths") { home in
      let files = ThemeConsumerPaths.ghosttyConfigurationFiles(home: home, environment: [:])
      #expect(
        files.map(\.lastPathComponent) == ["config", "config.ghostty", "config", "config.ghostty"])
      #expect(try GhosttyConfiguration.selectedFile(in: files) == files[0])
      for file in files {
        try write("font-size = 14\n", to: file)
        #expect(try GhosttyConfiguration.selectedFile(in: files) == file)
      }
      let custom = ThemeConsumerPaths.ghosttyConfigurationFiles(
        home: home, environment: ["XDG_CONFIG_HOME": home.appending(path: "xdg").path])
      #expect(custom[0] == home.appending(path: "xdg/ghostty/config"))
      #expect(
        ThemeConsumerPaths.ghosttyConfigurationFiles(
          home: home, environment: ["XDG_CONFIG_HOME": "relative"]) == files)
    }
  }

  @Test func onlyIncludesLoadedAfterMacarchyOverrideItsColors() throws {
    try withTemporaryRoot(named: "ghostty-queue") { home in
      let state = home.appending(path: "state")
      let files = ThemeConsumerPaths.ghosttyConfigurationFiles(home: home, environment: [:])
      let include = GhosttyConfiguration.includeDirective(root: state)
      let directory = files[0].deletingLastPathComponent()
      try write(
        "background = #111111\nconfig-file = nested\n", to: directory.appending(path: "earlier"))
      try write(
        "foreground = #222222\nconfig-file = earlier\n", to: directory.appending(path: "nested"))
      try write("font-size = 15\n", to: directory.appending(path: "font-only"))
      try write(
        "config-file = earlier\n\(include)\nbackground = #333333\nconfig-file = ?missing\nconfig-file = font-only\n",
        to: files[0])
      let before = try Data(contentsOf: files[0])
      let message = try #require(
        GhosttyConfiguration.overrideMessage(files: files, root: state, home: home))
      #expect(message.contains("nested (foreground)"))
      #expect(!message.contains("earlier (background)"))
      #expect(!message.contains("missing"))
      #expect(!message.contains("font-only"))
      #expect(try Data(contentsOf: files[0]) == before)
      try write("config-file = \"\(directory.appending(path: "later").path)\"\n", to: files[3])
      try write("background = #444444\n", to: directory.appending(path: "later"))
      #expect(
        GhosttyConfiguration.overrideMessage(files: files, root: state, home: home)?.contains(
          "later (background)") == true)
    }
  }

  @Test func resetAndUnreadableIncludesAreVisibleAndInspectionIsBounded() throws {
    try withTemporaryRoot(named: "ghostty-reset") { home in
      let files = ThemeConsumerPaths.ghosttyConfigurationFiles(home: home, environment: [:])
      try write(
        "\(GhosttyConfiguration.includeDirective(root: home))\nconfig-file =\n", to: files[0])
      #expect(
        GhosttyConfiguration.overrideMessage(files: files, root: home, home: home)?.contains(
          "does not load") == true)
      try write(
        "\(GhosttyConfiguration.includeDirective(root: home))\nconfig-file = missing\n",
        to: files[0])
      #expect(
        GhosttyConfiguration.overrideMessage(files: files, root: home, home: home)?.contains(
          "not checked") == true)
      try write((0..<130).map { "config-file = file\($0)\n" }.joined(), to: files[0])
      #expect(
        GhosttyConfiguration.overrideMessage(files: files, root: home, home: home)?.contains(
          "128-file limit") == true)
    }
  }

  @Test(arguments: [
    ("Ghostty 1.4.0", true, AdapterStatus.applied), ("Ghostty 1.1.3", false, .restartRequired),
  ])
  func runningVersionControlsTheSignal(version: String, signals: Bool, status: AdapterStatus)
    async throws
  {
    try await withTemporaryRoot(named: "ghostty-runtime") { home in
      let requests = Mutex<[ProcessRequest]>([])
      let signalled = Mutex<[Int32]>([])
      let adapter = try fixture(
        home: home,
        runner: ProcessRunner { request in
          requests.withLock { $0.append(request) }
          return ProcessResult(
            terminationStatus: 0, output: request.arguments == ["--version"] ? version : "")
        }, processes: fakeProcesses(signal: { pid in signalled.withLock { $0.append(pid) } }))
      let result = try await adapter.reconciliation().run()
      #expect(result.status == status)
      #expect(signalled.withLock { $0 } == (signals ? [42] : []))
      #expect(requests.withLock { $0.allSatisfy { $0.arguments == ["--version"] } })
      if !signals { #expect(result.message?.contains("press ⌘⇧,") == true) }
    }
  }

  @Test func missingAppAndStoppedAppAreDistinct() async throws {
    try await withTemporaryRoot(named: "ghostty-presence") { home in
      let absent = try fixture(
        home: home, available: false,
        runner: ProcessRunner { _ in
          Issue.record("Missing Ghostty must not run a command")
          return ProcessResult(terminationStatus: 1, output: "")
        })
      #expect(absent.inspection().status == .failed)
      let stopped = try fixture(
        home: home,
        runner: ProcessRunner { request in
          Issue.record("Stopped Ghostty must not run a signal command")
          return ProcessResult(terminationStatus: 0, output: "Ghostty 1.4.0")
        }, processes: fakeProcesses(instances: []))
      let result = try await stopped.reconciliation().run()
      #expect(result.status == .applied)
      #expect(result.message?.contains("next launch") == true)
    }
  }

  @Test func removedOrMovedIncludeReportsRuntimeDrift() throws {
    try withTemporaryRoot(named: "ghostty-drift") { home in
      let adapter = try fixture(
        home: home,
        runner: ProcessRunner { _ in
          Issue.record("Inspection does not reload Ghostty")
          return ProcessResult(terminationStatus: 0, output: "")
        })
      let file = try #require(adapter.ownedConfigurationURL)
      try write("# moved\n\(GhosttyConfiguration.includeDirective(root: home))\n", to: file)
      #expect(adapter.inspection().status == .drifted)
      try FileManager.default.removeItem(at: file)
      #expect(adapter.inspection().status == .drifted)
    }
  }

  @Test(arguments: ["leaf", "ancestor"])
  func redirectedOwnedConfigurationIsRejected(kind: String) async throws {
    try await withTemporaryRoot(named: "ghostty-symlink") { home in
      let adapter = try fixture(
        home: home,
        runner: ProcessRunner { _ in
          Issue.record("Unsafe configuration must not reload Ghostty")
          return ProcessResult(terminationStatus: 0, output: "")
        })
      let file = try #require(adapter.ownedConfigurationURL)
      let original = kind == "leaf" ? file : file.deletingLastPathComponent()
      let target = home.appending(path: "redirected")
      try FileManager.default.moveItem(at: original, to: target)
      try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
      #expect(adapter.inspection().status == .failed)
      #expect(try await adapter.reconciliation().run().status == .failed)
    }
  }

  @Test func onlyExactBundleGUIProcessesAreSignalled() async throws {
    try await withTemporaryRoot(named: "ghostty-signal-targets") { home in
      let path = GhosttyAdapter.liveExecutableURL.resolvingSymlinksInPath().path
      let instances = [
        instance(42, path: path),
        instance(43, path: path),
        instance(44, path: "/tmp/other/ghostty"),
        instance(45, path: path, gui: false),
        instance(46, path: "/opt/homebrew/bin/ghostty", gui: false),
      ]
      let signalled = Mutex<[Int32]>([])
      let adapter = try fixture(
        home: home,
        runner: ProcessRunner { request in
          #expect(request.executableURL.path == path)
          #expect(request.arguments == ["--version"])
          return ProcessResult(terminationStatus: 0, output: "Ghostty 1.4.0")
        },
        processes: fakeProcesses(
          instances: instances, signal: { pid in signalled.withLock { $0.append(pid) } }))
      #expect(try await adapter.reconciliation().run().status == .applied)
      #expect(signalled.withLock { $0 } == [42, 43])
    }
  }

  @Test func reusedPIDIsNotSignalled() async throws {
    try await withTemporaryRoot(named: "ghostty-reused-pid") { home in
      let original = instance(42, path: GhosttyAdapter.liveExecutableURL.path)
      let adapter = try fixture(
        home: home,
        runner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "Ghostty 1.4.0") },
        processes: GhosttyProcesses(
          list: { [original] },
          observe: {
            ProcessIdentity(pid: $0, started: 999, executablePath: original.identity.executablePath)
          },
          signal: { _ in Issue.record("Reused PID must not be signalled") }))
      await #expect(throws: GhosttyProcesses.Failure.self) {
        try await adapter.reconciliation().run()
      }
    }
  }

  private func instance(_ pid: Int32, path: String, gui: Bool = true) -> GhosttyProcesses.Instance {
    .init(identity: ProcessIdentity(pid: pid, started: 123, executablePath: path), isGUI: gui)
  }

  private func fakeProcesses(
    instances supplied: [GhosttyProcesses.Instance]? = nil,
    signal: @escaping @Sendable (Int32) throws -> Void = { _ in }
  ) -> GhosttyProcesses {
    let instances =
      supplied ?? [
        instance(42, path: GhosttyAdapter.liveExecutableURL.resolvingSymlinksInPath().path)
      ]
    return GhosttyProcesses(
      list: { instances },
      observe: { pid in instances.first { $0.identity.pid == pid }?.identity },
      signal: signal)
  }

  private func fixture(
    home: URL, available: Bool = true, runner: ProcessRunner,
    processes: GhosttyProcesses? = nil
  ) throws
    -> GhosttyAdapter
  {
    let files = ThemeConsumerPaths.ghosttyConfigurationFiles(home: home, environment: [:])
    try write("\(GhosttyConfiguration.includeDirective(root: home))\n", to: files[0])
    try write(
      "background = #000000\n",
      to: StateLayout(root: home).currentThemeArtifact(GhosttyAdapter.outputPath))
    return GhosttyAdapter(
      root: home, home: home, configurationFiles: files,
      ownedConfigurationURL: files[0], ownedLineIndex: 0,
      executableURL: GhosttyAdapter.liveExecutableURL, controlIsAvailable: { available },
      processRunner: runner, processes: processes ?? fakeProcesses())
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
}
