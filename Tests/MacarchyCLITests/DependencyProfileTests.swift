import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

struct DependencyProfileTests {

  @Test func freshFontGateAcceptsTheLiveRunnersNormalizedOutput() throws {
    let capability = DependencyCapability(
      id: "font", category: .desktopSubstrate, probes: [.postScriptFont("Fixture")],
      remediation: .cask("font-meslo-lg-nerd-font"))
    // The child prints a line; ProcessRunner removes trailing whitespace. Exercise
    // that transport instead of teaching only the fake runner the reply protocol.
    #expect(
      try capability.isAvailableWithFreshFonts(
        runner: ProcessRunner { _ in
          try ProcessRunner.live.run(
            .init(executableURL: URL(filePath: "/bin/echo"), arguments: ["registered"], timeout: 2))
        }))
  }

  @Test(arguments: [true, false])
  func postInstallFontGateUsesAFreshExactExecutable(available: Bool) throws {
    let capability = DependencyCapability(
      id: "sketchybar-symbol-font", category: .desktopSubstrate,
      probes: [.postScriptFont("MesloLGSNFM-Regular"), .postScriptFont("MesloLGSNFM-Bold")],
      remediation: .cask("font-meslo-lg-nerd-font"))
    let executable = URL(filePath: "/owned/current/macarchy")
    let result = try capability.isAvailableWithFreshFonts(
      executableURL: executable,
      runner: ProcessRunner { request in
        #expect(request.executableURL == executable)
        #expect(
          request.arguments == [
            "setup", "_check-fonts", "MesloLGSNFM-Regular", "MesloLGSNFM-Bold",
          ])
        #expect(request.timeout == 2)
        return .init(
          terminationStatus: available ? 0 : 1, output: available ? "registered" : "missing")
      })
    #expect(result == available)
  }

  @Test(arguments: [
    ProcessResult(terminationStatus: 0, output: "missing"),
    ProcessResult(terminationStatus: 1, output: "registered"),
    ProcessResult(terminationStatus: 2, output: "error"),
    ProcessResult(terminationStatus: 0, output: ""),
  ])
  func freshFontGateRejectsInconsistentReplies(reply: ProcessResult) {
    let capability = DependencyCapability(
      id: "font", category: .desktopSubstrate, probes: [.postScriptFont("Missing")],
      remediation: .cask("font-meslo-lg-nerd-font"))
    #expect(throws: DependencyFontVerificationError.self) {
      try capability.isAvailableWithFreshFonts(runner: ProcessRunner { _ in reply })
    }
  }

  @Test func freshFontGatePropagatesTransportFailureAndDoesNotSpawnForOtherProbes() throws {
    let capability = DependencyCapability(
      id: "font", category: .desktopSubstrate, probes: [.postScriptFont("Missing")],
      remediation: .cask("font-meslo-lg-nerd-font"))
    struct Unavailable: Error {}
    #expect(throws: Unavailable.self) {
      try capability.isAvailableWithFreshFonts(runner: ProcessRunner { _ in throw Unavailable() })
    }
    let system = DependencyCapability(
      id: "system", category: .platformRuntime, probes: [.executable(URL(filePath: "/bin/sh"))],
      remediation: .external("none"))
    #expect(
      try system.isAvailableWithFreshFonts(
        runner: ProcessRunner { _ in
          Issue.record("Non-font capabilities must not spawn a font checker")
          throw Unavailable()
        }))
    #expect(throws: (any Error).self) {
      _ = try Macarchy.Setup.CheckFonts.parse([])
    }
  }

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
