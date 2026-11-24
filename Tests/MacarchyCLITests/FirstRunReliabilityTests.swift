import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct FirstRunReliabilityTests {
  @Test(arguments: ["verification_timed_out", "failed", "drifted", "pending", "unsupported"])
  func onlyReadOnlyDeadlinesPermitConfigurationCommit(status: String) {
    let row = DesktopThemeAdapterStatus(
      adapterID: "atuin", requirement: "required", status: status, message: "probe")
    #expect(permitsEnvironmentConfigurationCommit([row]) == (status == "verification_timed_out"))
    #expect(!isAcceptedEnvironmentThemeStatus(row))
    #expect((pendingEnvironmentThemeMessage([row]) != nil) == (status == "verification_timed_out"))
    let optional = DesktopThemeAdapterStatus(
      adapterID: "spicetify", requirement: "optional", status: status, message: "probe")
    #expect(permitsEnvironmentConfigurationCommit([optional]))
    #expect(pendingEnvironmentThemeMessage([optional]) == nil)
    let hardFailure = DesktopThemeAdapterStatus(
      adapterID: "starship", requirement: "required", status: "failed", message: "bad output")
    #expect(!permitsEnvironmentConfigurationCommit([row, hardFailure]))
  }

  @Test func readOnlyInspectionDoesNotEraseAnUnfinishedVerification() {
    let row = DesktopThemeAdapterStatus(
      adapterID: "atuin", requirement: "required", status: "ready", message: "seam exists")
    let deadline = AdapterResult(
      adapterID: "atuin", requirement: .required, status: .verificationTimedOut,
      message: "not yet converged; macarchy reconcile atuin")
    let inspected = preservingUnfinishedThemeVerification([row], results: [deadline])
    #expect(inspected.first?.status == "verification_timed_out")
    #expect(!inspected.allSatisfy(isAcceptedEnvironmentThemeStatus))
    #expect(hasRequiredReconciliationFailure([deadline]))
    #expect(
      !hasRequiredReconciliationFailure([
        .init(adapterID: "atuin", requirement: .required, status: .applied)
      ]))
    #expect(preservingUnfinishedThemeVerification([row], results: []) == [row])
    let drift = DesktopThemeAdapterStatus(
      adapterID: "atuin", requirement: "required", status: "drifted", message: "real drift")
    #expect(preservingUnfinishedThemeVerification([drift], results: [deadline]) == [drift])
  }

  @Test(arguments: [true, false])
  func unifiedApplyCommitsIncompleteVerificationButRollsBackRealFailure(timeout: Bool) async throws
  {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let events = Mutex([String]())
    let planner = fixture.planner()
    let finalizer = UnifiedSetupTeardownCommandRunner(
      planner: planner,
      environmentTeardown: { _, _, _ in throw UnexpectedComponentCall() },
      desktopTeardown: { _, _, _ in throw UnexpectedComponentCall() },
      themeTeardown: { _, _, _, _ in
        events.withLock { $0.append("theme rollback") }
        return .noChange("theme restored")
      },
      environmentApplyFinalization: { _, commit in
        events.withLock { $0.append(commit ? "commit" : "rollback") }
        return .noChange(commit ? "committed" : "restored")
      })
    let message =
      timeout
      ? "atuin is not yet converged; macarchy reconcile atuin" : "atuin rejected bad output"
    let runner = fixture.runner(
      available: { _ in true }, plannedStages: [.environment],
      theme: { _, _ in themeReportStub() },
      desktop: { _, _, _, _, _ in throw UnexpectedComponentCall() },
      environment: { _, _, _, _, _ in
        environmentReportStub(timeout ? "applied_incomplete" : "failed", message: message)
      }, transactionTeardown: finalizer,
      restoredSessionVerifier: .init(
        { _, _ in
          Issue.record("No managed session check in rollback")
          return []
        },
        verifyRestored: { _, _ in
          #expect(events.withLock { $0 } == ["rollback", "theme rollback"])
          events.withLock { $0.append("verify restored") }
          return [.init(id: "zsh", status: "verified", message: "original restored")]
        }))
    let result = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), json: true)
    let object = try jsonObject(result.output)
    #expect(result.succeeded == timeout, "\(result.output)")
    #expect(object["outcome"] as? String == (timeout ? "applied_incomplete" : "rolled_back"))
    #expect(result.output.contains(message))
    #expect(
      events.withLock { $0 }
        == (timeout ? ["commit"] : ["rollback", "theme rollback", "verify restored"]))
    if !timeout { #expect(result.output.contains("restored fresh session was verified")) }
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
    // No real activation/pointer/activation mutex for policy or aggregate fixture tests.
    #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "current").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appending(path: "run/activation.lock").path))
  }

  @Test func finalRestorationDiagnosticsDistinguishFilesFromNativeStartup() {
    #expect(restoredSessionMessage([]).isEmpty)
    #expect(
      restoredSessionMessage([
        .init(id: "zsh", status: "verified", message: "ready")
      ]).contains("after unified restoration"))
    let warning = restoredSessionMessage([
      .init(id: "zsh", status: "failed", message: "user include is missing")
    ])
    #expect(warning.contains("Configuration files were restored"))
    #expect(warning.contains("native startup still requires attention"))
    #expect(warning.contains("user include is missing"))
    #expect(!warning.contains("was verified"))
  }
}
