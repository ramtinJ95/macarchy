import Testing

@testable import MacarchyMenu

struct MenuCommandTests {
  @Test func checkNeverOpensTheMenuAndHelpNeverChecksPermission() throws {
    var checks = 0
    var opens = 0
    let command = MenuCommand(check: { checks += 1 }, open: { opens += 1 })
    #expect(try command.execute(["--help"]).contains("manually"))
    #expect(checks == 0 && opens == 0)
    #expect(try command.execute(["--check"]) == "ready")
    #expect(checks == 1 && opens == 0)
    #expect(try command.execute(["--open-apple-menu"]) == "")
    #expect(checks == 2 && opens == 1)
  }

  @Test func deniedPermissionOrUnsupportedPlatformCannotOpenMenu() {
    for failure in [MenuFailure.permission, .unsupported] {
      let command = MenuCommand(
        check: { throw failure }, open: { Issue.record("unauthorized menu action") })
      #expect(throws: MenuFailure.self) { try command.execute(["--open-apple-menu"]) }
    }
  }

  @Test(arguments: [[], ["--grant"], ["--open-apple-menu", "extra"]])
  func rejectsAnyUnreviewedInvocation(arguments: [String]) {
    let command = MenuCommand(
      check: { Issue.record("unexpected check") }, open: { Issue.record("unexpected action") })
    #expect(throws: InvalidMenuArguments.self) { try command.execute(arguments) }
  }
}
