import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

struct EnvironmentSessionVerifierTests {
  @Test(arguments: [true, false])
  func verifiesInteractiveLoginWithoutAcquiringTheCallersTerminal(managed: Bool) throws {
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[shell]\nprovider = \"zsh\"\n",
      source: URL(filePath: "/tmp/profile.toml"))
    let results = EnvironmentSessionVerifier.verifyFreshSession(
      profile.environment, URL(filePath: "/tmp/session-home"), requireManagedMarker: managed,
      processRunner: ProcessRunner { request in
        #expect(request.arguments.prefix(4) == ["-l", "-i", "+m", "-c"])
        #expect(request.arguments.last?.contains("MACARCHY_MANAGED_SESSION") == managed)
        #expect(request.environmentOverrides["ZDOTDIR"] == "/tmp/session-home")
        #expect(request.timeout == 5)
        return ProcessResult(terminationStatus: 0, output: "")
      })
    #expect(results.map(\.status) == ["verified"])
  }
}
