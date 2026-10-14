import Foundation

/// One window reported by the window-server iterator; never retained past a tick.
struct WindowCandidate: Equatable, Sendable {
  var windowID: UInt32
  var parentID: UInt32
  var tags: UInt64
  var attributes: UInt64
  var level: Int32
  var cornerRadius: CGFloat = OutlineGeometry.defaultCornerRadius
}

/// Preserves the incumbent's class of selection: the first suitable window of the
/// front process's connection on the active display's current Space, in window-server
/// order. This is not accessibility focus and must never be reported as exact focus.
enum FocusTargetPolicy {
  static let selectionLabel = "front-connection-order"

  /// Bit positions as used by JankyBorders 1.9.0's suitability rule; their
  /// window-server meaning is undocumented.
  enum Bit {
    static let visibleAttribute: UInt64 = 1 << 1
    static let document: UInt64 = 1 << 0
    static let floating: UInt64 = 1 << 1
    static let attached: UInt64 = 1 << 7
    static let ignoresCycle: UInt64 = 1 << 18
    static let modal: UInt64 = 1 << 31
    static let alternateVisible: UInt64 = 1 << 58
  }

  static func isSuitable(_ window: WindowCandidate, excluding outlineWindowID: UInt32?) -> Bool {
    guard window.windowID != outlineWindowID, window.parentID == 0 else { return false }
    let tags = window.tags
    let visible =
      window.attributes & Bit.visibleAttribute != 0 || tags & Bit.alternateVisible != 0
    let independent = tags & (Bit.attached | Bit.ignoresCycle) == 0
    let floatingModal = Bit.floating | Bit.modal
    let role = tags & Bit.document != 0 || tags & floatingModal == floatingModal
    return visible && independent && role
  }
}

enum SpaceKind: Equatable, Sendable {
  case user
  case fullscreen
  case other(Int)
}

enum SpaceTopologyError: Error, Equatable, CustomStringConvertible {
  case displayMissing
  case spaceMissing
  case typeMissing

  var description: String {
    switch self {
    case .displayMissing: "the active menu-bar display is absent from the managed display Spaces"
    case .spaceMissing: "the current Space is absent from its display's Spaces"
    case .typeMissing: "the current Space has no numeric type"
    }
  }
}

/// Reads the selected Space's explicit type from `SLSCopyManagedDisplaySpaces`.
/// Unknown shapes fail instead of guessing whether a Space is native full screen.
enum SpaceClassifier {
  static func classify(
    displays: [Any], displayIdentifier: String, spaceID: UInt64
  ) throws -> SpaceKind {
    for case let display as [String: Any] in displays
    where display["Display Identifier"] as? String == displayIdentifier {
      let current = display["Current Space"].map { [$0] } ?? []
      let spaces = current + (display["Spaces"] as? [Any] ?? [])
      for case let space as [String: Any] in spaces
      where (space["ManagedSpaceID"] as? NSNumber)?.uint64Value == spaceID {
        guard let type = (space["type"] as? NSNumber)?.intValue else {
          throw SpaceTopologyError.typeMissing
        }
        switch type {
        case 0: return .user
        case 4: return .fullscreen
        default: return .other(type)
        }
      }
      throw SpaceTopologyError.spaceMissing
    }
    throw SpaceTopologyError.displayMissing
  }
}
