import Testing

@testable import ThemeCore

struct AdapterTextSupportTests {
  @Test
  func exactLineMatchingTrimsHorizontalWhitespaceAndUsesOnlyLFSeparators() {
    let directive = "required directive"

    #expect(containsExactLine(directive, in: "other\n \trequired directive\t \n"))
    #expect(!containsExactLine(directive, in: "other\r\nrequired directive\r\n"))
    #expect(!containsExactLine(directive, in: "other\rrequired directive\r"))

    #expect(
      NeovimAdapter.containsIntegrationDirective(
        in: "\(NeovimAdapter.integrationDirective)\n"
      )
    )
    #expect(
      !NeovimAdapter.containsIntegrationDirective(
        in: "\(NeovimAdapter.integrationDirective)\r\n"
      )
    )
  }
}
