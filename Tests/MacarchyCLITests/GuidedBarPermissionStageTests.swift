import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct GuidedBarPermissionStageTests {
  @Test(arguments: [-1743, -1744, -1712])
  func absentAutomationIsDifferentFromAProbeFailure(code: Int32) throws {
    let result = SetupAppearanceCheck.inspect {
      throw MacOSAppearanceEvents.Failure("native result", code: code)
    }
    #expect(result.exitStatus == (code == -1712 ? 1 : 77))
    #expect(result.status == (code == -1712 ? .failed : .notGranted))
    #expect(result.code == code)
    #expect(try renderJSON(result).contains(code == -1712 ? "failed" : "not_granted"))
  }

  @Test func successfulAppearanceCheckOnlyInvokesTheNonpromptingVerifier() {
    let calls = Mutex(0)
    let result = SetupAppearanceCheck.inspect { calls.withLock { $0 += 1 } }
    #expect(result.status == .verified && result.exitStatus == 0)
    #expect(calls.withLock { $0 } == 1)
  }

  @Test(arguments: [
    "permission:v2:old:complete:100:101:0", "permission:v2:token:complete:100:99:0",
    "permission:v2:token:complete:nan:101:0", "permission:v2:token:complete:100:inf:0",
    "permission:v2:token:complete:0:101:0", "permission:v2:token:complete:100:101:-1",
    "permission:v2:token:complete:100:101:999", "permission:granted:token",
  ])
  func malformedAndStaleMarkersNeverVerifyPermission(marker: String) {
    #expect(GuidedBarPermissionStage.decode(marker, token: "token") == nil)
  }

  @Test(arguments: [
    "slow-automation", "slow-ax", "stale", "query-error", "query-deadline", "service-change",
    "updates",
  ])
  func stagesRemainIndependentAndTimeoutsHaveActionableNames(mode: String) throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let token = Mutex("")
    let clock = Mutex(0.0)
    let queries = Mutex(0)
    let markerWrites = Mutex([[String]]())
    let expected = fixture.state.appending(path: "desktop/sketchybar/current/plugins/apple.sh").path
    let generation = SketchyBarGenerationInspection(
      status: .current, generationID: "generation", manifest: nil, message: "current")
    let inspections = Mutex(0)
    let service: @Sendable () throws -> SketchyBarRuntimeInspection = {
      let index = inspections.withLock {
        $0 += 1
        return $0
      }
      return .init(
        status: .running, message: "running",
        processID: mode == "service-change" && index > 1 ? 124 : 123,
        executablePath: "/installed/sketchybar", serviceLabel: "sh.brew.sketchybar")
    }
    func check() throws -> GuidedBarPermissions {
      try GuidedSetupPermissions.verifyBar(
        context: fixture.context,
        runner: ProcessRunner { request in
          let args = request.arguments
          if args.first == "--set" {
            markerWrites.withLock { $0.append(args) }
            return .init(terminationStatus: 0, output: "")
          }
          if args.first == "--trigger" {
            token.withLock { $0 = String(args[2].dropFirst("MACARCHY_PERMISSION_TOKEN=".count)) }
            return .init(terminationStatus: 0, output: "")
          }
          let marker = args[1] == SketchyBarContract.readyItem
          let count =
            marker
            ? queries.withLock {
              $0 += 1
              return $0
            } : 0
          if (mode == "query-error" || mode == "query-deadline") && count > 1 {
            if mode == "query-deadline" { clock.withLock { $0 = 10 } }
            throw ProcessRunnerError.timedOut(request.executableURL, request.timeout!)
          }
          let challenge = mode == "stale" ? "old" : token.withLock { $0 }
          let prefix = "permission:v2:\(challenge):"
          let ax = mode == "slow-ax" ? "running:100:0:-1" : "complete:100:100.2:0"
          let automation =
            mode == "slow-automation" || mode == "query-error" || mode == "query-deadline"
            ? "running:100:0:-1" : "complete:100:100.7:77"
          let json: [String: Any] = [
            "name": args[1], "type": "item",
            "geometry": ["drawing": "off", "position": "right", "associated_space_mask": 0],
            // Presentation deliberately disagrees: it must not be permission evidence.
            "label": ["value": marker ? prefix + ax : "Menu ERR", "drawing": "on"],
            "icon": ["value": prefix + automation, "drawing": "off"],
            "scripting": [
              "script": expected, "click_script": "", "update_freq": 0,
              "updates": mode == "updates" ? "when_shown" : "on",
            ],
          ]
          return .init(
            terminationStatus: 0,
            output: String(
              decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        }, generationInspection: { generation }, serviceInspection: service,
        wait: { clock.withLock { $0 += 0.5 } }, now: { clock.withLock { $0 } })
    }
    if mode == "service-change" || mode == "updates" {
      #expect(throws: (any Error).self) { try check() }
      return
    }
    let result = try check()
    #expect(result.apple == (mode == "slow-ax" || mode == "stale" ? .couldNotVerify : .verified))
    #expect(
      result.appearance
        == (mode == "slow-automation" || mode == "stale" || mode == "query-error"
          || mode == "query-deadline"
          ? .couldNotVerify : .notGranted))
    let messages = result.diagnostics.joined(separator: "\n")
    #expect(messages.contains("macarchy setup guided --resume"))
    #expect(!messages.contains("checking"))
    if mode == "query-error" {
      #expect(messages.contains("observation failed"))
      #expect(clock.withLock { $0 } < 10)
    } else {
      #expect(messages.contains("couldn't verify within 10 s"))
      #expect(clock.withLock { $0 } == 10)
    }
    if mode == "slow-automation" { #expect(messages.contains("Automation: couldn't verify")) }
    if mode == "slow-ax" { #expect(messages.contains("Accessibility: couldn't verify")) }
    let expiration = markerWrites.withLock { $0 }.dropFirst().flatMap { $0 }
    if mode == "slow-automation" || mode == "slow-ax" || mode == "query-deadline" {
      #expect(expiration.contains { $0.contains(":timeout:") })
      #expect(expiration.contains { $0.hasPrefix(mode == "slow-ax" ? "label=" : "icon=") })
      #expect(!expiration.contains { $0.hasPrefix(mode == "slow-ax" ? "icon=" : "label=") })
    } else {
      #expect(expiration.isEmpty)
    }
  }
}
