import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func piPublishesAValidCustomThemeThroughItsWatchedCanonicalLink() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())

    let configuration = root.appending(path: "pi", directoryHint: .isDirectory)
    let themes = configuration.appending(path: "themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    try "{\"theme\":\"\(PiAdapter.themeName)\"}\n".write(
      to: configuration.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    let link = themes.appending(path: "\(PiAdapter.themeName).json")
    let destination = root.appending(path: "current/\(PiAdapter.outputPath)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)

    let adapter = PiAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: PiAdapter.liveExecutableURL,
      controlIsAvailable: { true }
    )
    let outcome = try await adapter.reconciliation().run()
    #expect(outcome.status == .applied)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination.path)

    let document = try jsonObject(Data(contentsOf: destination))
    #expect(document["name"] as? String == PiAdapter.themeName)
    let colors = try #require(document["colors"] as? [String: String])
    #expect(colors["accent"] == "accent")
    #expect(colors["thinkingMax"] == "error")
    let export = try #require(document["export"] as? [String: String])
    #expect(
      export
        == [
          "pageBg": "background",
          "cardBg": "userMessageBg",
          "infoBg": "toolPendingBg",
        ])

    try "{\"theme\":\"dark\"}\n".write(
      to: configuration.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    #expect(adapter.inspection().status == .drifted)
  }

  @Test
  func agentTUIAdaptersPreserveBehaviorAndExposeTheirRealUpdateBoundaries() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: tokyoNightPackage())

    let herdrConfiguration = root.appending(path: "herdr/config.toml")
    try FileManager.default.createDirectory(
      at: herdrConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let originalHerdr = """
      onboarding = false
      [theme]
      name = "catppuccin" # preserve this note
      [terminal]
      shell_mode = "auto"

      """
    try originalHerdr.write(to: herdrConfiguration, atomically: true, encoding: .utf8)
    let requests = Mutex([ProcessRequest]())
    let herdr = HerdrAdapter(
      root: root,
      configurationURL: herdrConfiguration,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return request.arguments == ["--version"]
          ? ProcessResult(terminationStatus: 0, output: "herdr 0.8.0")
          : ProcessResult(
            terminationStatus: 0,
            output: herdrReloadSuccess
          )
      }
    )
    let herdrOutcome = try await herdr.reconciliation().run()
    #expect(herdrOutcome.status == .applied)
    let updatedHerdr = try String(contentsOf: herdrConfiguration, encoding: .utf8)
    #expect(updatedHerdr.contains("name = \"tokyo-night\" # preserve this note"))
    #expect(updatedHerdr.contains("shell_mode = \"auto\""))
    #expect(
      try String(
        contentsOf: root.appending(path: "state/adapters/herdr-config.toml.backup"),
        encoding: .utf8) == originalHerdr
    )
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: HerdrAdapter.liveExecutableURL,
            arguments: ["--version"],
            timeout: 2
          ),
          ProcessRequest(
            executableURL: HerdrAdapter.liveExecutableURL,
            arguments: ["server", "reload-config"],
            timeout: 2
          ),
        ]
    )

    let tuicr = root.appending(path: "tuicr", directoryHint: .isDirectory)
    let codex = root.appending(path: "codex", directoryHint: .isDirectory)
    for directory in [tuicr, codex] {
      try FileManager.default.createDirectory(
        at: directory.appending(path: "themes", directoryHint: .isDirectory),
        withIntermediateDirectories: true
      )
    }
    try "theme = \"\(TuicrAdapter.themeName)\"\nwrap = true\n".write(
      to: tuicr.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try "[tui]\ntheme = \"\(CodexAdapter.themeName)\"\nstatus_line_use_colors = true\n".write(
      to: codex.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: tuicr.appending(path: "themes/\(TuicrAdapter.themeName).toml"),
      withDestinationURL: root.appending(path: "current/\(TuicrAdapter.outputPath)")
    )
    for link in [
      tuicr.appending(path: "themes/\(TuicrAdapter.themeName).tmTheme"),
      codex.appending(path: "themes/\(CodexAdapter.themeName).tmTheme"),
    ] {
      try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: root.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
      )
    }

    let tuicrOutcome = try await TuicrAdapter(
      root: root,
      configurationDirectoryURL: tuicr,
      executableURL: TuicrAdapter.liveExecutableURL,
      controlIsAvailable: { true }
    ).reconciliation().run()
    let codexOutcome = try await CodexAdapter(
      root: root,
      configurationDirectoryURL: codex,
      executableURL: CodexAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(
          terminationStatus: 0,
          output: "codex-cli \(CodexAdapter.minimumVersion)"
        )
      }
    ).reconciliation().run()
    #expect(tuicrOutcome.status == .restartRequired)
    #expect(codexOutcome.status == .restartRequired)
  }

  @Test
  func herdrRetriesFailedReloadsAndRecognizesOnlyAConfirmedStoppedServer() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: tokyoNightPackage())
    let configuration = root.appending(path: "herdr/config.toml")
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "[theme]\nname = \"catppuccin\"\n".write(
      to: configuration, atomically: true, encoding: .utf8)

    let reloadAttempts = Mutex(0)
    let adapter = HerdrAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        if request.arguments == ["--version"] {
          return ProcessResult(terminationStatus: 0, output: "herdr 0.8.0")
        }
        if request.arguments == ["server", "reload-config"] {
          let attempt = reloadAttempts.withLock {
            $0 += 1
            return $0
          }
          return ProcessResult(
            terminationStatus: attempt == 1 ? 1 : 0,
            output: attempt == 1
              ? "reload denied"
              : herdrReloadSuccess
          )
        }
        return ProcessResult(terminationStatus: 0, output: "status: running")
      }
    )

    #expect(try await adapter.reconciliation().run().status == .failed)
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(reloadAttempts.withLock { $0 } == 2)

    let stopped = HerdrAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        request.arguments == ["--version"]
          ? ProcessResult(terminationStatus: 0, output: "herdr 0.8.0")
          : request.arguments == ["status", "server"]
            ? ProcessResult(terminationStatus: 0, output: "status: stopped")
            : ProcessResult(terminationStatus: 1, output: "server unavailable")
      }
    )
    let stoppedOutcome = try await stopped.reconciliation().run()
    #expect(stoppedOutcome.status == .applied)
    #expect(stoppedOutcome.message == "Herdr will use the active theme on next launch")
  }

  @Test
  func herdrAdoptsUpdatesAndRemovesOnlyItsCompleteCustomPalette() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let importedCatppuccin = packageWithoutNamedThemeMappings(try catppuccinPackage())
    _ = try testActivator(root: root).activate(package: importedCatppuccin)

    let configuration = root.appending(path: "herdr/config.toml")
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = """
      onboarding = false
      [theme]
      name = "tokyo-night" # preserve selector comment
      auto_switch = false
      [terminal]
      shell_mode = "auto"

      """
    try original.write(to: configuration, atomically: true, encoding: .utf8)

    let interrupted = HerdrAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: successfulHerdrProcessRunner(),
      faultInjector: { checkpoint in
        if checkpoint == .configurationWritten {
          throw ReconciliationTestError.expectedInterruption
        }
      }
    )
    #expect(try await interrupted.reconciliation().run().status == .failed)

    let adapter = HerdrAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: successfulHerdrProcessRunner()
    )
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(
      try String(
        contentsOf: root.appending(path: "state/adapters/herdr-config.toml.backup"),
        encoding: .utf8
      ) == original
    )

    var importedConfiguration = try String(contentsOf: configuration, encoding: .utf8)
    #expect(importedConfiguration.contains("name = \"catppuccin\" # preserve selector comment"))
    #expect(importedConfiguration.contains("[theme.custom]"))
    for key in HerdrAdapter.customKeys {
      #expect(importedConfiguration.contains("\n\(key) = \""))
    }

    importedConfiguration = importedConfiguration.replacingOccurrences(
      of: "onboarding = false",
      with: "onboarding = true # unrelated provider edit"
    )
    try importedConfiguration.write(to: configuration, atomically: true, encoding: .utf8)
    let importedTokyo = packageWithoutNamedThemeMappings(try tokyoNightPackage())
    _ = try testActivator(root: root).activate(package: importedTokyo)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let updated = try String(contentsOf: configuration, encoding: .utf8)
    #expect(updated.contains("onboarding = true # unrelated provider edit"))
    #expect(updated.contains("blue = \"#7aa2f7\""))
    #expect(
      try String(
        contentsOf: root.appending(path: "state/adapters/herdr-config.toml.backup"),
        encoding: .utf8
      ) == original
    )

    _ = try testActivator(root: root).activate(package: tokyoNightPackage())
    #expect(try await adapter.reconciliation().run().status == .applied)
    let restored = try String(contentsOf: configuration, encoding: .utf8)
    #expect(restored.contains("name = \"tokyo-night\" # preserve selector comment"))
    #expect(restored.contains("[theme.custom]"))
    #expect(restored.contains("onboarding = true # unrelated provider edit"))
    for key in HerdrAdapter.customKeys {
      #expect(!restored.contains("\n\(key) = "))
    }
    #expect(adapter.inspection().status == .ready)
    try FileManager.default.removeItem(
      at: root.appending(path: "state/adapters/herdr-config.toml.backup")
    )
    #expect(adapter.inspection().status == .failed)
  }

  @Test
  func herdrRejectsUnownedAndAmbiguousCustomPaletteShapes() throws {
    for configuration in [
      "[theme]\nname = \"catppuccin\"\n[theme.custom]\naccent = \"#ffffff\"\nunknown = \"#000000\"\n",
      "[theme]\nname = \"catppuccin\"\n[theme.custom]\n\"accent\" = \"#ffffff\"\n",
      "[theme]\nname = \"catppuccin\"\ncustom.accent = \"#ffffff\"\n",
      "[theme]\nname = \"catppuccin\"\n[theme.custom]\naccent = \"#ffffff\"\naccent = \"#000000\"\n",
      "[theme]\nname = \"catppuccin\"\n[theme.custom]\naccent = '#ffffff'\n",
    ] {
      #expect(throws: HerdrAdapterError.self) {
        try HerdrAdapter.validateConfiguration(configuration)
      }
    }

    try withTemporaryRoot(named: "macarchy-adapter-tests") { root in
      let package = packageWithoutNamedThemeMappings(try catppuccinPackage())
      _ = try testActivator(root: root).activate(package: package)
      let configuration = root.appending(path: "herdr/config.toml")
      try FileManager.default.createDirectory(
        at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "[theme]\nname = \"catppuccin\"\n[theme.custom]\naccent = \"#ffffff\"\n".write(
        to: configuration, atomically: true, encoding: .utf8)
      let adapter = HerdrAdapter(
        root: root,
        configurationURL: configuration,
        executableURL: HerdrAdapter.liveExecutableURL,
        controlIsAvailable: { true },
        processRunner: successfulHerdrProcessRunner()
      )

      #expect(throws: HerdrAdapterError.self) {
        try adapter.preflight(package: package)
      }
      #expect(adapter.inspection().status == .drifted)
    }
  }

  @Test
  func herdrResumesFirstImportBeforeBackupWithoutMutatingPreflight() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let package = packageWithoutNamedThemeMappings(try catppuccinPackage())
    _ = try testActivator(root: root).activate(package: package)
    let configuration = root.appending(path: "herdr/config.toml")
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = "[theme]\nauto_switch = false\n[terminal]\nshell_mode = \"auto\"\n"
    try original.write(to: configuration, atomically: true, encoding: .utf8)
    let backup = root.appending(path: "state/adapters/herdr-config.toml.backup")

    let interrupted = HerdrAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: successfulHerdrProcessRunner(),
      faultInjector: { checkpoint in
        if checkpoint == .ownershipPrepared {
          throw ReconciliationTestError.expectedInterruption
        }
      }
    )
    #expect(try await interrupted.reconciliation().run().status == .failed)
    #expect(!FileManager.default.fileExists(atPath: backup.path))

    #expect(throws: HerdrAdapterError.self) {
      try interrupted.preflight(package: package)
    }
    #expect(!FileManager.default.fileExists(atPath: backup.path))

    let retry = HerdrAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: successfulHerdrProcessRunner()
    )
    #expect(try await retry.reconciliation().run().status == .applied)
    #expect(try String(contentsOf: backup, encoding: .utf8) == original)
    let updated = try String(contentsOf: configuration, encoding: .utf8)
    #expect(updated.contains("name = \"catppuccin\""))
    #expect(updated.contains("[theme.custom]"))
  }

  @Test
  func agentTUIAdaptersRejectMalformedDocumentsConflictingModesAndWrongLinks() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())

    let tuicr = root.appending(path: "tuicr", directoryHint: .isDirectory)
    let codex = root.appending(path: "codex", directoryHint: .isDirectory)
    for directory in [tuicr, codex] {
      try FileManager.default.createDirectory(
        at: directory.appending(path: "themes", directoryHint: .isDirectory),
        withIntermediateDirectories: true
      )
    }
    try "theme = \"\(TuicrAdapter.themeName)\"\n[broken\n".write(
      to: tuicr.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: tuicr.appending(path: "themes/\(TuicrAdapter.themeName).toml"),
      withDestinationURL: root.appending(path: "current/\(TuicrAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: tuicr.appending(path: "themes/\(TuicrAdapter.themeName).tmTheme"),
      withDestinationURL: root.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
    )
    let tuicrAdapter = TuicrAdapter(
      root: root,
      configurationDirectoryURL: tuicr,
      executableURL: TuicrAdapter.liveExecutableURL,
      controlIsAvailable: { true }
    )
    #expect(tuicrAdapter.inspection().status == .failed)

    try "[tui]\ntheme = \"\(CodexAdapter.themeName)\"\n[tui]\n".write(
      to: codex.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    let codexTheme = codex.appending(path: "themes/\(CodexAdapter.themeName).tmTheme")
    try FileManager.default.createSymbolicLink(
      at: codexTheme,
      withDestinationURL: root.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
    )
    let codexAdapter = CodexAdapter(
      root: root,
      configurationDirectoryURL: codex,
      executableURL: CodexAdapter.liveExecutableURL,
      controlIsAvailable: { true }
    )
    #expect(codexAdapter.inspection().status == .failed)

    try "[tui]\ntheme = \"\(CodexAdapter.themeName)\"\n".write(
      to: codex.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: codexTheme)
    try FileManager.default.createSymbolicLink(
      at: codexTheme,
      withDestinationURL: root.appending(path: "current/generated/other.tmTheme")
    )
    #expect(codexAdapter.inspection().status == .drifted)

    let herdrConfiguration = root.appending(path: "herdr/config.toml")
    try FileManager.default.createDirectory(
      at: herdrConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "[theme]\nname = \"catppuccin\"\nauto_switch = true\n".write(
      to: herdrConfiguration, atomically: true, encoding: .utf8)
    let herdr = HerdrAdapter(
      root: root,
      configurationURL: herdrConfiguration,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: successfulHerdrProcessRunner()
    )
    #expect(herdr.inspection().status == .drifted)
    try "[theme]\nname = 42\n".write(
      to: herdrConfiguration, atomically: true, encoding: .utf8)
    #expect(herdr.inspection().status == .failed)
    try "[theme]\n\"name\" = \"catppuccin\"\n".write(
      to: herdrConfiguration, atomically: true, encoding: .utf8)
    #expect(herdr.inspection().status == .failed)
    try "[theme]\nname = \"\"\"\ncatppuccin\n\"\"\"\n".write(
      to: herdrConfiguration, atomically: true, encoding: .utf8)
    #expect(herdr.inspection().status == .failed)
  }

}

private func successfulHerdrProcessRunner() -> ProcessRunner {
  ProcessRunner { request in
    request.arguments == ["--version"]
      ? ProcessResult(terminationStatus: 0, output: "herdr 0.8.0")
      : ProcessResult(
        terminationStatus: 0,
        output: herdrReloadSuccess
      )
  }
}
