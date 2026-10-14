import CoreGraphics
import Testing

@testable import MacarchyFocusRing

struct DirectOutlineMovePolicyTests {
  let current = CGRect(x: 100, y: 200, width: 300, height: 400)

  @Test func hiddenPanelIsNotMovedDirectly() {
    let next = current.offsetBy(dx: 10, dy: 0)
    #expect(
      !SkyLightOutlineMover.shouldMoveDirectly(previous: current, next: next, isVisible: false))
  }

  @Test func resizeIsNotMovedDirectly() {
    let next = CGRect(x: 110, y: 200, width: 320, height: 400)
    #expect(
      !SkyLightOutlineMover.shouldMoveDirectly(previous: current, next: next, isVisible: true))
  }

  @Test func unchangedFrameIsNotMovedDirectly() {
    #expect(
      !SkyLightOutlineMover.shouldMoveDirectly(previous: current, next: current, isVisible: true))
  }

  @Test func shownPositionOnlyChangeIsMovedDirectly() {
    let next = current.offsetBy(dx: -25, dy: 40)
    #expect(SkyLightOutlineMover.shouldMoveDirectly(previous: current, next: next, isVisible: true))
  }
}
