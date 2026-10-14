import Testing

@testable import MacarchyFocusRing

struct SkyLightOutlineMoverTests {
  @Test func rejectsInvalidConnectionOrWindowID() {
    #expect(throws: FocusRingError.self) {
      try SkyLightOutlineMover.validateOwnership(connection: 0, windowID: 7, status: 0, owner: 0)
    }
    #expect(throws: FocusRingError.self) {
      try SkyLightOutlineMover.validateOwnership(connection: -1, windowID: 7, status: 0, owner: -1)
    }
    #expect(throws: FocusRingError.self) {
      try SkyLightOutlineMover.validateOwnership(connection: 5, windowID: 0, status: 0, owner: 5)
    }
  }

  @Test func rejectsFailedQueryOrForeignOwner() {
    #expect(throws: FocusRingError.self) {
      try SkyLightOutlineMover.validateOwnership(connection: 5, windowID: 7, status: 1001, owner: 5)
    }
    #expect(throws: FocusRingError.self) {
      try SkyLightOutlineMover.validateOwnership(connection: 5, windowID: 7, status: 0, owner: 6)
    }
  }

  @Test func acceptsOwnWindow() throws {
    try SkyLightOutlineMover.validateOwnership(connection: 5, windowID: 7, status: 0, owner: 5)
  }
}
