import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct MacOSLookTests {
  @Test(arguments: [
    ("#ff0000", MacOSAccent.red), ("#f38ba8", .pink), ("#e64553", .red), ("#fab387", .orange),
    ("#f9e2af", .yellow), ("#a6e3a1", .green), ("#94e2d5", .blue), ("#89dceb", .blue),
    ("#89b4fa", .blue), ("#cba6f7", .purple), ("#f5c2e7", .pink), ("#ff0080", .pink),
    ("#808080", .graphite), ("#7f8c8d", .graphite), ("#0a0a14", .graphite),
    ("#fdfdff", .graphite),
  ])
  func aColorMapsToTheNearestPresetByHue(hex: String, expected: MacOSAccent) throws {
    #expect(MacOSAccent.nearest(to: try #require(SRGBColor(rawValue: hex))) == expected)
  }

  @Test func theHelperReportsCapabilitiesAndTheStoredAccent() throws {
    let fake = ProcessRunnerFake(replies: [
      .init(arguments: ["check"], output: #"{"ok":true,"value":{"accent":true,"build":"25G83"}}"#),
      .init(arguments: ["get", "accent"], output: #"{"ok":true,"value":-1}"#),
      .init(arguments: ["set", "accent", "4"], output: #"{"ok":true,"value":4}"#),
    ])
    let helper = MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner)

    #expect(try helper.check() == .init(build: "25G83", accent: true))
    #expect(try helper.accent() == .graphite)
    #expect(try helper.setAccent(.blue) == .blue)
    try helper.requireAccentSupport()
    #expect(fake.requests.allSatisfy { $0.timeout == MacOSLookHelper.timeout })
  }

  @Test func anUntestedBuildOrMissingFunctionsAreUnsupported() throws {
    let untested = MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"),
      processRunner: ProcessRunnerFake(
        output: #"{"ok":true,"value":{"accent":true,"build":"25A1"}}"#
      ).runner)
    let missing = MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"),
      processRunner: ProcessRunnerFake(
        output: #"{"ok":true,"value":{"accent":false,"build":"25G83"}}"#
      ).runner)

    #expect(throws: MacOSLookError.untestedBuild("25A1")) { try untested.requireAccentSupport() }
    #expect(
      throws: MacOSLookError.unavailable(
        "the accent color functions are unavailable on macOS build 25G83")
    ) { try missing.requireAccentSupport() }
  }

  @Test func helperFailuresBecomeErrors() throws {
    func helper(status: Int32, output: String) -> MacOSLookHelper {
      MacOSLookHelper(
        executableURL: URL(filePath: "/usr/bin/true"),
        processRunner: ProcessRunnerFake(status: status, output: output).runner)
    }

    #expect(
      throws: MacOSLookError.helperFailed("accent read back 2, expected 4; reverted to -1")
    ) {
      try helper(
        status: 1,
        output: #"{"error":"accent read back 2, expected 4; reverted to -1","ok":false}"#
      ).setAccent(.blue)
    }
    #expect(throws: MacOSLookError.helperFailed("exited with status 139: Segmentation fault")) {
      try helper(status: 139, output: "Segmentation fault").accent()
    }
    #expect(throws: MacOSLookError.unreadableReply("hello")) {
      try helper(status: 0, output: "hello").accent()
    }
    #expect(throws: MacOSLookError.unreadableReply("9")) {
      try helper(status: 0, output: #"{"ok":true,"value":9}"#).accent()
    }
    #expect(throws: MacOSLookError.helperMissing("/nonexistent/macarchy-look")) {
      try MacOSLookHelper(executableURL: URL(filePath: "/nonexistent/macarchy-look")).accent()
    }
  }
}
