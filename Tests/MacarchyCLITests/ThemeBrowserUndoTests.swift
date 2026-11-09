import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI

struct ThemeBrowserUndoTests {
  @Test func undoRunsThemeUndoWithTheBrowsersOptionsAndAnAlert() throws {
    let spawned = Mutex<(URL, [String], [String: String])?>(nil)
    let launcher = ThemeBrowserApplyProcessLauncher(spawn: { url, arguments, environment in
      spawned.withLock { $0 = (url, arguments, environment) }
      return ThemeBrowserApplyProcessLauncher.RunningProcess(
        isRunning: { false }, terminationStatus: { 0 })
    })

    _ = try launcher.launchUndo(
      executableURL: URL(filePath: "/test/macarchy"),
      arguments: ["theme", "browse", "--state-root", "/test/state"],
      environment: ["PRESERVED": "yes"])

    let (url, arguments, environment) = try #require(spawned.withLock { $0 })
    #expect(url == URL(filePath: "/test/macarchy"))
    #expect(arguments == ["theme", "undo", "--alert-on-error", "--state-root", "/test/state"])
    #expect(environment == ["PRESERVED": "yes"])
  }

  @Test func undoRefusesArgumentsThatAreNotThemeBrowse() {
    let launcher = ThemeBrowserApplyProcessLauncher(spawn: { _, _, _ in
      Issue.record("Nothing may be spawned")
      return ThemeBrowserApplyProcessLauncher.RunningProcess(
        isRunning: { false }, terminationStatus: { 0 })
    })

    #expect(throws: ThemeBrowserApplyLaunchError.self) {
      _ = try launcher.launchUndo(
        executableURL: URL(filePath: "/test/macarchy"), arguments: ["browse"], environment: [:])
    }
  }
}
