import Testing

@testable import MacarchyFocusRing

struct FocusEventBatchTests {
  @Test func ignoresUnobservedAndUnknownEvents() {
    var batch = FocusEventBatch()
    let accepted1 = batch.merge(event: 807, windowID: 3, observed: [9])
    #expect(!accepted1)
    let accepted2 = batch.merge(event: 804, windowID: nil, observed: [9])
    #expect(!accepted2)
    let accepted3 = batch.merge(event: 999, windowID: 9, observed: [9])
    #expect(!accepted3)
    #expect(batch == FocusEventBatch())
  }

  @Test func coalescesGeometryIntoSetAndCount() {
    var batch = FocusEventBatch()
    for event: UInt32 in [806, 807, 806] {
      let accepted4 = batch.merge(event: event, windowID: 9, observed: [4, 9])
      #expect(accepted4)
    }
    let accepted5 = batch.merge(event: 807, windowID: 4, observed: [4, 9])
    #expect(accepted5)
    #expect(batch == FocusEventBatch(geometryIDs: [4, 9], count: 4))
  }

  @Test func globalsAndOrderingRequestSettledFullRefresh() {
    var global = FocusEventBatch()
    let accepted6 = global.merge(event: 1401, windowID: nil, observed: [])
    #expect(accepted6)
    #expect(global == FocusEventBatch(requiresFullRefresh: true, settle: true, count: 1))

    var window = FocusEventBatch()
    let accepted7 = window.merge(event: 804, windowID: 9, observed: [9])
    #expect(accepted7)
    #expect(window == FocusEventBatch(requiresFullRefresh: true, count: 1))
    let accepted8 = window.merge(event: 808, windowID: 9, observed: [9])
    #expect(accepted8)
    #expect(window == FocusEventBatch(requiresFullRefresh: true, settle: true, count: 2))
  }
}
