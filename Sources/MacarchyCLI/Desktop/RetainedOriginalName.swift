import Foundation

/// The file name of a desktop provider's retained original under its state directory:
/// `retained-` followed by a lowercase UUID nonce.
enum RetainedOriginalName {
  private static let prefix = "retained-"

  /// Which spellings of the nonce a check accepts. SketchyBar ownership validation requires the
  /// lowercase spelling it writes; yabai's ownership migration accepts a UUID in any case.
  enum NonceCase {
    case lowercaseOnly
    case any
  }

  static func make(nonce: UUID) -> String { prefix + nonce.uuidString.lowercased() }

  static func isValid(_ name: String, nonceCase: NonceCase) -> Bool {
    guard name.hasPrefix(prefix) else { return false }
    let nonce = String(name.dropFirst(prefix.count))
    switch nonceCase {
    case .lowercaseOnly: guard nonce == nonce.lowercased() else { return false }
    case .any: break
    }
    return UUID(uuidString: nonce) != nil
  }
}
