import CoreGraphics
import Foundation
import Testing
import ThemeCore

@testable import MacarchyFocusRing

private typealias Bit = FocusTargetPolicy.Bit

@Suite struct FocusRingPolicyTests {
  @Test func transientPaletteFailuresAreBoundedAndSuccessResetsTheBudget() {
    var policy = FocusRingRetryPolicy()
    #expect(policy.paletteFailed() == .logAndRetry)
    for _ in 2...7 { #expect(policy.paletteFailed() == .retry) }
    policy.paletteSucceeded()
    #expect(policy.paletteFailed() == .logAndRetry)
    for _ in 2...7 { #expect(policy.paletteFailed() == .retry) }
    #expect(policy.paletteFailed() == .refuse)
    #expect(policy.paletteFailed() == .refuse)
  }

  @Test func managedSessionWaitIsBoundedAndPreviewDoesNotWait() {
    #expect(FocusRingRetryPolicy.session(ready: false, elapsed: 0, managed: true) == .wait)
    #expect(FocusRingRetryPolicy.session(ready: false, elapsed: 59.9, managed: true) == .wait)
    #expect(FocusRingRetryPolicy.session(ready: false, elapsed: 60, managed: true) == .refuse)
    #expect(FocusRingRetryPolicy.session(ready: false, elapsed: 61, managed: true) == .refuse)
    #expect(FocusRingRetryPolicy.session(ready: true, elapsed: 59, managed: true) == .ready)
    #expect(FocusRingRetryPolicy.session(ready: false, elapsed: 0, managed: false) == .refuse)
    #expect(FocusRingRetryPolicy.session(ready: true, elapsed: 0, managed: false) == .ready)
  }

  @Test func managedModeIsExplicitAndCannotOverridePreviewDuration() throws {
    let preview = try FocusRingOptions.parse(["--state-root", "/x"])
    #expect(!preview.managed && preview.previewDuration == 30)
    let managed = try FocusRingOptions.parse(["--state-root", "/x", "--managed"])
    #expect(managed.managed && managed.seconds == nil)
    #expect(throws: (any Error).self) {
      try FocusRingOptions.parse(["--state-root", "/x", "--managed", "--seconds", "30"])
    }
    #expect(throws: (any Error).self) {
      try FocusRingOptions.parse(["--state-root", "relative", "--managed"])
    }
  }

