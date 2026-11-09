import CoreGraphics
import Foundation
import Testing

@testable import MacarchyLook

struct IconStyleTests {
  @Test func explicitTintRestoresAnAbsentCustomColor() throws {
    let native = FakeIconConfiguration(
      .init(style: "TintedDark", tint: "Other", custom: "#123456"))
    let original = IconStyle.State(style: "RegularLight", tint: "None", custom: nil)
    #expect(try IconStyle.set(original, native, read: { native.stored }, settle: {}) == original)
    #expect(native.customWrites == 1)
    #expect(native.stored.custom == nil)
  }

  @Test func keepTintPreservesBothTintFields() throws {
    let native = FakeIconConfiguration(
      .init(style: "TintedDark", tint: "Other", custom: "#123456"))
    let desired = IconStyle.State(style: "RegularDark", tint: "-", custom: nil)
    let result = try IconStyle.set(desired, native, read: { native.stored }, settle: {})
    #expect(result == .init(style: "RegularDark", tint: "Other", custom: "#123456"))
    #expect(native.customWrites == 0)
  }

  @Test func keepTintWithAnExplicitCustomColorPreservesTheSuppliedHelperProtocol() throws {
    let native = FakeIconConfiguration(.init(style: "TintedDark", tint: "Other", custom: "#123456"))
    let result = try IconStyle.set(
      .init(style: "TintedLight", tint: "-", custom: "#abcdef"), native,
      read: { native.stored }, settle: {})
    #expect(result == .init(style: "TintedLight", tint: "Other", custom: "#abcdef"))
  }

  @Test(arguments: ["style", "tint", "custom", "absent-custom", "keep-tint"])
  func aMismatchRevertsEveryField(field: String) throws {
    let original = IconStyle.State(style: "RegularLight", tint: "Blue", custom: "#123456")
    let native = FakeIconConfiguration(original)
    let desired = IconStyle.State(
      style: "TintedDark", tint: field == "keep-tint" ? "-" : "Other",
      custom: field == "absent-custom" || field == "keep-tint" ? nil : "#abcdef")
    var reads = 0
    var failure: String?
    do {
      _ = try IconStyle.set(
        desired, native,
        read: {
          reads += 1
          var value = native.stored
          if reads == 2 {
            switch field {
            case "style": value.style = "ClearLight"
            case "tint", "keep-tint": value.tint = "Pink"
            case "absent-custom": value.custom = "#010203"
            default: value.custom = nil
            }
          }
          return value
        }, settle: {})
    } catch {
      failure = error.message
    }
    #expect(failure?.hasSuffix("; reverted") == true)
    #expect(native.stored == original)
    #expect(native.saves == 2)
  }

  @Test func aFailedRevertIsReportedHonestly() {
    let original = IconStyle.State(style: "RegularLight", tint: "None", custom: nil)
    let native = FakeIconConfiguration(original)
    var reads = 0
    var failure: String?
    do {
      _ = try IconStyle.set(
        .init(style: "TintedDark", tint: "Other", custom: "#abcdef"), native,
        read: {
          reads += 1
          return reads == 1 ? original : .init(style: "ClearDark", tint: "Red", custom: nil)
        }, settle: {})
    } catch {
      failure = error.message
    }
    #expect(failure?.hasSuffix("revert did not restore the original") == true)
  }

  @Test func customTintRoundTripsAtEightBitPrecision() throws {
    let native = FakeIconConfiguration(.init(style: "RegularLight", tint: "None", custom: nil))
    let target = IconStyle.State(style: "TintedLight", tint: "Other", custom: "#ABCDEF")
    #expect(
      try IconStyle.set(target, native, read: { native.stored }, settle: {}).custom == "#abcdef")
    #expect(IconStyle.hex(storedComponents: "0.5 0.25 1.0 1.0") == "#8040ff")
  }

  @Test(arguments: [
    IconStyle.State(style: "unknown", tint: "None", custom: nil),
    .init(style: "RegularLight", tint: "Hardware", custom: nil),
    .init(style: "RegularLight", tint: "unknown", custom: nil),
    .init(style: "TintedDark", tint: "Other", custom: "bad"),
  ])
  func invalidTargetsNeverSave(target: IconStyle.State) {
    let native = FakeIconConfiguration(.init(style: "RegularLight", tint: "None", custom: nil))
    #expect(throws: HelperFailure.self) {
      try IconStyle.set(target, native, read: { native.stored }, settle: {})
    }
    #expect(native.saves == 0)
  }
}

private final class FakeIconConfiguration: IconStyleConfiguration {
  final class Value: NSObject {
    var style: UInt32
    var tint: UInt32
    var custom: CGColor?
    init(_ state: IconStyle.State) {
      style = UInt32(IconStyle.styles.firstIndex(of: state.style)!)
      tint = UInt32(IconStyle.tints.firstIndex(of: state.tint)!)
      custom = state.custom.flatMap(IconStyle.cgColor)
    }
  }
  var stored: IconStyle.State
  var saves = 0
  var customWrites = 0
  init(_ state: IconStyle.State) { stored = state }
  func fetch() throws(HelperFailure) -> AnyObject { Value(stored) }
  func uint(_ object: AnyObject, _ name: String) -> UInt32 {
    let value = object as! Value
    return name == "iconAppearanceTheme" ? value.style : value.tint
  }
  func setUInt(_ object: AnyObject, _ name: String, _ number: UInt32) {
    let value = object as! Value
    if name == "setIconAppearanceTheme:" { value.style = number } else { value.tint = number }
  }
  func customColor(_ object: AnyObject) -> CGColor? { (object as! Value).custom }
  func setCustomColor(_ object: AnyObject, _ color: CGColor?) {
    customWrites += 1
    (object as! Value).custom = color
  }
  func save(_ object: AnyObject) {
    saves += 1
    let value = object as! Value
    let custom =
      value.custom?.components.map {
        IconStyle.hex(storedComponents: $0.map { String(Double($0)) }.joined(separator: " "))
      } ?? nil
    stored = .init(
      style: IconStyle.styles[Int(value.style)], tint: IconStyle.tints[Int(value.tint)],
      custom: custom)
  }
}
