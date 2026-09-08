import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarWiFiTests {
  private let colors = SketchyBarWiFi.Colors(
    text: "0xffffffff", accent: "0xff0000ff",
    muted: "0xff888888", error: "0xffff0000")

  @Test(arguments: [
    (0.0, "000 Bps"), (999.0, "999 Bps"), (1000.0, "001KBps"),
    (999999.0, "999KBps"), (1000000.0, "001MBps"), (1000000000.0, "001GBps"),
  ])
  func formatsDecimalRates(sample: (Double, String)) {
    #expect(WiFiState.rate(sample.0) == sample.1)
  }

  @Test
  func samplesCountersWithoutPersistingNetworkIdentity() throws {
    let previous = state(received: .max - 4, sent: 100)
    let current = state(received: 5, sent: 2100)
    let rates = try current.rates(since: previous, seconds: 2)
    #expect(rates.download == "005 Bps")
    #expect(rates.upload == "001KBps")
    #expect(throws: WiFiError.self) { try current.rates(since: previous, seconds: 0) }
    #expect(throws: WiFiError.self) { try current.rates(since: previous, seconds: 10) }
    #expect(throws: WiFiError.self) {
      try current.rates(since: state(interface: nil), seconds: 1)
    }
  }

  @Test(arguments: ["connected", "disconnected", "no_interface"])
  func updatesStackedRatesAndExplicitPrivacyAndConnectionState(condition: String) throws {
    let requests = RequestLog()
    var reads = 0
    var time = 0.0
    let runner = SketchyBarWiFi(
      processRunner: recording(requests),
      read: {
        reads += 1
        return state(
          interface: condition == "no_interface" ? nil : "en7",
          address: condition == "connected" ? "192.0.2.10" : nil,
          received: 0, sent: reads == 1 ? 0 : 2000)
      }, sleep: { time += $0 }, uptime: { time },
      copy: { _ in Issue.record("unexpected clipboard write") })
    try runner.execute(name: "macarchy.wifi", sender: "routine", colors: colors)
    let arguments = try #require(requests.withLock { $0.last })
    #expect(arguments.contains("label=\(condition == "no_interface" ? "Unavailable" : "002KBps")"))
    #expect(
      arguments.contains(
        "label=\(condition == "no_interface" ? "No Wi-Fi interface" : condition == "connected" ? "Privacy restricted" : "Disconnected / no IPv4")"
      ))
    #expect(arguments.contains("label.color=0xff888888"))
    #expect(reads == (condition == "no_interface" ? 1 : 2))
  }

  @Test
  func popupAndClipboardNeverEvaluateNetworkValuesAsShell() throws {
    let requests = RequestLog()
    let value = #"host \" $(touch /tmp/never) ${HOME} `id`"#
    let json = String(
      decoding: try JSONSerialization.data(withJSONObject: ["label": ["value": value]]),
      as: UTF8.self)
    var copied: String?
    var reads = 0
    let runner = SketchyBarWiFi(
      processRunner: recording(requests, output: json),
      read: {
        reads += 1
        return state()
      }, sleep: { _ in }, uptime: { 0 }, copy: { copied = $0 })
    try runner.execute(name: "macarchy.wifi.hostname", sender: "mouse.clicked", colors: colors)
    #expect(copied == value)
    #expect(reads == 0)
    #expect(requests.withLock { $0.last } == ["--set", "macarchy.wifi.hostname", "label=\(value)"])
    try runner.execute(name: "macarchy.wifi.up", sender: "mouse.clicked", colors: colors)
    #expect(reads == 1)
    #expect(requests.withLock { $0.last?.contains("popup.drawing=toggle") } == true)
    try runner.execute(name: "macarchy.wifi", sender: "mouse.exited.global", colors: colors)
    #expect(reads == 1)
    #expect(
      requests.withLock { $0.last } == ["--set", "macarchy.wifi.bracket", "popup.drawing=off"])
    try runner.execute(name: "macarchy.wifi.up", sender: "forced", colors: colors)
    try runner.execute(name: "macarchy.wifi.ssid", sender: "forced", colors: colors)
    #expect(reads == 1)
  }

  @Test
  func queryFailuresReplaceStaleRatesAndUnknownItemsAreRejected() throws {
    let requests = RequestLog()
    let runner = SketchyBarWiFi(
      processRunner: recording(requests),
      read: {
        throw WiFiError.queryFailed("fixture failure")
      }, sleep: { _ in }, uptime: { 0 }, copy: { _ in })
    #expect(throws: WiFiError.self) {
      try runner.execute(name: "macarchy.wifi", sender: "routine", colors: colors)
    }
    #expect(requests.withLock { $0.last?.contains("label=ERR") } == true)
    #expect(requests.withLock { $0.last?.contains("label=Network query failed") } == true)
    #expect(throws: WiFiError.self) {
      try runner.execute(name: "foreign.item", sender: "mouse.clicked", colors: colors)
    }
  }

  private func state(
    interface: String? = "en7", address: String? = "192.0.2.10",
    received: UInt32 = 0, sent: UInt32 = 0
  ) -> WiFiState {
    WiFiState(
      interface: interface, address: address, mask: "255.255.255.0", router: "192.0.2.1",
      hostname: "test-machine", received: received, sent: sent)
  }

  private final class RequestLog: Sendable {
    let values = Mutex<[[String]]>([])
    func withLock<T>(_ body: (inout [[String]]) -> T) -> T {
      values.withLock { body(&$0) }
    }
  }

  private func recording(_ requests: RequestLog, output: String = "") -> ProcessRunner {
    ProcessRunner { request in
      #expect(request.executableURL.path == "/opt/homebrew/bin/sketchybar")
      requests.withLock { $0.append(request.arguments) }
      return ProcessResult(terminationStatus: 0, output: output)
    }
  }
}