  @Test func durationAcceptsInclusiveFiniteBoundsOnly() {
    func parse(_ seconds: Double) throws {
      _ = try FocusRingOptions.parse(["--state-root", "/x", "--seconds", "\(seconds)"])
    }
    for seconds in [1.0, 30, 300] { #expect(throws: Never.self) { try parse(seconds) } }
    for seconds in [0.999, 300.001, 0, -1, .nan, .infinity, -.infinity] {
      #expect(throws: (any Error).self) { try parse(seconds) }
    }
  }

  @Test func accentParsesOnlyHashedHexTriplets() {
    let color = SRGBColor(rawValue: "#FF8000")
    #expect(color?.rawValue == SRGBColor(rawValue: "#ff8000")?.rawValue)
    #expect(color?.components.red == 1)
    #expect(color?.components.green == 128.0 / 255)
    #expect(color?.components.blue == 0)
    for accent in ["", "#", "FF8000", "#FF800", "#FF80000", "#FF800G", " #ff800", "#ff80 0"] {
      #expect(SRGBColor(rawValue: accent) == nil)
    }
  }

  @Test func outlineStrokeCentersOnTargetEdgesOnSecondaryDisplays() {
    #expect(OutlineGeometry.width == 6)
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let cases: [(server: CGRect, appKit: CGRect)] = [
      // Display left of the primary: negative global x.
      (
        CGRect(x: -1920, y: 100, width: 800, height: 600),
        CGRect(x: -1920, y: 200, width: 800, height: 600)
      ),
      // Display above the primary: negative window-server y.
      (
        CGRect(x: 40, y: -1000, width: 500, height: 500),
        CGRect(x: 40, y: 1400, width: 500, height: 500)
      ),
    ]
    for (server, appKit) in cases {
      let target = OutlineGeometry.appKitRect(fromWindowServer: server, primaryScreenFrame: primary)
      #expect(target == appKit)
      let frame = OutlineGeometry.outlineFrame(around: target)
      #expect(frame == target.insetBy(dx: -3, dy: -3))
      let bounds = CGRect(origin: .zero, size: frame.size)
      let stroke = OutlineGeometry.strokeRect(in: bounds)
      // Outer edge is the panel edge; the centerline is the target edge.
      #expect(stroke.insetBy(dx: -3, dy: -3) == bounds)
      #expect(stroke == CGRect(origin: CGPoint(x: 3, y: 3), size: target.size))
    }
  }

  @Test func cornerRadiusClampsToNarrowRects() {
    let cases: [(CGRect, CGFloat)] = [
      (CGRect(x: 0, y: 0, width: 400, height: 300), 9),
      (CGRect(x: 0, y: 0, width: 10, height: 300), 5),
      (CGRect(x: 0, y: 0, width: 400, height: 4), 2),
      (.zero, 0),
    ]
    for (rect, radius) in cases { #expect(OutlineGeometry.pathRadius(for: rect) == radius) }
  }

  @Test func orderingRepeatsOnlyWhenStackMayHaveChanged() {
    func needsOrder(
      visible: Bool = true, previous: UInt32? = 10, target: UInt32 = 10, level: Bool = false
    ) -> Bool {
      OutlineOrdering.needsOrder(
        isVisible: visible, previousTarget: previous, target: target, levelChanged: level)
    }
    #expect(!needsOrder())
    #expect(needsOrder(visible: false))
    #expect(needsOrder(target: 11))
    #expect(needsOrder(level: true))
    #expect(needsOrder(previous: nil))
  }

  @Test func cornerRadiusUsesNativeValueOrIncumbentFallback() {
    #expect(OutlineGeometry.resolvedCornerRadius(nil) == 9)
    for radius: CGFloat in [0, -4, .nan, .infinity] {
      #expect(OutlineGeometry.resolvedCornerRadius(radius) == 9)
    }
    #expect(OutlineGeometry.resolvedCornerRadius(16) == 16)
    let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
    #expect(OutlineGeometry.pathRadius(for: rect, cornerRadius: 16) == 16)
    #expect(OutlineGeometry.pathRadius(for: rect, cornerRadius: 0) == 9)
    let narrow = CGRect(x: 0, y: 0, width: 10, height: 40)
    #expect(OutlineGeometry.pathRadius(for: narrow, cornerRadius: 16) == 5)
  }

  private func window(
    tags: UInt64 = Bit.document, attributes: UInt64 = Bit.visibleAttribute, parent: UInt32 = 0
  ) -> WindowCandidate {
    WindowCandidate(windowID: 10, parentID: parent, tags: tags, attributes: attributes, level: 0)
  }

  @Test func suitabilityMatchesJankyBordersRule() {
    let suitable = [
      window(),
      window(tags: Bit.floating | Bit.modal),
      window(tags: Bit.document | Bit.alternateVisible, attributes: 0),
    ]
    for candidate in suitable {
      #expect(FocusTargetPolicy.isSuitable(candidate, excluding: nil))
      #expect(FocusTargetPolicy.isSuitable(candidate, excluding: 99))
    }
    let unsuitable = [
      window(attributes: 0),
      window(parent: 3),
      window(tags: Bit.document | Bit.attached),
      window(tags: Bit.document | Bit.ignoresCycle),
      window(tags: Bit.floating),
      window(tags: Bit.modal),
      window(tags: 0),
    ]
    for candidate in unsuitable {
      #expect(!FocusTargetPolicy.isSuitable(candidate, excluding: nil))
    }
    #expect(!FocusTargetPolicy.isSuitable(window(), excluding: 10))
  }

  private func space(type: Any?) -> [String: Any] {
    var space: [String: Any] = ["ManagedSpaceID": NSNumber(value: 7)]
    space["type"] = type
    return space
  }

  private func classify(
    _ space: [String: Any], display: String = "Main", spaceID: UInt64 = 7
  ) throws -> SpaceKind {
    let displays: [Any] = [
      "unexpected",
      ["Display Identifier": "Main", "Current Space": space, "Spaces": [space]] as [String: Any],
    ]
    return try SpaceClassifier.classify(
      displays: displays, displayIdentifier: display, spaceID: spaceID)
  }

  @Test func spaceClassifierRequiresExplicitType() throws {
    #expect(try classify(space(type: NSNumber(value: 0))) == .user)
    #expect(try classify(space(type: NSNumber(value: 4))) == .fullscreen)
    #expect(try classify(space(type: NSNumber(value: 2))) == .other(2))
    let user = space(type: NSNumber(value: 0))
    #expect(throws: SpaceTopologyError.displayMissing) { try classify(user, display: "Other") }
    #expect(throws: SpaceTopologyError.spaceMissing) { try classify(user, spaceID: 8) }
    #expect(throws: SpaceTopologyError.typeMissing) { try classify(space(type: nil)) }
    #expect(throws: SpaceTopologyError.typeMissing) { try classify(space(type: "4")) }
  }

  private func observation(_ uptime: Double, _ reason: String, accent: String = "#000000")
    -> FocusRingObservation
  {
    FocusRingObservation(
      uptime: uptime, visible: false, reason: reason, targetWindowID: nil, frame: nil,
      generationID: "g", accent: accent)
  }

  @Test func diagnosticsRecordStateChangesWithinCapacity() {
    var diagnostics = FocusRingDiagnostics()
    diagnostics.record(observation(0, "a"))
    diagnostics.record(observation(1, "a"))
    #expect(diagnostics.observations.map(\.uptime) == [0])
    diagnostics.record(observation(2, "a", accent: "#ffffff"))
    #expect(diagnostics.observations.count == 2)

    #expect(FocusRingDiagnostics.capacity == 1024)
    for index in 0..<(FocusRingDiagnostics.capacity + 8) {
      diagnostics.record(observation(Double(index + 3), "r\(index)"))
    }
    #expect(diagnostics.observations.count == 1024)
    #expect(diagnostics.dropped == 10)
    diagnostics.record(observation(5000, "r\(FocusRingDiagnostics.capacity + 7)"))
    #expect(diagnostics.dropped == 10)
  }
}
