import Foundation
import Testing

@testable import MacarchyCLI

struct LeanBordersPreviewTests {
  @Test func rendererDefaultsToBorders() throws {
    #expect(try Borders.Preview.parse([]).renderer == .borders)
  }

  @Test func leanRendererIsAccepted() throws {
    let preview = try Borders.Preview.parse(["--renderer", "lean", "--dry-run"])
    #expect(preview.renderer == .lean)
    #expect(preview.dryRun)
  }

  @Test func unknownRendererIsRejected() {
    #expect(throws: (any Error).self) {
      try Borders.Preview.parse(["--renderer", "jankyborders"])
    }
  }

  @Test func leanKeepsTheBoundedDuration() {
    #expect(throws: (any Error).self) {
      try Borders.Preview.parse(["--renderer", "lean", "--seconds", "301"])
    }
  }

  @Test func helperIsSiblingOfRunningExecutable() {
    let helper = LeanBordersPreview.helperURL(
      beside: URL(filePath: "/build/release/macarchy"))
    #expect(helper.path == "/build/release/macarchy-focus-ring")
  }

  @Test func helperReceivesOnlyTheBoundedOptions() {
    #expect(
      LeanBordersPreview.helperArguments(stateRoot: "/state", seconds: 12, json: true)
        == ["--state-root", "/state", "--seconds", "12.0", "--json"])
    #expect(
      LeanBordersPreview.helperArguments(stateRoot: "/state", seconds: 12, json: false)
        == ["--state-root", "/state", "--seconds", "12.0"])
  }
}
