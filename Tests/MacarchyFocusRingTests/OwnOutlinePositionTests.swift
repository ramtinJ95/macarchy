import CoreGraphics
import Testing

@testable import MacarchyFocusRing

struct OwnOutlinePositionTests {
  private let requested = CGPoint(x: 100, y: 200)

  @Test func acceptsExactOrigin() throws {
    try SkyLightOutlineMover.validateCommittedBounds(
      actual: CGRect(x: 100, y: 200, width: 40, height: 30), requestedOrigin: requested)
  }

  @Test func acceptsOriginWithinTolerance() throws {
    try SkyLightOutlineMover.validateCommittedBounds(
      actual: CGRect(x: 100.5, y: 199.5, width: 40, height: 30), requestedOrigin: requested)
  }

  @Test(arguments: [
    CGRect(x: 100.51, y: 200, width: 40, height: 30),
    CGRect(x: 100, y: 199.49, width: 40, height: 30),
    CGRect(x: 0, y: 0, width: 40, height: 30),
  ])
  func rejectsWrongOrigin(actual: CGRect) {
    #expect(throws: FocusRingError.self) {
      try SkyLightOutlineMover.validateCommittedBounds(actual: actual, requestedOrigin: requested)
    }
  }

  @Test(arguments: [
    CGRect(x: CGFloat.nan, y: 200, width: 40, height: 30),
    CGRect(x: 100, y: CGFloat.infinity, width: 40, height: 30),
    CGRect(x: 100, y: 200, width: CGFloat.nan, height: 30),
    CGRect(x: 100, y: 200, width: 40, height: CGFloat.infinity),
    CGRect(x: 100, y: 200, width: 0, height: 30),
    CGRect(x: 100, y: 200, width: 40, height: -1),
  ])
  func rejectsNonFiniteOrInvalidBounds(actual: CGRect) {
    #expect(throws: FocusRingError.self) {
      try SkyLightOutlineMover.validateCommittedBounds(actual: actual, requestedOrigin: requested)
    }
  }
}
