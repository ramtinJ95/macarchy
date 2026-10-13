import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

extension GuidedHomebrewTrust {
  static let testAlreadyTrusted = Self(
    missing: { _ in [] }, grant: { _ in Issue.record("Unexpected trust mutation") })
}

struct GuidedHomebrewTrustTests {
  @Test
  func nativeTrustIsExactFormulaOnlyAndRespectsExistingTrust() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let commands = Mutex([[String]]())
    let trust = GuidedHomebrewTrust.live(
      homeDirectory: fixture.home,
      runner: .init { request in
        #expect(request.executableURL.path == "/usr/bin/env")
        #expect(request.arguments.first == "-i")
        let brew = try #require(request.arguments.firstIndex(of: "/opt/homebrew/bin/brew"))
        let arguments = Array(request.arguments.dropFirst(brew + 1))
        commands.withLock { $0.append(arguments) }
        return .init(
          terminationStatus: 0,
          output: arguments.contains("--json=v1")
            ? #"{"taps":["trusted/tools"],"formulae":["vendor/tools/old"],"casks":[],"commands":[]}"#
            : "Trusted")
      })
    let missing = HomebrewPackageIdentity(kind: .formula, name: "vendor/tools/new")
    #expect(
      try trust.missing([
        .init(kind: .formula, name: "jq"),
        .init(kind: .cask, name: "vendor/tools/app"),
        .init(kind: .formula, name: "trusted/tools/tool"),
        .init(kind: .formula, name: "vendor/tools/old"), missing,
      ]) == [missing])
    try trust.grant(missing)
    #expect(
      commands.withLock { $0 } == [["trust", "--json=v1"], ["trust", "--formula", missing.name]])
    #expect(throws: (any Error).self) {
      try trust.grant(.init(kind: .cask, name: "vendor/tools/app"))
    }
    #expect(throws: (any Error).self) { try trust.grant(.init(kind: .formula, name: "jq")) }
    #expect(commands.withLock { $0.count } == 2)
  }

  @Test(arguments: ["bad json", #"{"formulae":[]}"#])
  func malformedTrustCannotBecomePermission(output: String) throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let trust = GuidedHomebrewTrust.live(
      homeDirectory: fixture.home,
      runner: .init { _ in
        .init(terminationStatus: 0, output: output)
      })
    #expect(throws: (any Error).self) {
      try trust.missing([.init(kind: .formula, name: "vendor/tools/tool")])
    }
  }

  @Test
  func interactiveBundleInheritsTerminalWithoutCredentialsOrAnAlternateCommand() {
    let brewfile = URL(filePath: "/tmp/reviewed.Brewfile")
    let process = HomebrewBundleInstaller.guidedProcess(
      brewfile: brewfile, homeDirectory: URL(filePath: "/tmp/home"))
    #expect(process.executableURL?.path == "/usr/bin/env")
    #expect(
      process.arguments?.suffix(6) == [
        "/opt/homebrew/bin/brew", "bundle", "install", "--no-upgrade", "--file", brewfile.path,
      ])
    #expect((process.standardInput as? FileHandle)?.fileDescriptor == 0)
    #expect((process.standardOutput as? FileHandle)?.fileDescriptor == 1)
    #expect((process.standardError as? FileHandle)?.fileDescriptor == 2)
    #expect(process.arguments?.contains("-i") == true)
    #expect(
      process.arguments?.contains { $0.contains("ASKPASS") || $0 == "sudo" || $0 == "trust" }
        == false)
  }
}
