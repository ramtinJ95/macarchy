import Foundation
import Testing

@testable import MacarchyCLI

struct DependencyProfileTests {
  @Test
  func externalAtuinAndHerdrExecutablesSatisfyTheirCapabilityProbes() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-dependency-profile-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: home) }
    for path in [".atuin/bin/atuin", ".local/bin/herdr"] {
      let executable = home.appending(path: path)
      try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("#!/bin/sh\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
      )
    }

    let capabilities = DependencyProfile.personal(homeDirectory: home).capabilities
    #expect(capabilities.first { $0.id == "atuin" }?.isAvailable() == true)
    #expect(capabilities.first { $0.id == "herdr" }?.isAvailable() == true)
  }

  @Test
  func homebrewRequestsSeparateFormulaeAndCasksAndDisableGlobalSideEffects() {
    let plan = HomebrewInstallPlan(
      capabilities: [
        SetupCapability(
          id: "bat",
          category: .requiredAdapter,
          status: .missing,
          requirement: "bat",
          remediation: .formula("bat")
        ),
        SetupCapability(
          id: "codex",
          category: .optionalAdapter,
          status: .missing,
          requirement: "codex",
          remediation: .cask("codex")
        ),
      ]
    )

    #expect(plan.requests.count == 2)
    #expect(plan.requests[0].arguments == ["install", "--formula", "--no-ask", "bat"])
    #expect(plan.requests[1].arguments == ["install", "--cask", "--no-ask", "codex"])
    #expect(plan.requests.allSatisfy { $0.environmentOverrides == HomebrewInstallPlan.environment })
  }
}
