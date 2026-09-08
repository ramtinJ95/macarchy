import Testing

@testable import MacarchyCLI

struct CPULoadTests {
  @Test
  func measuresIntervalRatherThanLifetimeAndIncludesNiceTime() throws {
    let previous = CPUTicks(user: 1000, system: 2000, idle: 3000, nice: 4000)
    let current = CPUTicks(user: 1010, system: 2020, idle: 3060, nice: 4010)
    #expect(try current.utilization(since: previous) == 40)
    #expect(throws: CPULoadError.self) { try previous.utilization(since: previous) }
  }

  @Test
  func handlesCounterWrapAndExtremeLoads() throws {
    let previous = CPUTicks(user: .max - 4, system: 0, idle: 0, nice: 0)
    let current = CPUTicks(user: 5, system: 0, idle: 10, nice: 0)
    #expect(try current.utilization(since: previous) == 50)
    let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    #expect(try CPUTicks(user: 1, system: 0, idle: 0, nice: 0).utilization(since: zero) == 100)
    #expect(try CPUTicks(user: 0, system: 0, idle: 1, nice: 0).utilization(since: zero) == 0)
  }
}
