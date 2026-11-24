import CoreServices
import Foundation
import Testing

@testable import ThemeCore

struct MacOSAppearanceEventsTests {
  @Test func fixedAppearanceRequestsAndEverySetterSuppressImplicitConsent() throws {
    #expect(MacOSAppearanceEvents.sendOptions.contains(.neverInteract))
    #expect(
      MacOSAppearanceEvents.sendOptions.contains(
        .init(rawValue: UInt(kAEDoNotPromptForUserConsent))))
    let get = try MacOSAppearanceEvents.request(appearance: nil, target: .null())
    let dark = try MacOSAppearanceEvents.request(appearance: .dark, target: .null())
    let light = try MacOSAppearanceEvents.request(appearance: .light, target: .null())
    #expect(get.eventClass == AEEventClass(kAECoreSuite))
    #expect(get.eventID == AEEventID(kAEGetData))
    #expect(dark.eventID == AEEventID(kAESetData))
    #expect(get.paramDescriptor(forKeyword: AEKeyword(keyAEData)) == nil)
    #expect(dark.paramDescriptor(forKeyword: AEKeyword(keyAEData))?.booleanValue == true)
    #expect(light.paramDescriptor(forKeyword: AEKeyword(keyAEData))?.booleanValue == false)
    let property = try #require(get.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
    #expect(property.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == 0x7468_6d65)
    #expect(
      property.forKeyword(AEKeyword(keyAEContainer))?
        .forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == 0x6170_7270)
  }

  @Test(arguments: [false, true])
  func grantedInteractiveAccessNeverRepeatsConsentAndBackgroundNeverAsks(interactive: Bool) throws {
    var asks = [Bool]()
    var writes = [ThemeAppearance]()
    try MacOSAppearanceEvents.change(
      .dark, allowConsent: interactive,
      determine: { asks.append($0) }, send: { writes.append($0) })
    #expect(asks == (interactive ? [false] : []))
    #expect(writes == [.dark])
  }

  @Test(arguments: [-1744, -1743])
  func explicitInteractiveRequestIsTheOnlyPromptCapableBranch(code: Int32) throws {
    var asks = [Bool]()
    var writes = [ThemeAppearance]()
    try MacOSAppearanceEvents.change(
      .light, allowConsent: true,
      determine: { ask in
        asks.append(ask)
        if !ask { throw MacOSAppearanceEvents.Failure("missing", code: code) }
      }, send: { writes.append($0) })
    #expect(asks == [false, true])
    #expect(writes == [.light])
  }

  @Test func denialDoesNotWriteOrTryAnAlternateSender() {
    var asks = [Bool]()
    #expect(throws: MacOSAppearanceEvents.Failure.self) {
      try MacOSAppearanceEvents.change(
        .light, allowConsent: true,
        determine: { ask in
          asks.append(ask)
          throw MacOSAppearanceEvents.Failure("denied", code: -1743)
        }, send: { _ in Issue.record("Denied access must not write") })
    }
    #expect(asks == [false, true])
    let message = MacOSAppearanceEvents.Failure("denied", code: -1743).description
    #expect(message.contains("launch context"))
    #expect(message.contains("keybinding"))
    #expect(message.contains("tccutil reset AppleEvents"))
    #expect(message.contains("resets other Automation decisions"))
  }

  @Test func unavailableTargetDoesNotRequestConsent() {
    var asks = [Bool]()
    #expect(throws: MacOSAppearanceEvents.Failure.self) {
      try MacOSAppearanceEvents.change(
        .dark, allowConsent: true,
        determine: { ask in
          asks.append(ask)
          throw MacOSAppearanceEvents.Failure("target unavailable")
        }, send: { _ in Issue.record("Unavailable target must not write") })
    }
    #expect(asks == [false])
    #expect(!MacOSAppearanceEvents.Failure("target unavailable").description.contains("tccutil"))
  }

  @Test func launchCompletionAloneDoesNotMakeAPendingTargetReady() throws {
    var events = 0
    let pid = try MacOSAppearanceEvents.awaitReadyTarget(
      before: Date().addingTimeInterval(3),
      observe: { events == 2 ? 42 : nil },
      receiveEvent: { _ in
        events += 1
        return true
      })
    #expect(pid == 42)
    #expect(events == 2)
  }

  @Test func readinessDeadlineIsNamedAndNeverReturnsAnUnreadyPID() {
    do {
      _ = try MacOSAppearanceEvents.awaitReadyTarget(
        before: .distantPast,
        observe: {
          Issue.record("Expired resolution must not begin")
          return 42
        },
        receiveEvent: { _ in
          Issue.record("Expired resolution must not wait")
          return true
        })
      Issue.record("An unready process is not an authorized target")
    } catch let failure as MacOSAppearanceEvents.Failure {
      #expect(failure.code == -1712)
      #expect(failure.state == "timed_out")
      #expect(failure.description.contains("target_readiness_timed_out"))
    } catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test func missingLaunchEventSourceFailsExplicitlyWithoutSpinning() {
    var events = 0
    #expect(throws: MacOSAppearanceEvents.Failure.self) {
      try MacOSAppearanceEvents.awaitReadyTarget(
        before: Date().addingTimeInterval(3), observe: { nil },
        receiveEvent: { _ in
          events += 1
          return false
        })
    }
    #expect(events == 1)
  }

  @Test func missingProcessAfterConsentRechecksOnceWithoutPrompting() throws {
    var asks = [Bool]()
    let value = try MacOSAppearanceEvents.withTargetRecovery(ask: true) { ask in
      asks.append(ask)
      if asks.count == 1 { throw MacOSAppearanceEvents.Failure("stale PID", code: -600) }
      return ThemeAppearance.dark
    }
    #expect(asks == [true, false])
    #expect(value == .dark)
  }

  @Test(arguments: [-1743, -1744, -1712, -1708])
  func terminalTransportFailuresAreNotRetriedOrTreatedAsGrants(code: Int32) {
    var calls = 0
    #expect(throws: MacOSAppearanceEvents.Failure.self) {
      try MacOSAppearanceEvents.withTargetRecovery(ask: true) { _ in
        calls += 1
        throw MacOSAppearanceEvents.Failure("transport", code: code)
      }
    }
    #expect(calls == 1)
    if code == -1712 {
      #expect(
        MacOSAppearanceEvents.Failure("transport", code: code).description.contains("timed_out"))
    }
  }

  @Test(arguments: [-600, -1743, -1744, -1712])
  func recoveryRequiresRealSuccessAndPreservesTheFinalVerdict(code: Int32) {
    var asks = [Bool]()
    do {
      try MacOSAppearanceEvents.withTargetRecovery(ask: true) { ask in
        asks.append(ask)
        throw MacOSAppearanceEvents.Failure("transport", code: asks.count == 1 ? -600 : code)
      }
      Issue.record("A missing process or failed recheck is never a grant")
    } catch let error as MacOSAppearanceEvents.Failure {
      #expect(error.code == code)
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(asks == [true, false])
  }

  @Test func backgroundRecoveryNeverPrompts() throws {
    var asks = [Bool]()
    try MacOSAppearanceEvents.withTargetRecovery { ask in
      asks.append(ask)
      if asks.count == 1 { throw MacOSAppearanceEvents.Failure("stale PID", code: -600) }
    }
    #expect(asks == [false, false])
  }

  @Test(arguments: [Int32(0), -600, -1744])
  func guidedConsentRequiresIndependentVerification(code: Int32) throws {
    var asks = [Bool]()
    var verified = false
    try MacOSAppearanceEvents.requestConsent(
      determine: {
        asks.append($0)
        if code != 0 { throw MacOSAppearanceEvents.Failure("request", code: code) }
      }, verify: { verified = true })
    #expect(asks == [true])
    #expect(verified)
  }

  @Test(arguments: [Int32(-1743), -1712, -1708])
  func guidedDenialAndTimeoutNeverBecomeGrants(code: Int32) {
    #expect(throws: MacOSAppearanceEvents.Failure.self) {
      try MacOSAppearanceEvents.requestConsent(
        determine: { _ in throw MacOSAppearanceEvents.Failure("request", code: code) },
        verify: { Issue.record("Final native failure must not start child checks") })
    }
  }

  @Test(arguments: [Int32(0), -600, -1744])
  func guidedIndependentVerificationFailureIsNeverSuppressed(code: Int32) {
    #expect(throws: MacOSAppearanceEvents.Failure.self) {
      try MacOSAppearanceEvents.requestConsent(
        determine: { _ in
          if code != 0 { throw MacOSAppearanceEvents.Failure("request", code: code) }
        },
        verify: { throw MacOSAppearanceEvents.Failure("fresh denied", code: -1743) })
    }
  }

  @Test func inspectionReportsDeniedAccessEvenWhenAppearanceAlreadyMatches() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let adapter = MacOSAppearanceAdapter(
      root: root, controlIsAvailable: { true },
      currentAppearance: { .dark },
      writeAppearance: { _ in Issue.record("Inspection must not write") },
      verifyAutomation: { throw MacOSAppearanceEvents.Failure("denied", code: -1743) })
    let inspection = adapter.inspection(desiredAppearance: .dark)
    #expect(inspection.status == .failed)
    #expect(inspection.message?.contains("System Events") == true)
    #expect(inspection.message?.contains("launch context") == true)
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }
}
