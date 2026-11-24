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
