import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func invocationBoundAdaptersUseCanonicalLinksAndExpectedProcesses() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let kittyConfiguration = root.appending(path: "kitty.conf")
    try "include fixture.conf\n".write(
      to: kittyConfiguration,
      atomically: true,
      encoding: .utf8
    )
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: kittyConfiguration,
      sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)
    )
    let requests = Mutex([ProcessRequest]())
    let runner = ProcessRunner { request in
      requests.withLock { $0.append(request) }
      return ProcessResult(terminationStatus: 0, output: "")
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
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: root.appending(path: "kitty.conf"),
      sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)
    )
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
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: root.appending(path: "kitty.conf"),
      sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)
    )
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

}
