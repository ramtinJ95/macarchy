import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test(arguments: ["valid", "disabled", "commented", "other-source", "missing"])
  func ezaRecognizesOnlyThePublishedNativeStarterAndItsActualDefaults(mode: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(root: root, adapterIDs: ["eza"])
    let defaults = root.appending(path: "environment/current/zsh/defaults.zsh")
    try FileManager.default.createDirectory(
      at: defaults.deletingLastPathComponent(), withIntermediateDirectories: true)
    if mode != "missing" {
      try
        (mode == "disabled" ? "# eza disabled\n" : "export EZA_CONFIG_DIR=\"$HOME/.config/eza\"\n")
        .write(to: defaults, atomically: true, encoding: .utf8)
    }
    let source = EnvironmentConfigurationComposer.nativeZshDefaultsSource(
      stateRoot: mode == "other-source" ? root.appending(path: "other") : root)
    try ((mode == "commented" ? "# " : "") + source + "\n")
      .write(to: paths.shellConfigurationURL, atomically: true, encoding: .utf8)
    let adapter = EzaAdapter(
      root: root, configurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      executableURL: URL(filePath: "/test/eza"), controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        Issue.record("inspection must not execute shell code")
        return ProcessResult(terminationStatus: 0, output: "")
      })
    #expect(
      adapter.inspection().status
        == (mode == "valid" ? .ready : mode == "missing" ? .failed : .drifted))
  }

  @Test
  func invocationBoundAdaptersUseCanonicalLinksAndExpectedProcesses() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(root: root, adapterIDs: ["eza", "bat"])
    let requests = Mutex([ProcessRequest]())
    let runner = ProcessRunner { request in
      requests.withLock { $0.append(request) }
      return ProcessResult(
        terminationStatus: 0,
        output: request.arguments.last == "--list-themes" ? BatAdapter.themeName : ""
      )
    }
    let ezaExecutable = URL(filePath: "/test/eza")
    let batExecutable = URL(filePath: "/test/bat")
    let eza = EzaAdapter(
      root: root,
      configurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      executableURL: ezaExecutable,
      controlIsAvailable: { true },
      processRunner: runner
    )
    let bat = BatAdapter(
      root: root,
      configurationDirectoryURL: paths.batConfigurationDirectoryURL,
      cacheDirectoryURL: paths.batCacheDirectoryURL,
      executableURL: batExecutable,
      controlIsAvailable: { true },
      processRunner: runner
    )

    #expect(eza.inspection().status == .ready)
    #expect(bat.inspection().status == .ready)
    #expect(try await eza.reconciliation().run().status == .applied)
    #expect(try await bat.reconciliation().run().status == .applied)
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: ezaExecutable,
            arguments: [
              "--color=always", "--oneline",
              paths.ezaConfigurationDirectoryURL.appending(path: "theme.yml").path,
            ],
            timeout: 1,
            environmentOverrides: [
              "EZA_CONFIG_DIR": paths.ezaConfigurationDirectoryURL.path
            ]
          ),
          ProcessRequest(
            executableURL: batExecutable,
            arguments: ["cache", "--build"],
            timeout: 5,
            environmentOverrides: [
              "BAT_CACHE_PATH": paths.batCacheDirectoryURL.path,
              "BAT_CONFIG_DIR": paths.batConfigurationDirectoryURL.path,
            ]
          ),
          ProcessRequest(
            executableURL: batExecutable,
            arguments: ["--no-config", "--color=never", "--paging=never", "--list-themes"],
            timeout: 5,
            environmentOverrides: [
              "BAT_CACHE_PATH": paths.batCacheDirectoryURL.path,
              "BAT_CONFIG_DIR": paths.batConfigurationDirectoryURL.path,
            ]
          ),
        ]
    )

    let ezaTheme = paths.ezaConfigurationDirectoryURL.appending(path: "theme.yml")
    try FileManager.default.removeItem(at: ezaTheme)
    try FileManager.default.createSymbolicLink(
      at: ezaTheme,
      withDestinationURL: root.appending(path: "wrong/eza.yml")
    )
    #expect(eza.inspection().status == .drifted)
    #expect(eza.inspection().message?.contains("must point to") == true)
  }

  @Test
  func ezaReadsAnExternallyLinkedShellConfiguration() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(root: root, adapterIDs: ["eza"])
    let external = root.appending(path: "dotfiles/.zshrc")
    try FileManager.default.createDirectory(
      at: external.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "export EZA_CONFIG_DIR=\"\(paths.ezaConfigurationDirectoryURL.path)\"\n".write(
      to: external,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.removeItem(at: paths.shellConfigurationURL)
    try FileManager.default.createSymbolicLink(
      at: paths.shellConfigurationURL,
      withDestinationURL: external
    )
    let eza = EzaAdapter(
      root: root,
      configurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      executableURL: URL(filePath: "/test/eza"),
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") }
    )

    #expect(eza.inspection().status == .ready)
  }

  @Test
  func invocationBoundAdaptersExposeUnavailableControlsAndRejectedCacheBuilds() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(root: root, adapterIDs: ["eza", "bat"])
    let unavailable = EzaAdapter(
      root: root,
      configurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      executableURL: URL(filePath: "/test/eza"),
      controlIsAvailable: { false },
      processRunner: ProcessRunner { _ in throw ReconciliationTestError.expectedFailure }
    )
    #expect(unavailable.inspection().status == .failed)
    #expect(unavailable.inspection().message?.contains("not executable") == true)

    let rejected = BatAdapter(
      root: root,
      configurationDirectoryURL: paths.batConfigurationDirectoryURL,
      cacheDirectoryURL: paths.batCacheDirectoryURL,
      executableURL: URL(filePath: "/test/bat"),
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 2, output: "invalid tmTheme")
      }
    )
    let outcome = try await rejected.reconciliation().run()
    #expect(outcome.status == .failed)
    #expect(outcome.message == "invalid tmTheme")
  }

  @Test(
    arguments: [
      ("1337\nMacarchy Current\nMonokai Extended (default)", .applied),
      ("1337\nMacarchy Current (default dark)", .applied),
      ("1337\nCatppuccin Mocha\nMonokai Extended (default)", .drifted),
    ] as [(String, AdapterStatus)])
  func batVerifiesTheRebuiltCacheListsTheManagedTheme(
    listedThemes: String,
    expected: AdapterStatus
  ) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(root: root, adapterIDs: ["bat"])
    let buildOutput = """
      Failed to load one or more themes from '\(paths.batConfigurationDirectoryURL.path)/themes' \
      (reason: 'IO error for operation on Catppuccin Mocha.tmTheme: No such file or directory')
      Writing theme set to \(paths.batCacheDirectoryURL.path)/themes.bin ... okay
      """
    let bat = BatAdapter(
      root: root,
      configurationDirectoryURL: paths.batConfigurationDirectoryURL,
      cacheDirectoryURL: paths.batCacheDirectoryURL,
      executableURL: URL(filePath: "/test/bat"),
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        ProcessResult(
          terminationStatus: 0,
          output: request.arguments.last == "--list-themes" ? listedThemes : buildOutput
        )
      }
    )

    let outcome = try await bat.reconciliation().run()

    #expect(outcome.status == expected)
    if expected == .drifted {
      #expect(outcome.message?.contains(buildOutput) == true)
      #expect(outcome.message?.contains("macarchy reconcile bat") == true)
    } else {
      #expect(outcome.message == "bat rebuilt its cache for the active palette")
    }
  }

  @Test
  func batReportsAFailedThemeListing() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(root: root, adapterIDs: ["bat"])
    let bat = BatAdapter(
      root: root,
      configurationDirectoryURL: paths.batConfigurationDirectoryURL,
      cacheDirectoryURL: paths.batCacheDirectoryURL,
      executableURL: URL(filePath: "/test/bat"),
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        request.arguments.last == "--list-themes"
          ? ProcessResult(terminationStatus: 1, output: "cache is unreadable")
          : ProcessResult(terminationStatus: 0, output: "")
      }
    )

    let outcome = try await bat.reconciliation().run()

    #expect(outcome.status == .failed)
    #expect(outcome.message == "cache is unreadable")
  }

}
