import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

// Icon & widget style through SkyLight's SLSIconAppearanceConfiguration. Every selector is
// checked against the exact type encoding observed on tested builds before it is called, so a
// changed ABI makes the control unavailable instead of calling through a wrong signature.
// The approach follows Scene (MIT, Copyright (c) 2026 InsaneArts), see THIRD_PARTY_NOTICES.md.
protocol IconStyleConfiguration {
  func fetch() throws(HelperFailure) -> AnyObject
  func uint(_ object: AnyObject, _ name: String) -> UInt32
  func setUInt(_ object: AnyObject, _ name: String, _ value: UInt32)
  func customColor(_ object: AnyObject) -> CGColor?
  func setCustomColor(_ object: AnyObject, _ color: CGColor?)
  func save(_ object: AnyObject)
}

enum IconStyle {
  /// Index is the value SkyLight stores.
  static let styles = [
    "RegularAutomatic", "RegularLight", "RegularDark", "ClearAutomatic", "ClearLight",
    "ClearDark", "TintedAutomatic", "TintedLight", "TintedDark",
  ]
  static let tints = [
    "None", "Hardware", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Graphite",
    "Other",
  ]
  static let settleMicroseconds: useconds_t = 300_000
  static let keepTint = "-"

  private static let fetchEncoding = "@16@0:8"
  private static let instanceEncodings = [
    "iconAppearanceTheme": "I16@0:8", "setIconAppearanceTheme:": "v20@0:8I16",
    "iconTintColorName": "I16@0:8", "setIconTintColorName:": "v20@0:8I16",
    "otherIconTintColor": "^{CGColor=}16@0:8", "setOtherIconTintColor:": "v24@0:8^{CGColor=}16",
    "save": "v16@0:8",
  ]

  typealias Fetch = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
  typealias GetUInt = @convention(c) (AnyObject, Selector) -> UInt32
  typealias SetUInt = @convention(c) (AnyObject, Selector, UInt32) -> Void
  typealias GetColor = @convention(c) (AnyObject, Selector) -> Unmanaged<CGColor>?
  typealias SetColor = @convention(c) (AnyObject, Selector, CGColor?) -> Void
  typealias Save = @convention(c) (AnyObject, Selector) -> Void

  /// The current style, tint and custom tint color as one JSON-ready value.
  struct State: Equatable {
    var style: String
    var tint: String
    /// `#rrggbb`, or nil when no custom tint is stored.
    var custom: String?

    var json: [String: Any] {
      ["style": style, "tint": tint, "custom": custom.map { $0 as Any } ?? NSNull()]
    }
  }

  struct Configuration: IconStyleConfiguration {
    let configurationClass: AnyClass
    let implementation: (String) -> IMP

    /// A fresh configuration object; SkyLight returns the stored state each time.
    func fetch() throws(HelperFailure) -> AnyObject {
      let selector = NSSelectorFromString("fetchCurrentIconAppearanceConfiguration")
      guard let method = class_getClassMethod(configurationClass, selector) else {
        throw .iconUnavailable
      }
      let fetch = unsafeBitCast(method_getImplementation(method), to: Fetch.self)
      guard let object = fetch(configurationClass, selector)?.takeUnretainedValue() else {
        throw HelperFailure("SkyLight returned no icon appearance configuration")
      }
      return object
    }

    func uint(_ object: AnyObject, _ name: String) -> UInt32 {
      unsafeBitCast(implementation(name), to: GetUInt.self)(object, NSSelectorFromString(name))
    }

    func setUInt(_ object: AnyObject, _ name: String, _ value: UInt32) {
      unsafeBitCast(implementation(name), to: SetUInt.self)(
        object, NSSelectorFromString(name), value)
    }

    func customColor(_ object: AnyObject) -> CGColor? {
      unsafeBitCast(implementation("otherIconTintColor"), to: GetColor.self)(
        object, NSSelectorFromString("otherIconTintColor")
      )?.takeUnretainedValue()
    }

    func setCustomColor(_ object: AnyObject, _ color: CGColor?) {
      unsafeBitCast(implementation("setOtherIconTintColor:"), to: SetColor.self)(
        object, NSSelectorFromString("setOtherIconTintColor:"), color)
    }

    func save(_ object: AnyObject) {
      unsafeBitCast(implementation("save"), to: Save.self)(object, NSSelectorFromString("save"))
    }
  }

