import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct GuidedSetupPermissionsTests {
  private struct Denied: Error {}
  private func permissions(
    read: @escaping @Sendable () -> String? = { nil },
    write: @escaping @Sendable (String) -> Void = { _ in },
    open: @escaping @Sendable (String) throws -> Void = { _ in },
    services: @escaping @Sendable () -> [URL] = { [] },
    bar: @escaping @Sendable (UnifiedSetupPlanContext) throws -> GuidedBarPermissions = { _ in
      .init(apple: .verified, appearance: .verified)
    },
    verify: @escaping @Sendable () throws -> Void = {},
    requestBar: @escaping @Sendable (UnifiedSetupPlanContext) throws -> Void = { _ in
      Issue.record("Unexpected bar consent")
    },
    request: @escaping @Sendable () throws -> Void = { Issue.record("Unexpected consent") },
    reconcile:
      @escaping @Sendable (UnifiedSetupPlanContext, ThemeConsumerPaths) async throws -> Void = {
        _, _ in
      }
  ) -> GuidedSetupPermissions {
    .init(
      io: .init(read: read, write: write), openPane: open, servicesNeedingGuidance: services,
      verifyBar: bar, requestBarAccessibility: requestBar, verifyAppearance: verify,
      requestAppearance: request,
      appearanceContext: { "test-terminal.app → test-macarchy" }, reconcileAppearance: reconcile)
  }

  private func profile(_ fixture: ApplyFixture, desktop: Bool, bar: Bool) throws {
    var answers = GuidedSetupAnswers()
    answers.desktop = desktop
    answers.topBar = bar
    try answers.profileTOML.write(to: fixture.context.profileURL, atomically: true, encoding: .utf8)
  }

  @Test(arguments: ["yes", "no"])
  func installedBinaryGuidancePrecedesServiceVerification(answer: String) throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let binary = fixture.root.appending(path: "test-yabai")
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let output = Mutex("")
    let panes = Mutex([String]())
    let guide = permissions(
      read: { answer }, write: { text in output.withLock { $0 += text } },
      open: { pane in panes.withLock { $0.append(pane) } }, services: { [binary] })
    let result = try guide.beforeConfiguration(context: fixture.context, profile: .defaults)
    #expect((result == nil) == (answer == "yes"))
    #expect(output.withLock { $0.contains(binary.path) && $0.contains("not proof") })
    #expect(panes.withLock { $0 } == ["Accessibility"])
    if answer == "no" {
      #expect(result?.contains("Installed packages and the profile are retained") == true)
    }
  }

  @Test func nonexistentServiceNeverSendsUserToGrantAnAbsentBinary() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let missing = fixture.root.appending(path: "absent-skhd")
    let guide = permissions(
      read: {
        Issue.record("No consent before install")
        return nil
      },
      open: { _ in Issue.record("No Settings pane for an absent binary") }, services: { [missing] })
    let result = try guide.beforeConfiguration(context: fixture.context, profile: .defaults)
    #expect(result?.contains(missing.path) == true)
    #expect(result?.contains("not installed") == true)
  }

  @Test func grantedConsentIsVerifiedWithoutPromptingAgain() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try profile(fixture, desktop: false, bar: false)
    let reconciled = Mutex(false)
    let guide = permissions(
      read: {
        Issue.record("Existing grant must not ask again")
        return nil
      },
      open: { _ in Issue.record("Existing grant needs no Settings") },
      reconcile: { _, _ in reconciled.withLock { $0 = true } })
    let result = try await guide.afterConfiguration(
      context: fixture.context, consumerPaths: testConsumerPaths())
    #expect(result.succeeded)
    #expect(result.output.contains("this invocation"))
    #expect(reconciled.withLock { $0 })
  }

  @Test(arguments: ["no", "yes"])
  func missingAppearanceConsentIsExplicitAndNeverHidesDenial(answer: String) async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try profile(fixture, desktop: false, bar: false)
    let requested = Mutex(0)
    let guide = permissions(
      read: { answer },
      verify: { throw Denied() },
      request: {
        requested.withLock { $0 += 1 }
        throw Denied()
      },
      reconcile: { _, _ in Issue.record("Unverified consent cannot reconcile appearance") })
    let result = try await guide.afterConfiguration(
      context: fixture.context, consumerPaths: testConsumerPaths())
    #expect(!result.succeeded)
    #expect(requested.withLock { $0 } == (answer == "yes" ? 1 : 0))
    #expect(result.output.contains("permissions are incomplete"))
    #expect(result.output.contains("test-terminal.app"))
    #expect(result.output.contains("macarchy setup guided --resume"))
  }

  @Test func consentRequestsNoAppearanceChangeUntilVerification() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try profile(fixture, desktop: false, bar: false)
    let events = Mutex([String]())
    let granted = Mutex(false)
    let guide = permissions(
      read: { "yes" },
      verify: {
        events.withLock { $0.append("verify") }
        if !granted.withLock({ $0 }) { throw Denied() }
      },
      request: {
        events.withLock { $0.append("request") }
        granted.withLock { $0 = true }
      },
      reconcile: { _, _ in events.withLock { $0.append("reconcile") } })
    let result = try await guide.afterConfiguration(
      context: fixture.context, consumerPaths: testConsumerPaths())
    #expect(result.succeeded)
    #expect(events.withLock { $0 } == ["verify", "request", "verify", "reconcile"])
  }

  @Test func helperDenialDoesNotUndoConfigurationOrPretendTerminalGrantCoversServices() async throws
  {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try profile(fixture, desktop: true, bar: true)
    let output = Mutex("")
    let barChecks = Mutex(0)
    let guide = permissions(
      write: { text in output.withLock { $0 += text } },
      bar: { _ in
        barChecks.withLock { $0 += 1 }
        return .init(apple: .notGranted, appearance: .notGranted)
      })
    let result = try await guide.afterConfiguration(
      context: fixture.context, consumerPaths: testConsumerPaths())
    #expect(!result.succeeded)
    #expect(result.output.contains("Configuration is applied"))
    #expect(result.output.contains("Apple menu will not work"))
    #expect(result.output.contains("Keybinding-origin"))
    #expect(output.withLock { $0.contains("observation only") })
    #expect(result.output.contains("terminal resume cannot verify"))
    #expect(
      output.withLock { $0.contains("macarchy-menu") && $0.contains("running SketchyBar service") })
    #expect(barChecks.withLock { $0 } == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.context.profileURL.path))
  }

  @Test func explicitNativeBarRequestIsRecheckedWithoutRequiringUnusedAutomation() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try profile(fixture, desktop: false, bar: true)
    let granted = Mutex(false)
    let requests = Mutex(0)
    let guide = permissions(
      read: { "yes" },
      bar: { _ in
        .init(apple: granted.withLock { $0 } ? .verified : .notGranted, appearance: .notGranted)
      },
      requestBar: { _ in
        requests.withLock { $0 += 1 }
        granted.withLock { $0 = true }
      })
    let result = try await guide.afterConfiguration(
      context: fixture.context, consumerPaths: testConsumerPaths())
    #expect(result.succeeded)
    #expect(requests.withLock { $0 } == 1)
  }

  @Test func resumeCommandKeepsCustomProfileAndStatePathsCopyable() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    var context = fixture.context
    context.nativeStarterProviders = []
    let command = GuidedSetupPermissions.resumeCommand(context)
    #expect(command == "macarchy setup guided --resume")
    #expect(command.contains("macarchy setup guided --resume"))
  }
  @Test(arguments: [false, true])
  func currentConfigurationResumesOnlyPermissionsWithoutReapproval(resume: Bool) async throws {
    let fixture = try ApplyFixture()
    var manifest: GenerationManifest?
    defer { fixture.cleanup(expectedThemeGenerationID: manifest?.generationID) }
    if resume { manifest = try fixture.activateSetupOwnedTheme() }
    var answers = GuidedSetupAnswers()
    answers.desktop = false
    answers.topBar = false
    answers.shell = false
    answers.terminal = false
    answers.editor = false
    if resume {
      try answers.profileTOML.write(
        to: fixture.context.profileURL, atomically: true, encoding: .utf8)
    }
    let events = Mutex([String]())
    let guide = permissions(
      verify: { events.withLock { $0.append("verify") } },
      reconcile: { _, _ in events.withLock { $0.append("reconcile") } })
    let runner = GuidedSetupCommandRunner(
      packageTrust: .testAlreadyTrusted, planner: fixture.planner(),
      apply: { _, _, _, _, _ in
        #expect(!resume)
        events.withLock { $0.append("apply") }
        return ("configuration applied", true)
      },
      io: .init(
        read: {
          #expect(!resume, "A permission-only resume must not repeat configuration consent")
          return "yes"
        }, write: { _ in }),
      permissions: guide)
    let result: CommandExecution
    if resume {
      result = try await runner.execute(
        context: fixture.context, consumerPaths: testConsumerPaths(), resume: true)
    } else {
      result = try await runner.execute(
        context: fixture.context, consumerPaths: testConsumerPaths(), answers: answers)
    }
    #expect(result.succeeded, "\(result.output)")
    #expect(
      events.withLock { $0 }
        == (resume ? ["verify", "reconcile"] : ["apply", "verify", "reconcile"]))
  }

  @Test(arguments: [true, false], [true, false])
  func barProbeRequiresAFreshActualServiceVerdict(granted: Bool, requestAccessibility: Bool) throws
  {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let token = Mutex("")
    let expected = fixture.state.appending(path: "desktop/sketchybar/current/plugins/apple.sh").path
    let generation = SketchyBarGenerationInspection(
      status: .current, generationID: "selected-generation", manifest: nil, message: "selected")
    let service = SketchyBarRuntimeInspection(
      status: .running, message: "running", processID: 123,
      executablePath: "/installed/sketchybar", serviceLabel: "homebrew.mxcl.sketchybar")
    let result = try GuidedSetupPermissions.verifyBar(
      context: fixture.context,
      runner: ProcessRunner { request in
        let args = request.arguments
        if args.first == "--trigger" {
          #expect(args[1] == "macarchy_permission_check")
          #expect(
            args.last == "MACARCHY_PERMISSION_REQUEST_AX=" + (requestAccessibility ? "1" : "0"))
          token.withLock { $0 = String(args[2].dropFirst("MACARCHY_PERMISSION_TOKEN=".count)) }
          return .init(terminationStatus: 0, output: "")
        }
        if args.first == "--set" { return .init(terminationStatus: 0, output: "") }
        #expect(args.first == "--query")
        let marker = args[1] == "macarchy.theme.ready"
        let stage = token.withLock {
          "permission:v2:\($0):complete:100:100.25:\(granted ? 0 : 77)"
        }
        let label = marker ? stage : (granted ? "" : "Menu ERR")
        let json: [String: Any] = [
          "name": args[1], "type": "item",
          "geometry": ["drawing": "on", "position": "left", "associated_space_mask": 0],
          "label": ["value": label, "drawing": granted || marker ? "off" : "on"],
          "icon": ["value": stage, "drawing": "off"],
          "scripting": ["script": expected, "click_script": "", "update_freq": 0],
        ]
        return .init(
          terminationStatus: 0,
          output: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
      },
      requestAccessibility: requestAccessibility,
      generationInspection: { generation }, serviceInspection: { service },
      wait: { Issue.record("A completed fresh verdict should need no wait") })
    #expect(result.apple == (granted ? .verified : .failed))
    #expect(result.appearance == (granted ? .verified : .notGranted))
    #expect(result.diagnostics.contains { $0.contains("elapsed=0.250 s") })
    #expect(!token.withLock { $0 }.isEmpty)
  }

}
