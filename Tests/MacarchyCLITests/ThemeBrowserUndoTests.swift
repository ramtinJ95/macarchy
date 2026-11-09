import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI

struct ThemeBrowserUndoTests {
  @Test func undoLauncherSpawnsTheSameCommandWithAnUndoRequestAndNoSelection() throws {
    let spawned = Mutex<(URL, [String], [String: String])?>(nil)
    let launcher = ThemeBrowserApplyProcessLauncher(spawn: { url, arguments, environment in
      spawned.withLock { $0 = (url, arguments, environment) }
      return ThemeBrowserApplyProcessLauncher.RunningProcess(
        isRunning: { false }, terminationStatus: { 0 })
    })
    let arguments = ["theme", "browse", "--state-root", "/test/state"]

    _ = try launcher.launchUndo(
      executableURL: URL(filePath: "/test/macarchy"),
      arguments: arguments,
      environment: [
        "PRESERVED": "yes",
        ThemeBrowserApplyRequest.themeEnvironmentKey: "tokyo-night",
        ThemeBrowserApplyRequest.backgroundEnvironmentKey: "default",
      ])

    let (url, spawnedArguments, environment) = try #require(spawned.withLock { $0 })
    #expect(url == URL(filePath: "/test/macarchy"))
    #expect(spawnedArguments == arguments)
    #expect(environment["PRESERVED"] == "yes")
    #expect(ThemeBrowserUndoRequest.isPresent(in: environment))
    #expect(ThemeBrowserApplyRequest(environment: environment) == nil)
  }

  @Test func onlyAnExplicitUndoRequestIsRecognized() {
    #expect(!ThemeBrowserUndoRequest.isPresent(in: [:]))
    #expect(!ThemeBrowserUndoRequest.isPresent(in: [ThemeBrowserUndoRequest.environmentKey: "0"]))
  }
}
