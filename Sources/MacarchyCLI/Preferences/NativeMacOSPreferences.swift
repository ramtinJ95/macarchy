import AppKit
import CoreServices
import Foundation
import ThemeCore

struct NativeMacOSPreferences: Sendable {
  let read: @Sendable (MacOSPreference) throws -> Bool
  let write: @Sendable (MacOSPreference, Bool) throws -> Void

  static let live = NativeMacOSPreferences(
    read: { key in
      let reply = try NativePreferenceEvent.send(key: key)
      guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
        [DescType(typeBoolean), DescType(typeTrue), DescType(typeFalse)].contains(
          value.descriptorType)
      else { throw PreferencesError.unavailable("\(key.rawValue) did not return a Boolean.") }
      return value.booleanValue
    },
    write: { key, value in _ = try NativePreferenceEvent.send(key: key, value: value) }
  )
}

enum NativePreferenceEvent {
  // neverInteract alone does NOT suppress Automation consent dialogs.
  static let sendOptions: NSAppleEventDescriptor.SendOptions = [
    .waitForReply, .neverInteract, .init(rawValue: UInt(kAEDoNotPromptForUserConsent)),
  ]

  static func requireSupportedVersion(_ version: OperatingSystemVersion) throws {
    guard version.majorVersion == 26 else {
      throw PreferencesError.unavailable(
        "Native preferences are qualified on macOS 26 only; this macOS version is unsupported.")
    }
  }

  static func application(for key: MacOSPreference) -> (bundle: String, url: URL) {
    switch key {
    case .dockAutohide:
      ("com.apple.systemevents", URL(filePath: "/System/Library/CoreServices/System Events.app"))
    case .finderShowExtensions:
      ("com.apple.finder", URL(filePath: "/System/Library/CoreServices/Finder.app"))
    }
  }

  static func request(
    key: MacOSPreference, value: Bool?, target: NSAppleEventDescriptor
  ) throws -> NSAppleEventDescriptor {
    let (parent, property): (String, String) =
      switch key {
      case .dockAutohide: ("dpas", "dahd")
      case .finderShowExtensions: ("pfrp", "psnx")
      }
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kAECoreSuite),
      eventID: AEEventID(value == nil ? kAEGetData : kAESetData),
      targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(
      try specifier(property, in: specifier(parent, in: .null())),
      forKeyword: AEKeyword(keyDirectObject))
    if let value {
      event.setParam(.init(boolean: value), forKeyword: AEKeyword(keyAEData))
    }
    return event
  }

  fileprivate static func send(key: MacOSPreference, value: Bool? = nil) throws
    -> NSAppleEventDescriptor
  {
    try requireSupportedVersion(ProcessInfo.processInfo.operatingSystemVersion)
    let app = application(for: key)
    // System Events is an on-demand OS query helper, not a resident Macarchy service.
    // Finder must already be running in the current user's GUI session.
    if key == .dockAutohide,
      NSRunningApplication.runningApplications(withBundleIdentifier: app.bundle).isEmpty
    {
      let result = try ProcessRunner.live.run(
        .init(
          executableURL: URL(filePath: "/usr/bin/open"), arguments: ["-g", "-j", app.url.path],
          timeout: 3))
      guard result.terminationStatus == 0 else {
        throw PreferencesError.unavailable(
          "Cannot start Apple's System Events query helper: \(result.output)")
      }
    }
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundle)
      // NSRunningApplication returns directory URLs with a trailing slash.
      .filter { $0.bundleURL?.standardizedFileURL.path == app.url.path }
    guard matches.count == 1, let process = matches.first else {
      throw PreferencesError.unavailable(
        "\(app.url.lastPathComponent) is not running in this GUI session.")
    }
    do {
      let reply = try request(
        key: key, value: value, target: .init(processIdentifier: process.processIdentifier)
      ).sendEvent(options: sendOptions, timeout: 2)
      if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)),
        error.int32Value != 0
      {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
      }
      return reply
    } catch {
      let code = (error as NSError).code
      if value != nil, ![-1743, -1744, -600, -1708].contains(code) {
        throw PreferencesError.uncertain(
          "\(key.rawValue) setter did not confirm completion (\(code)). The OS may still finish it; do not retry blindly. \(error)"
        )
      }
      throw PreferencesError.unavailable(
        "\(key.rawValue) Apple Event failed (\(code)). No permission prompt or fallback was attempted. "
          + "Automation permissions, if required, must be configured manually. \(error)")
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
    guard let specifier = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
      throw PreferencesError.invalid("Cannot construct the fixed public preference specifier.")
    }
    return specifier
  }
}

enum PreferencesError: Error, CustomStringConvertible, Sendable {
  case invalid(String)
  case unavailable(String)
  case drift(String)
  case recoveryRequired(String)
  case uncertain(String)
  case rolledBack(String)

  var description: String {
    switch self {
    case .invalid(let reason): "Invalid macOS preferences state: \(reason)"
    case .unavailable(let reason): "macOS preferences unavailable: \(reason)"
    case .drift(let reason): "macOS preferences drift: \(reason)"
    case .recoveryRequired(let reason): "macOS preferences recovery required: \(reason)"
    case .uncertain(let reason): "macOS preferences write outcome uncertain: \(reason)"
    case .rolledBack(let reason): "macOS preferences apply rolled back: \(reason)"
    }
  }
}
