import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct NeovimLateColorschemeTests {
  @Test(
    .enabled(
      if: FileManager.default.isExecutableFile(atPath: NeovimAdapter.liveExecutableURL.path),
      "Needs Neovim"))
  func aColorschemePickedByAPluginAfterStartupIsReplacedButTheUsersChoicesStay() throws {
    try withTemporaryRoot(named: "macarchy-neovim-late-colorscheme") { root in
      let result = try ProcessRunner.live.run(
        ProcessRequest(
          executableURL: NeovimAdapter.liveExecutableURL,
          arguments: [
            "--clean", "--headless", "-i", "NONE", "-l",
            repositoryRoot.appending(path: "Tests/Fixtures/NeovimLateColorscheme/check.lua").path,
            repositoryRoot.path,
          ],
          timeout: 10,
          environmentOverrides: [
            "HOME": root.path, "NVIM_APPNAME": "nvim",
            "XDG_CONFIG_HOME": root.appending(path: "config").path,
            "XDG_STATE_HOME": root.appending(path: "state").path,
            "XDG_CACHE_HOME": root.appending(path: "cache").path,
            "XDG_DATA_HOME": root.appending(path: "data").path,
          ]))

      #expect(result.terminationStatus == 0, "\(result.output)")
      #expect(result.output.contains("Late colorscheme checks passed"))
    }
  }
}