  /// The configuration class with every selector at its expected encoding, or nil.
  static func resolve() -> Configuration? {
    guard
      dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL)
        != nil,
      let configurationClass = NSClassFromString("SLSIconAppearanceConfiguration"),
      let fetch = class_getClassMethod(
        configurationClass, NSSelectorFromString("fetchCurrentIconAppearanceConfiguration")),
      encoding(fetch) == fetchEncoding
    else { return nil }
    var implementations: [String: IMP] = [:]
    for (name, expected) in instanceEncodings {
      guard let method = class_getInstanceMethod(configurationClass, NSSelectorFromString(name)),
        encoding(method) == expected
      else { return nil }
      implementations[name] = method_getImplementation(method)
    }
    let resolved = implementations
    // Only the names checked above are ever looked up.
    return Configuration(configurationClass: configurationClass) { resolved[$0]! }
  }

  private static func encoding(_ method: Method) -> String? {
    method_getTypeEncoding(method).map { String(cString: $0) }
  }

  /// The stored state, read from the global preferences the configuration saves to.
  static func stored() -> State {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    func value(_ key: String) -> String? {
      CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? String
    }
    return State(
      style: value("AppleIconAppearanceTheme") ?? "RegularLight",
      tint: value("AppleIconAppearanceTintColor") ?? "None",
      custom: value("AppleIconAppearanceCustomTintColor").flatMap(hex(storedComponents:)))
  }

  /// Sets `target`, reads it back from the stored preferences, and puts the previous style,
  /// tint and custom color back on a mismatch.
  static func set(
    _ target: State, _ configuration: some IconStyleConfiguration,
    read: () -> State = stored, settle: () -> Void = { usleep(settleMicroseconds) }
  ) throws(HelperFailure) -> State {
    guard let style = styles.firstIndex(of: target.style) else {
      throw HelperFailure("unknown icon style \(target.style)")
    }
    // "-" keeps the stored tint, as System Settings does for untinted styles.
    let tint: Int?
    if target.tint == keepTint {
      tint = nil
    } else {
      guard let index = tints.firstIndex(of: target.tint), target.tint != "Hardware" else {
        throw HelperFailure("unknown or unsettable icon tint \(target.tint)")
      }
      tint = index
    }
    var color: CGColor?
    if let custom = target.custom {
      guard let parsed = cgColor(custom) else {
        throw HelperFailure("custom tint must be #rrggbb")
      }
      color = parsed
    }
    let storedBefore = read()
    let expected = State(
      style: target.style, tint: tint == nil ? storedBefore.tint : target.tint,
      custom: target.custom?.lowercased() ?? (tint == nil ? storedBefore.custom : nil))
    let current = try configuration.fetch()
    let before = (
      style: configuration.uint(current, "iconAppearanceTheme"),
      tint: configuration.uint(current, "iconTintColorName"),
      custom: configuration.customColor(current)
    )
    configuration.setUInt(current, "setIconAppearanceTheme:", UInt32(style))
    if let tint { configuration.setUInt(current, "setIconTintColorName:", UInt32(tint)) }
    if tint != nil || target.custom != nil { configuration.setCustomColor(current, color) }
    configuration.save(current)
    settle()
    let after = read()
    guard after == expected
    else {
      let revert = try configuration.fetch()
      configuration.setUInt(revert, "setIconAppearanceTheme:", before.style)
      configuration.setUInt(revert, "setIconTintColorName:", before.tint)
      configuration.setCustomColor(revert, before.custom)
      configuration.save(revert)
      settle()
      let reverted = read()
      throw HelperFailure(
        "icon style read back \(after.style) \(after.tint) \(after.custom ?? "no custom tint"); "
          + "expected \(expected.style) \(expected.tint) \(expected.custom ?? ""); "
          + (reverted == storedBefore ? "reverted" : "revert did not restore the original"))
    }
    return after
  }

  static func cgColor(_ hex: String) -> CGColor? {
    guard hex.count == 7, hex.first == "#", let value = Int(hex.dropFirst(), radix: 16) else {
      return nil
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let components: [CGFloat] = [
      CGFloat((value >> 16) & 0xff) / 255, CGFloat((value >> 8) & 0xff) / 255,
      CGFloat(value & 0xff) / 255, 1,
    ]
    return CGColor(colorSpace: space, components: components)
  }

  /// `#rrggbb` from the stored "r g b a" floating-point form.
  static func hex(storedComponents: String) -> String? {
    let parts = storedComponents.split(separator: " ").compactMap { Double($0) }
    guard parts.count >= 3, parts.prefix(3).allSatisfy({ (0...1).contains($0) }) else {
      return nil
    }
    let bytes = parts.prefix(3).map { Int(($0 * 255).rounded()) }
    return String(format: "#%02x%02x%02x", bytes[0], bytes[1], bytes[2])
  }
}

extension HelperFailure {
  static let iconUnavailable = HelperFailure(
    "the icon & widget style functions are unavailable on this macOS")
}
