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
}
