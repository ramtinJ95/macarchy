import Testing

@testable import MacarchyFocusRing

struct FocusEventBatchTests {
  @Test func ignoresOwnUnobservedAndUnknownEvents() {
    var batch = FocusEventBatch()
    let accepted1 = batch.merge(event: 806, windowID: 7, observed: [7, 9], own: 7)
    #expect(!accepted1)
    let accepted2 = batch.merge(event: 807, windowID: 3, observed: [9], own: 7)
    #expect(!accepted2)
    let accepted3 = batch.merge(event: 804, windowID: nil, observed: [9], own: nil)
    #expect(!accepted3)
    let accepted4 = batch.merge(event: 999, windowID: 9, observed: [9], own: nil)
    #expect(!accepted4)
    #expect(batch == FocusEventBatch())
  }

  @Test func coalescesGeometryIntoSetAndCount() {
    var batch = FocusEventBatch()
    for event: UInt32 in [806, 807, 806] {
      let accepted5 = batch.merge(event: event, windowID: 9, observed: [4, 9], own: 1)
      #expect(accepted5)
    }
    let accepted6 = batch.merge(event: 807, windowID: 4, observed: [4, 9], own: 1)
    #expect(accepted6)
    #expect(batch == FocusEventBatch(geometryIDs: [4, 9], count: 4))
  }

  @Test func globalsAndOrderingRequestSettledFullRefresh() {
    var global = FocusEventBatch(count: .max)
    let accepted7 = global.merge(event: 1401, windowID: nil, observed: [], own: nil)
    #expect(accepted7)
    #expect(global == FocusEventBatch(requiresFullRefresh: true, settle: true, count: .max))

    var window = FocusEventBatch()
    let accepted8 = window.merge(event: 804, windowID: 9, observed: [9], own: nil)
    #expect(accepted8)
    #expect(window == FocusEventBatch(requiresFullRefresh: true, count: 1))
    let accepted9 = window.merge(event: 808, windowID: 9, observed: [9], own: nil)
    #expect(accepted9)
    #expect(window == FocusEventBatch(requiresFullRefresh: true, settle: true, count: 2))
  }
}
