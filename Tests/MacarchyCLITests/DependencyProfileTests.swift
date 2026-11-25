import Foundation
import Synchronization
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

  @Test
  func postInstallFontGateUsesAFreshExactExecutable() throws {
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
          terminationStatus: 0, output: "registered")
      })
    #expect(result)
  }

  @Test(arguments: [true, false])
  func freshFontGateWaitsOnlyForMissingRegistration(eventuallyRegistered: Bool) throws {
    let clock = Mutex(0.0)
    let calls = Mutex(0)
    let capability = DependencyCapability(
      id: "font", category: .desktopSubstrate, probes: [.postScriptFont("Fixture")],
      remediation: .cask("font-meslo-lg-nerd-font"))
    do {
      let available = try capability.isAvailableWithFreshFonts(
        runner: ProcessRunner { request in
          calls.withLock { $0 += 1 }
          let time = clock.withLock { $0 }
          #expect(request.timeout == min(2, 5 - time))
          let registered = eventuallyRegistered && time >= 2
          return .init(
            terminationStatus: registered ? 0 : 1, output: registered ? "registered" : "missing")
        },
        now: { clock.withLock { $0 } },
        wait: { delay in
          #expect(delay > 0 && delay <= 0.5)
          clock.withLock { $0 += delay }
        })
      #expect(eventuallyRegistered && available)
      #expect(clock.withLock { $0 } == 2)
      #expect(calls.withLock { $0 } == 5)
    } catch DependencyFontVerificationError.registrationUnconfirmed(let names) {
      #expect(!eventuallyRegistered)
      #expect(names == ["Fixture"])
      #expect(clock.withLock { $0 } == 5)
      #expect(calls.withLock { $0 } == 10)
    }
  }

  @Test func fontRegistrationReportedAfterDeadlineIsNotAccepted() {
    let clock = Mutex(0.0)
    let capability = DependencyCapability(
      id: "font", category: .desktopSubstrate, probes: [.postScriptFont("Fixture")],
      remediation: .cask("font-meslo-lg-nerd-font"))
    #expect(throws: DependencyFontVerificationError.self) {
      try capability.isAvailableWithFreshFonts(
        runner: ProcessRunner { _ in
          clock.withLock { $0 = 5 }
          return .init(terminationStatus: 0, output: "registered")
        },
        now: { clock.withLock { $0 } },
        wait: { _ in Issue.record("Deadline must not sleep or retry") })
    }
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
      try capability.isAvailableWithFreshFonts(
        runner: ProcessRunner { _ in reply },
        wait: { _ in Issue.record("Invalid replies must not retry") })
    }
  }

  @Test func freshFontGatePropagatesTransportFailureAndDoesNotSpawnForOtherProbes() throws {
    let capability = DependencyCapability(
      id: "font", category: .desktopSubstrate, probes: [.postScriptFont("Missing")],
      remediation: .cask("font-meslo-lg-nerd-font"))
    struct Unavailable: Error {}
    #expect(throws: Unavailable.self) {
      try capability.isAvailableWithFreshFonts(
        runner: ProcessRunner { _ in throw Unavailable() },
        wait: { _ in Issue.record("Transport failures must not retry") })
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
