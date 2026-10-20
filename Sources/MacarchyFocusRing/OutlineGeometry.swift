import CoreGraphics
import ThemeCore

enum OutlineGeometry {
  static let width = CGFloat(BordersPalette.width)
  /// JankyBorders 1.9.0's fallback for missing or non-positive native radii.
  static let defaultCornerRadius: CGFloat = 9

  static func resolvedCornerRadius(_ reported: CGFloat?) -> CGFloat {
    guard let reported, reported.isFinite, reported > 0 else { return defaultCornerRadius }
    return reported
  }

  /// Converts window-server global coordinates (origin at the primary display's
  /// top-left, y down) to AppKit global coordinates (origin at the primary screen's
  /// bottom-left, y up).
  static func appKitRect(fromWindowServer rect: CGRect, primaryScreenFrame: CGRect) -> CGRect {
    CGRect(
      x: rect.minX, y: primaryScreenFrame.maxY - rect.maxY,
      width: rect.width, height: rect.height)
  }

  /// The outline window extends half a stroke width beyond the target on every side.
  static func outlineFrame(around target: CGRect) -> CGRect {
    target.insetBy(dx: -width / 2, dy: -width / 2)
  }

  /// The stroke is centered on the target edge; the inner half is occluded by the
  /// target because the outline panel is ordered below it.
  static func strokeRect(in bounds: CGRect) -> CGRect {
    bounds.insetBy(dx: width / 2, dy: width / 2)
  }

  static func pathRadius(for rect: CGRect, cornerRadius: CGFloat = defaultCornerRadius) -> CGFloat {
    max(0, min(resolvedCornerRadius(cornerRadius), rect.width / 2, rect.height / 2))
  }
}

/// Frame changes do not require an unchanged window stack to be reordered.
enum OutlineOrdering {
  static func needsOrder(
    isVisible: Bool, previousTarget: UInt32?, target: UInt32, levelChanged: Bool
  ) -> Bool {
    !isVisible || previousTarget != target || levelChanged
  }
}

/// AppKit's `isVisible` only says the panel is ordered in, not that it is on the
/// active Space, so the watchdog checks it against the window server's on-screen list.
/// A stranded outline is one that is missing while the window it surrounds is on-screen;
/// when both are missing (lock screen, another user's session) nothing is repaired.
struct OutlinePlacement {
  enum Action: Equatable {
    case keep
    /// `log` is true once per divergence, until the outline is seen on-screen again.
    case recreate(log: Bool)
  }

  private var diverged = false

  mutating func reconcile(shown: Bool, onScreen: Bool, targetOnScreen: Bool) -> Action {
    if onScreen { diverged = false }
    guard shown, !onScreen, targetOnScreen else { return .keep }
    defer { diverged = true }
    return .recreate(log: !diverged)
  }
}
