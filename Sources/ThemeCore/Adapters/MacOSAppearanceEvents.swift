import AppKit
import CoreServices
import Darwin
import Foundation

/// One fixed public scripting-suite operation. Ordinary callers never request consent.
package enum MacOSAppearanceEvents {
  package static let applicationURL = URL(
    filePath: "/System/Library/CoreServices/System Events.app")
  package static let sendOptions: NSAppleEventDescriptor.SendOptions = [
    .waitForReply, .neverInteract, .init(rawValue: UInt(kAEDoNotPromptForUserConsent)),
  ]

  package static var launchContext: String {
    let executable = processExecutablePath(getpid()) ?? CommandLine.arguments[0]
    return
      "sender \(executable); launching application \(launchingApplication?.path ?? "unidentified (do not guess the TCC entry)")"
  }

  /// An observable ancestor, not a claim about macOS's private responsibility attribution.
  package static var launchingApplication: URL? {
    var pid = getppid()
    for _ in 0..<32 where pid > 1 {
      if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL { return url }
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
      let parent = Int32(info.pbi_ppid)
      guard parent != pid else { return nil }
      pid = parent
    }
    return nil
  }

  package static func target() throws -> NSAppleEventDescriptor {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
      throw Failure("Appearance Apple Events are supported on macOS 26 only.")
    }
    let bundle = "com.apple.systemevents"
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
      let result = try ProcessRunner.live.run(
        .init(
          executableURL: URL(filePath: "/usr/bin/open"),
          arguments: ["-g", "-j", applicationURL.path], timeout: 3))
      guard result.terminationStatus == 0 else {
        throw Failure("Cannot start \(applicationURL.path): \(result.output)")
      }
    }
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
      .filter { $0.bundleURL?.standardizedFileURL.path == applicationURL.path }
    guard matches.count == 1, let app = matches.first else {
      throw Failure("Cannot identify Apple's System Events in this GUI session.")
    }
    return .init(processIdentifier: app.processIdentifier)
  }

  /// Checks permission for the setter and verifies a Boolean getter without changing appearance.
  package static func verify() throws {
    try permission(ask: false)
    _ = try read()
  }

  /// Guided setup only, after a separate default-no confirmation.
  package static func requestConsent() throws {
    try permission(ask: true)
    try verify()
  }

  private static func permission(ask: Bool) throws {
    let target = try target()
    guard let descriptor = target.aeDesc else { throw Failure("Cannot address System Events.") }
    let status = AEDeterminePermissionToAutomateTarget(
      descriptor, AEEventClass(kAECoreSuite), AEEventID(kAESetData), ask)
    guard status == noErr else {
      throw Failure("System Events Automation is not verified (\(status)).", code: status)
    }
  }

  package static func request(
    appearance: ThemeAppearance?, target: NSAppleEventDescriptor
  ) throws -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kAECoreSuite),
      eventID: AEEventID(appearance == nil ? kAEGetData : kAESetData),
      targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    // SystemEvents.sdef: appearance preferences = aprp; dark mode = thme.
    event.setParam(
      try specifier("thme", in: specifier("aprp", in: .null())),
      forKeyword: AEKeyword(keyDirectObject))
    if let appearance {
      event.setParam(.init(boolean: appearance == .dark), forKeyword: AEKeyword(keyAEData))
    }
    return event
  }

  package static func read() throws -> ThemeAppearance {
    let reply = try send(appearance: nil)
    guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
      [DescType(typeBoolean), DescType(typeTrue), DescType(typeFalse)].contains(
        value.descriptorType)
    else { throw Failure("System Events appearance getter did not return a Boolean.") }
    return value.booleanValue ? .dark : .light
  }

  package static func write(_ appearance: ThemeAppearance) throws {
    try change(
      appearance, allowConsent: false, determine: permission, send: { _ = try send(appearance: $0) }
    )
  }

  package static func requestInteractiveConsent() throws {
    try authorizeInteractiveChange(determine: permission)
  }

  private static func authorizeInteractiveChange(determine: (Bool) throws -> Void) throws {
    do { try determine(false) } catch let error as Failure
      where error.code == -1744 || error.code == -1743
    {
      try determine(true)
    }
  }

  static func change(
    _ appearance: ThemeAppearance, allowConsent: Bool,
    determine: (Bool) throws -> Void, send: (ThemeAppearance) throws -> Void
  ) throws {
    if allowConsent { try authorizeInteractiveChange(determine: determine) }
    // Every setter still uses sendOptions; only determine(true) may prompt.
    try send(appearance)
  }

  private static func send(appearance: ThemeAppearance?) throws -> NSAppleEventDescriptor {
    do {
      let reply = try request(appearance: appearance, target: target())
        .sendEvent(options: sendOptions, timeout: 2)
      if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)),
        error.int32Value != 0
      {
        throw Failure(
          "System Events rejected the appearance event (\(error.int32Value)).",
          code: error.int32Value)
      }
      return reply
    } catch let error as Failure { throw error } catch {
      throw Failure(
        "System Events appearance event failed: \(error)",
        code: Int32(exactly: (error as NSError).code))
    }
  }

  private static func specifier(
    _ property: String, in container: NSAppleEventDescriptor
  ) throws -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(
      .init(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
    record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
    record.setDescriptor(
      .init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
    record.setDescriptor(
      .init(typeCode: property.utf8.reduce(0) { ($0 << 8) | UInt32($1) }),
      forKeyword: AEKeyword(keyAEKeyData))
    guard let value = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
      throw Failure("Cannot construct the fixed appearance property specifier.")
    }
    return value
  }

  package struct Failure: Error, CustomStringConvertible, Sendable {
    let reason: String
    let code: Int32?
    package init(_ reason: String, code: Int32? = nil) {
      self.reason = reason
      self.code = code
    }
    package var description: String {
      var message =
        "\(reason) Light/dark changes are blocked in this launch context: \(MacOSAppearanceEvents.launchContext). Recipient: \(MacOSAppearanceEvents.applicationURL.path). "
      if code == -1743 || code == -1744 {
        message +=
          "To create a missing Automation entry, choose an opposite-appearance theme interactively from the failing menu/keybinding, or run macarchy setup guided --resume in the failing terminal app. "
        if code == -1743 {
          message +=
            "For an earlier denial, enable the responsible app's System Events toggle in System Settings > Privacy & Security > Automation. As a last resort the user may run tccutil reset AppleEvents; that resets other Automation decisions too. "
        }
      } else {
        message +=
          "Run macarchy setup doctor in the same GUI session and resolve the reported target/event failure before retrying. "
      }
      return message
        + "Terminal consent does not verify skhd, SketchyBar/menu or launch-agent contexts. Background operations never prompt; there is no osascript fallback."

    }
  }
}
