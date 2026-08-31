import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func tuiAdaptersUseCanonicalThemesAndTheirHighestAvailableUpdateBoundaries() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: root.appending(path: "unused-kitty.conf"),
      sketchyBarConfigurationURL: root.appending(path: "unused-sketchybarrc")
    )
    let btopDirectory = paths.btopConfigurationDirectoryURL
    let yaziDirectory = paths.yaziConfigurationDirectoryURL
    let atuinDirectory = paths.atuinConfigurationDirectoryURL
    let btopLink = btopDirectory.appending(
      path: "themes/\(BtopAdapter.themeName).theme")

    let calls = Mutex([ProcessRequest]())
    let runner = ProcessRunner { request in
      calls.withLock { $0.append(request) }
      if request.executableURL == URL(filePath: "/test/atuin") {
        return ProcessResult(terminationStatus: 0, output: AtuinAdapter.themeName)
      }
      return ProcessResult(terminationStatus: 0, output: "")
    }
    let btop = BtopAdapter(
      root: root,
      configurationDirectoryURL: btopDirectory,
      executableURL: URL(filePath: "/test/btop"),
      controlIsAvailable: { true },
      processRunner: runner
    )
    let yazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: yaziDirectory,
      executableURL: URL(filePath: "/test/yazi"),
      controlURL: URL(filePath: "/test/ya"),
      controlsAreAvailable: { true },
      processRunner: runner
    )
    let atuin = AtuinAdapter(
      root: root,
      configurationDirectoryURL: atuinDirectory,
      executableURL: URL(filePath: "/test/atuin"),
      controlIsAvailable: { true },
      processRunner: runner
    )
    try "color_theme = \"\(BtopAdapter.themeName)\"\r\n".write(
      to: btopDirectory.appending(path: "btop.conf"), atomically: true, encoding: .utf8)
    try "[flavor]\r\nlayout = [\r\n  [\"name\"]\r\n]\r\ndark = \"\(YaziAdapter.flavorName)\"\r\n"
      .write(
        to: yaziDirectory.appending(path: "theme.toml"), atomically: true, encoding: .utf8)
    try "[theme]\r\nname = \"\(AtuinAdapter.themeName)\"\r\n".write(
      to: atuinDirectory.appending(path: "config.toml"), atomically: true, encoding: .utf8)

    #expect(try await btop.reconciliation().run().status == .applied)
    #expect(try await yazi.reconciliation().run().status == .applied)
    #expect(try await atuin.reconciliation().run().status == .applied)
    #expect(
      calls.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/killall"),
            arguments: ["-USR2", "btop"]
          ),
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/killall"),
            arguments: ["-0", "yazi"]
          ),
          ProcessRequest(
            executableURL: URL(filePath: "/test/ya"),
            arguments: ["emit-to", "0", "theme"],
            timeout: 1
          ),
          ProcessRequest(
            executableURL: URL(filePath: "/test/atuin"),
            arguments: ["config", "get", "theme.name"],
            timeout: 1,
            environmentOverrides: ["ATUIN_CONFIG_DIR": atuinDirectory.path]
          ),
        ]
    )

    try FileManager.default.removeItem(at: btopLink)
    try FileManager.default.createSymbolicLink(
      at: btopLink, withDestinationURL: root.appending(path: "wrong/btop.theme"))
    #expect(btop.inspection().status == .drifted)
    try FileManager.default.removeItem(at: btopLink)
    try FileManager.default.createSymbolicLink(
      at: btopLink,
      withDestinationURL: root.appending(path: "current/\(BtopAdapter.outputPath)"))
    try "color_theme = \"\"\(BtopAdapter.themeName)\"\"\n".write(
      to: btopDirectory.appending(path: "btop.conf"), atomically: true, encoding: .utf8)
    #expect(btop.inspection().status == .drifted)
    try "[flavor]\ndark = \"other\"\n".write(
      to: yaziDirectory.appending(path: "theme.toml"), atomically: true, encoding: .utf8)
    #expect(yazi.inspection().status == .drifted)
    try "[theme]\nname = \"other\"\n".write(
      to: atuinDirectory.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    #expect(atuin.inspection().status == .drifted)

    #expect(
      BtopAdapter(
        root: root,
        configurationDirectoryURL: btopDirectory,
        executableURL: URL(filePath: "/test/btop"),
        controlIsAvailable: { false },
        processRunner: runner
      ).inspection().status == .failed
    )
    #expect(
      YaziAdapter(
        root: root,
        configurationDirectoryURL: yaziDirectory,
        executableURL: URL(filePath: "/test/yazi"),
        controlURL: URL(filePath: "/test/ya"),
        controlsAreAvailable: { false },
        processRunner: runner
      ).inspection().status == .failed
    )
    #expect(
      AtuinAdapter(
        root: root,
        configurationDirectoryURL: atuinDirectory,
        executableURL: URL(filePath: "/test/atuin"),
        controlIsAvailable: { false },
        processRunner: runner
      ).inspection().status == .failed
    )
  }

  @Test
  func tuiAdaptersExposeReloadRejectionAndProcessExit() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: root.appending(path: "unused-kitty.conf"),
      sketchyBarConfigurationURL: root.appending(path: "unused-sketchybarrc")
    )
    let denied = ProcessRunner { request in
      if request.executableURL == URL(filePath: "/usr/bin/killall"),
        request.arguments.first == "-0"
      {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      return ProcessResult(terminationStatus: 1, output: "reload denied")
    }
    let deniedBtop = BtopAdapter(
      root: root,
      configurationDirectoryURL: paths.btopConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/btop"),
      controlIsAvailable: { true },
      processRunner: denied
    )
    let deniedYazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: paths.yaziConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/yazi"),
      controlURL: URL(filePath: "/test/ya"),
      controlsAreAvailable: { true },
      processRunner: denied
    )
    let deniedAtuin = AtuinAdapter(
      root: root,
      configurationDirectoryURL: paths.atuinConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/atuin"),
      controlIsAvailable: { true },
      processRunner: denied
    )

    let btopFailure = try await deniedBtop.reconciliation().run()
    let yaziFailure = try await deniedYazi.reconciliation().run()
    let atuinFailure = try await deniedAtuin.reconciliation().run()
    #expect(btopFailure.status == .failed)
    #expect(btopFailure.message == "reload denied")
    #expect(yaziFailure.status == .failed)
    #expect(yaziFailure.message == "reload denied")
    #expect(atuinFailure.status == .failed)
    #expect(atuinFailure.message == "reload denied")

    let yaziProbes = Mutex(0)
    let exited = ProcessRunner { request in
      if request.arguments == ["-0", "yazi"] {
        return yaziProbes.withLock { count in
          count += 1
          return ProcessResult(terminationStatus: count == 1 ? 0 : 1, output: "")
        }
      }
      return ProcessResult(terminationStatus: 1, output: "no matching process")
    }
    let exitedBtop = BtopAdapter(
      root: root,
      configurationDirectoryURL: paths.btopConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/btop"),
      controlIsAvailable: { true },
      processRunner: exited
    )
    let exitedYazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: paths.yaziConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/yazi"),
      controlURL: URL(filePath: "/test/ya"),
      controlsAreAvailable: { true },
      processRunner: exited
    )

    let btopExit = try await exitedBtop.reconciliation().run()
    let yaziExit = try await exitedYazi.reconciliation().run()
    #expect(btopExit.status == .applied)
    #expect(btopExit.message == "btop will use the active palette on next launch")
    #expect(yaziExit.status == .applied)
    #expect(yaziExit.message == "Yazi will use the active palette on next launch")
  }

}
