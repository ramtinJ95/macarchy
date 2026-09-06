import Foundation
import Testing

@testable import MacarchyCLI

struct HomebrewInstallationContractTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_FORMULA_EFFECTS"] == "1"))
  func realStagedBottlesProduceBoundedNativeEffectsWithoutInstallation() throws {
    let provider = HomebrewFormulaInstallProvider.live(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    let effects = try provider.prepare(["resvg", "jemalloc"])
    #expect(effects.components.map(\.name) == ["jemalloc", "resvg"])
    #expect(effects.links.contains { $0.path == "/opt/homebrew/bin/resvg" })
    #expect(effects.links.contains { $0.path == "/opt/homebrew/opt/jemalloc" })
    #expect(effects.footprint.first { $0.path == "/opt/homebrew" }?.inode != nil)
    #expect(
      effects.links.allSatisfy {
        !FileManager.default.fileExists(atPath: $0.path)
      })
    // This qualified host has an untrusted installed dependency. Native
    // dependent scanning must remain blocking, even when payload links resolve.
    #expect(effects.dependentIssue?.contains("Homebrew::UntrustedTapError") == true)
    #expect(throws: SetupPackageAdoptionError.self) {
      try effects.validate(roots: ["resvg", "jemalloc"])
    }
    #expect(!FileManager.default.fileExists(atPath: "/opt/homebrew/Cellar/resvg"))
    #expect(!FileManager.default.fileExists(atPath: "/opt/homebrew/Cellar/jemalloc"))
  }
}
