import CoreGraphics
import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarPopupWatchTests {
  // Measured on a 1920x1080 display: the Wi-Fi icon in the bar and the first two popup rows.
  private let icon = CGRect(x: 1703, y: 0, width: 26, height: 30)
  private let rows = [
    CGRect(x: 1613, y: 32, width: 250, height: 30), CGRect(x: 1613, y: 62, width: 250, height: 30),
  ]

  private func verdicts(
    _ samples: [(point: CGPoint, time: TimeInterval)], drawn: Bool = true, rows: [CGRect]? = nil
  ) -> [PopupPointerWatch.Verdict] {
    var watch = PopupPointerWatch(started: 0)
    return samples.map {
      watch.observe(
        drawn: drawn, pointer: $0.point, owner: [icon], rows: rows ?? self.rows, at: $0.time)
    }
  }

  @Test func staysOpenWhileThePointerMovesFromTheIconThroughTheRows() {
    let path = [
      CGPoint(x: 1716, y: 15), CGPoint(x: 1716, y: 31), CGPoint(x: 1620, y: 61.5),
      CGPoint(x: 1860, y: 90),
    ]
    let samples = path.enumerated().map { (point: $0.element, time: Double($0.offset) * 0.15) }
    #expect(verdicts(samples).allSatisfy { $0 == .keepOpen })
  }

  @Test func closesOnlyAfterThePointerStaysOutsideForTheDelay() {
    let below = CGPoint(x: 1700, y: 200)
    #expect(
      verdicts([(below, 1), (below, 1.15), (below, 1.29), (below, 1.3)]) == [
        .keepOpen, .keepOpen, .keepOpen, .close,
      ])
    let inside = CGPoint(x: 1700, y: 40)
    #expect(
      verdicts([(below, 1), (below, 1.2), (inside, 1.25), (below, 1.4), (below, 1.6)]) == [
        .keepOpen, .keepOpen, .keepOpen, .keepOpen, .keepOpen,
      ])
  }

  @Test(arguments: [
    (CGPoint(x: 1607.5, y: 50), true), (CGPoint(x: 1606.5, y: 50), false),
    (CGPoint(x: 1700, y: 97.5), true), (CGPoint(x: 1700, y: 98.5), false),
    (CGPoint(x: 1690, y: 15), false),
  ])
  func toleranceCoversThePopupBorderButNotTheRestOfTheBar(sample: (CGPoint, Bool)) {
    let expected: PopupPointerWatch.Verdict = sample.1 ? .keepOpen : .close
    #expect(verdicts([(sample.0, 0), (sample.0, 0.3)]) == [.keepOpen, expected])
  }

  @Test func rowGapsWithinTheToleranceDoNotClose() {
    let gapped = [
      CGRect(x: 1613, y: 32, width: 250, height: 30),
      CGRect(x: 1613, y: 70, width: 250, height: 30),
    ]
    let gap = CGPoint(x: 1700, y: 66)
    #expect(verdicts([(gap, 0), (gap, 0.3)], rows: gapped) == [.keepOpen, .keepOpen])
  }

  @Test func rectanglesOnEveryDisplayCount() {
    let external = CGRect(x: -1440, y: 32, width: 250, height: 30)
    let point = CGPoint(x: -1300, y: 45)
    let both = verdicts([(point, 0), (point, 0.3)], rows: rows + [external])
    #expect(both == [.keepOpen, .keepOpen])
    #expect(verdicts([(point, 0), (point, 0.3)]) == [.keepOpen, .close])
  }

  @Test func unknownRowGeometryKeepsThePopupOpen() {
    let below = CGPoint(x: 1700, y: 200)
    #expect(verdicts([(below, 0), (below, 1)], rows: []) == [.keepOpen, .keepOpen])
  }

  @Test func stopsWhenThePopupIsClosedOrTheWatchOutlivesItsCap() {
    let inside = CGPoint(x: 1716, y: 15)
    #expect(verdicts([(inside, 0)], drawn: false) == [.stop])
    #expect(
      verdicts([(inside, PopupPointerWatch.lifetime - 0.01), (inside, PopupPointerWatch.lifetime)])
        == [.keepOpen, .stop])
  }

  @Test func decodesBoundingRectanglesOnEveryDisplay() throws {
    let json = """
      {"name": "macarchy.wifi.bracket", "bounding_rects": {
        "display-2": {"origin": [-1500.5, 0], "size": [26, 30]},
        "display-1": {"origin": [1703, 0], "size": [26, 30]},
        "display-3": {"origin": [0, 0], "size": [0, 0]}},
       "popup": {"drawing": "on", "items": ["macarchy.wifi.ssid", "macarchy.wifi.ip"]}}
      """
    let frame = try JSONDecoder().decode(SketchyBarItemFrame.self, from: Data(json.utf8))
    #expect(
      frame.rects == [
        CGRect(x: 1703, y: 0, width: 26, height: 30),
        CGRect(x: -1500.5, y: 0, width: 26, height: 30),
      ])
    #expect(frame.popup?.drawing == "on")
    #expect(frame.popup?.items == ["macarchy.wifi.ssid", "macarchy.wifi.ip"])
    let hidden = try JSONDecoder().decode(
      SketchyBarItemFrame.self, from: Data(#"{"name": "macarchy.wifi.ssid"}"#.utf8))
    #expect(hidden.rects.isEmpty)
    #expect(hidden.popup == nil)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        SketchyBarItemFrame.self,
        from: Data(#"{"bounding_rects": {"display-1": {"origin": [1], "size": [2, 3]}}}"#.utf8))
    }
  }

  @Test func watcherClosesThePopupOnceThePointerLeavesThroughTheBottom() throws {
    let bar = FakeBar()
    let path = [CGPoint(x: 1716, y: 15), CGPoint(x: 1700, y: 45), CGPoint(x: 1700, y: 80)]
    var clock = 0.0
    var samples = 0
    var leftAt: TimeInterval?
    try SketchyBarPopupWatcher(
      popup: .wifi, processRunner: bar.runner,
      pointer: {
        defer { samples += 1 }
        if samples < path.count { return path[samples] }
        leftAt = leftAt ?? clock
        return CGPoint(x: 1700, y: 200)
      },
      uptime: { clock }, sleep: { clock += $0 }
    )
    .run()
    #expect(bar.sets == [["--set", "macarchy.wifi.bracket", "popup.drawing=off"]])
    let outside = clock - (try #require(leftAt))
    #expect(outside >= PopupPointerWatch.closeDelay)
    #expect(outside < PopupPointerWatch.closeDelay + SketchyBarPopupWatcher.interval)
  }

  @Test func watcherLeavesAPopupClosedElsewhereAlone() throws {
    let bar = FakeBar()
    var clock = 0.0
    try SketchyBarPopupWatcher(
      popup: .wifi, processRunner: bar.runner,
      pointer: {
        if clock >= 0.3 { bar.state.withLock { $0.drawing = "off" } }
        return CGPoint(x: 1716, y: 15)
      },
      uptime: { clock }, sleep: { clock += $0 }
    )
    .run()
    #expect(bar.sets.isEmpty)
  }

  @Test func watcherWaitsForRowsThatAreNotLaidOutYet() throws {
    let bar = FakeBar()
    bar.state.withLock { $0.rowsLaidOut = false }
    var clock = 0.0
    try SketchyBarPopupWatcher(
      popup: .wifi, processRunner: bar.runner,
      pointer: {
        if clock >= 0.3 { bar.state.withLock { $0.rowsLaidOut = true } }
        return clock < 1 ? CGPoint(x: 1700, y: 80) : CGPoint(x: 1700, y: 200)
      },
      uptime: { clock }, sleep: { clock += $0 }
    )
    .run()
    #expect(bar.sets == [["--set", "macarchy.wifi.bracket", "popup.drawing=off"]])
    #expect(clock >= 1.3)
  }

  @Test(arguments: ["off", "on"])
  func toggleStartsExactlyOneWatcherOnlyWhenItOpensThePopup(drawing: String) throws {
    let bar = FakeBar()
    bar.state.withLock { $0.drawing = drawing }
    var launches: [[String]] = []
    try SketchyBarPopupToggle(
      popup: .battery, processRunner: bar.runner, launch: { launches.append($0) }
    )
    .execute()
    let opening = drawing == "off"
    #expect(bar.sets == [["--set", "macarchy.battery", "popup.drawing=\(opening ? "on" : "off")"]])
    #expect(launches == (opening ? [BarPopup.battery.watchArguments] : []))
  }

  @Test(arguments: BarPopup.allCases)
  func watchArgumentsRunTheWatchCommandForThatPopup(popup: BarPopup) throws {
    let command = try #require(
      try Macarchy.parseAsRoot(popup.watchArguments) as? Desktop.PopupWatch)
    #expect(command.popup == popup)
    #expect(throws: (any Error).self) {
      try Macarchy.parseAsRoot(["desktop", "_popup-watch", "--popup", "macarchy.clock"])
    }
  }

  @Test func watcherPicksUpRowsThatChangeSizeWhileThePopupIsOpen() throws {
    let bar = FakeBar()
    var clock = 0.0
    try SketchyBarPopupWatcher(
      popup: .wifi, processRunner: bar.runner,
      pointer: {
        if clock >= 0.3 { bar.state.withLock { $0.ipWidth = 400 } }
        if clock < 1.2 { return CGPoint(x: 1700, y: 80) }
        return clock < 3 ? CGPoint(x: 1950, y: 75) : CGPoint(x: 1700, y: 200)
      },
      uptime: { clock }, sleep: { clock += $0 }
    )
    .run()
    #expect(bar.sets == [["--set", "macarchy.wifi.bracket", "popup.drawing=off"]])
    #expect(clock >= 3.3)
  }

  @Test(arguments: [SketchyBarPopupWatcher.failureLimit - 1, SketchyBarPopupWatcher.failureLimit])
  func watcherRidesOutAFewFailedSamplesInARow(failures: Int) throws {
    let bar = FakeBar()
    bar.state.withLock { $0.failingQueries = failures }
    var clock = 0.0
    let watcher = SketchyBarPopupWatcher(
      popup: .wifi, processRunner: bar.runner, pointer: { CGPoint(x: 1700, y: 200) },
      uptime: { clock }, sleep: { clock += $0 })
    if failures < SketchyBarPopupWatcher.failureLimit {
      try watcher.run()
      #expect(bar.sets == [["--set", "macarchy.wifi.bracket", "popup.drawing=off"]])
    } else {
      #expect(throws: PopupWatchError.self) { try watcher.run() }
      #expect(bar.sets.isEmpty)
    }
  }

  @Test func aSecondWatcherWaitsForTheFirstToExit() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-popup-lock-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let second: Task<ContinuousClock.Instant, any Error>
    let released: ContinuousClock.Instant
    do {
      let first = try PopupWatchLock.acquire(.wifi, in: directory)
      _ = try PopupWatchLock.acquire(.volume, in: directory)
      second = Task.detached {
        _ = try PopupWatchLock.acquire(.wifi, in: directory)
        return ContinuousClock.now
      }
      try await Task.sleep(for: .milliseconds(200))
      released = .now
      withExtendedLifetime(first) {}
    }
    #expect(try await second.value >= released)
  }

  /// A running bar with the Wi-Fi bracket, a battery item, and two Wi-Fi rows.
  private final class FakeBar: Sendable {
    struct State {
      var drawing = "on"
      var rowsLaidOut = true
      var ipWidth = 250.0
      var failingQueries = 0
      var sets: [[String]] = []
    }
    let state = Mutex(State())

    var sets: [[String]] { state.withLock { $0.sets } }

    var runner: ProcessRunner {
      ProcessRunner { request in
        #expect(request.executableURL.path == "/opt/homebrew/bin/sketchybar")
        return self.state.withLock { value in
          guard request.arguments.first == "--query" else {
            value.sets.append(request.arguments)
            return ProcessResult(terminationStatus: 0, output: "")
          }
          guard value.failingQueries == 0 else {
            value.failingQueries -= 1
            return ProcessResult(terminationStatus: 1, output: "")
          }
          let rects: [String: [Double]] = [
            "macarchy.wifi.bracket": [1650, 0, 120, 30], "macarchy.battery": [1500, 0, 40, 30],
            "macarchy.wifi.ssid": [1613, 32, 250, 30],
            "macarchy.wifi.ip": [1613, 62, value.ipWidth, 30],
          ]
          let name = request.arguments[1]
          let row = name == "macarchy.wifi.ssid" || name == "macarchy.wifi.ip"
          var object: [String: Any] = [
            "popup": [
              "drawing": value.drawing, "items": ["macarchy.wifi.ssid", "macarchy.wifi.ip"],
            ]
          ]
          if let rect = rects[name], value.rowsLaidOut || !row {
            object["bounding_rects"] = [
              "display-1": ["origin": [rect[0], rect[1]], "size": [rect[2], rect[3]]]
            ]
          }
          let data = try? JSONSerialization.data(withJSONObject: object)
          return ProcessResult(
            terminationStatus: 0, output: String(decoding: data ?? Data(), as: UTF8.self))
        }
      }
    }
  }
}
