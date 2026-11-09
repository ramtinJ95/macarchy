import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct MacOSIconStyleClientTests {
  @Test func helperCapabilityIsIndependentAndStateRoundTrips() throws {
    let fake = ProcessRunnerFake(replies: [
      .init(
        arguments: ["check"],
        output: #"{"ok":true,"value":{"accent":false,"iconStyle":true,"build":"25G83"}}"#),
      .init(
        arguments: ["get", "icon-style"], output: IconStyleFixtureValues.original.fixtureReply),
      .init(
        arguments: ["set", "icon-style", "TintedDark", "Other", "#0011ff"],
        output: IconStyleFixtureValues.applied.fixtureReply),
      .init(
        arguments: ["set", "icon-style", "RegularDark", "-"],
        output: MacOSIconStyle(style: "RegularDark", tint: "Other", custom: "#0011ff").fixtureReply),
    ])
    let helper = MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner)
    try helper.requireIconStyleSupport()
    #expect(try helper.iconStyle() == IconStyleFixtureValues.original)
    #expect(
      try helper.setIconStyle(IconStyleFixtureValues.applied) == IconStyleFixtureValues.applied)
    #expect(
      try helper.setIconStyle(.init(style: "RegularDark", tint: "-", custom: nil)).tint == "Other")
    #expect(fake.requests.allSatisfy { $0.timeout == 20 })
  }

  @Test(arguments: [
    #"{"accent":true,"iconStyle":true,"build":"unknown"}"#,
    #"{"accent":true,"iconStyle":false,"build":"25G83"}"#,
    #"{"accent":true,"build":"25G83"}"#,
  ])
  func untestedBuildAndUnavailableOrOlderHelpersCannotSet(capability: String) {
    let fake = ProcessRunnerFake(output: "{\"ok\":true,\"value\":\(capability)}")
    let helper = MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner)
    #expect(throws: MacOSLookError.self) { try helper.requireIconStyleSupport() }
    #expect(fake.requests.map(\.arguments) == [["check"]])
  }

  @Test(arguments: [
    #"{"style":"Unknown","tint":"None","custom":null}"#,
    #"{"style":"RegularLight","tint":"-","custom":null}"#,
    #"{"style":"RegularLight","tint":"None","custom":"bad"}"#,
    #"{"style":"RegularLight","tint":"None"}"#,
    #"{"style":"RegularLight","tint":"None","custom":123}"#,
  ])
  func malformedStoredTriplesFailExplicitly(value: String) {
    let helper = MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"),
      processRunner: ProcessRunnerFake(output: "{\"ok\":true,\"value\":\(value)}").runner)
    #expect(throws: MacOSLookError.self) { try helper.iconStyle() }
  }

  @Test func helperRevertFailureIsVisibleToTheCaller() {
    let helper = MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"),
      processRunner: ProcessRunnerFake(
        status: 1,
        output:
          #"{"ok":false,"error":"icon style readback mismatch; revert did not restore the original"}"#
      ).runner)
    #expect(
      throws: MacOSLookError.helperFailed(
        "icon style readback mismatch; revert did not restore the original")
    ) {
      try helper.setIconStyle(IconStyleFixtureValues.applied)
    }
  }
}
