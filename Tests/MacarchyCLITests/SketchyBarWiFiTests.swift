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

  @Test(
    arguments: ["connected", "disconnected", "no_interface"], ["SF Pro", "MesloLGS Nerd Font Mono"])
  func updatesStackedRatesAndExplicitPrivacyAndConnectionState(condition: String, family: String)
    throws
  {
    let requests = RequestLog()
    var reads = 0
    var time = 0.0
    let runner = SketchyBarWiFi(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: recording(requests, font: "\(family):Bold:13.00"),
      read: {
        reads += 1
        return state(
          interface: condition == "no_interface" ? nil : "en7",
          address: condition == "connected" ? "192.0.2.10" : nil,
          received: 0, sent: reads == 1 ? 0 : 2000)
      }, sleep: { time += $0 }, uptime: { time },
      copy: { _ in Issue.record("unexpected clipboard write") },
      launch: { _ in Issue.record("unexpected launch") })
    try runner.execute(name: "macarchy.wifi", sender: "routine", colors: colors)
    let arguments = try #require(requests.withLock { $0.last })
    #expect(arguments.contains("label=\(condition == "no_interface" ? "Unavailable" : "002KBps")"))
    #expect(
      arguments.contains(
        "label=\(condition == "no_interface" ? "No Wi-Fi interface" : condition == "connected" ? "Privacy restricted" : "Disconnected / no IPv4")"
      ))
    #expect(arguments.contains("label.color=0xff888888"))
    let icon =
      family == "SF Pro"
      ? (condition == "connected" ? "\u{100647}" : "\u{100648}")
      : (condition == "connected" ? "\u{f1eb}" : "\u{f127}")
    #expect(arguments.contains("icon=\(icon)"))
    #expect(requests.withLock { $0.contains(["--query", "macarchy.wifi"]) })
    #expect(reads == (condition == "no_interface" ? 1 : 2))
  }

  @Test
  func popupAndClipboardNeverEvaluateNetworkValuesAsShell() throws {
    let requests = RequestLog()
    let value = #"host \" $(touch /tmp/never) ${HOME} `id`"#
    let reply = SketchyBarNativeQuery.item(
      name: "macarchy.wifi.hostname", position: "popup", label: value)
    var copied: String?
    var reads = 0
    var launches: [[String]] = []
    let runner = SketchyBarWiFi(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: recording(requests) { arguments in
        arguments == ["--query", "macarchy.wifi.bracket"] ? Self.popupQuery(drawing: "off") : reply
      },
      read: {
        reads += 1
        return state()
      }, sleep: { _ in }, uptime: { 0 }, copy: { copied = $0 }, launch: { launches.append($0) })
    try runner.execute(name: "macarchy.wifi.hostname", sender: "mouse.clicked", colors: colors)
    #expect(copied == value)
    #expect(requests.withLock { $0.contains(["--set", "macarchy.wifi.hostname", "label=Copied"]) })
    #expect(reads == 0)
    #expect(requests.withLock { $0.last } == ["--set", "macarchy.wifi.hostname", "label=\(value)"])
    try runner.execute(name: "macarchy.wifi.up", sender: "mouse.clicked", colors: colors)
    #expect(reads == 1)
    #expect(requests.withLock { $0.last?.contains("popup.drawing=on") } == true)
    #expect(requests.withLock { $0.last?.contains("label=test-machine") } == true)
    #expect(launches == [["desktop", "_popup-watch", "--popup", "macarchy.wifi.bracket"]])
    try runner.execute(name: "macarchy.wifi", sender: "mouse.exited.global", colors: colors)
    #expect(reads == 1)
    #expect(
      requests.withLock { $0.last } == ["--set", "macarchy.wifi.bracket", "popup.drawing=off"])
    try runner.execute(name: "macarchy.wifi.up", sender: "forced", colors: colors)
    try runner.execute(name: "macarchy.wifi.ssid", sender: "forced", colors: colors)
    #expect(reads == 1)
  }

  @Test
  func clickClosesAnOpenPopupWithoutStartingAWatcher() throws {
    let requests = RequestLog()
    var launches = 0
    let runner = SketchyBarWiFi(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: recording(requests) { _ in Self.popupQuery(drawing: "on") },
      read: { state() }, sleep: { _ in }, uptime: { 0 }, copy: { _ in },
      launch: { _ in launches += 1 })
    try runner.execute(name: "macarchy.wifi", sender: "mouse.clicked", colors: colors)
    let arguments = try #require(requests.withLock { $0.last })
    #expect(Array(arguments.prefix(3)) == ["--set", "macarchy.wifi.bracket", "popup.drawing=off"])
    #expect(launches == 0)
  }

  @Test
  func queryFailuresReplaceStaleRatesAndUnknownItemsAreRejected() throws {
    let requests = RequestLog()
    let runner = SketchyBarWiFi(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: recording(requests),
      read: {
        throw WiFiError.queryFailed("fixture failure")
      }, sleep: { _ in }, uptime: { 0 }, copy: { _ in }, launch: { _ in })
    #expect(throws: WiFiError.self) {
      try runner.execute(name: "macarchy.wifi", sender: "routine", colors: colors)
    }
    #expect(requests.withLock { $0.last?.contains("label=ERR") } == true)
    #expect(requests.withLock { $0.last?.contains("label=Network query failed") } == true)
    #expect(throws: WiFiError.self) {
      try runner.execute(name: "foreign.item", sender: "mouse.clicked", colors: colors)
    }
  }

  @Test(arguments: ["SF Pro", "MesloLGS Nerd Font Mono"])
  func fontFailuresHideStaleSymbolsShowErrorsAndRecoverWithoutReapplication(family: String) throws {
    let requests = RequestLog()
    requests.withLock {
      $0.append(["--set", "macarchy.wifi", "icon=\u{f1eb}", "icon.drawing=on"])
    }
    let process = recording(requests, font: "\(family):Bold:13.00")
    func helper(available: Bool) -> SketchyBarWiFi {
      SketchyBarWiFi(
        symbolFont: .init(supports: { _, _ in available }), processRunner: process,
        read: { state(interface: nil, address: nil) }, sleep: { _ in }, uptime: { 0 },
        copy: { _ in Issue.record("unexpected copy") }, launch: { _ in })
    }
    #expect(throws: SketchyBarSymbolFont.Failure.self) {
      try helper(available: false).execute(name: "macarchy.wifi", sender: "routine", colors: colors)
    }
    #expect(requests.properties("macarchy.wifi")["icon"] == "\u{f1eb}")
    for item in ["macarchy.wifi", "macarchy.wifi.up", "macarchy.wifi.down"] {
      #expect(requests.properties(item)["icon.drawing"] == "off")
    }
    for item in ["macarchy.wifi.up", "macarchy.wifi.down"] {
      #expect(requests.properties(item)["label.drawing"] == "on")
      #expect(requests.properties(item)["label"] == "ERR")
    }
    #expect(
      requests.properties("macarchy.wifi.ssid")["label"]
        == "Symbol font unavailable; run macarchy setup plan and apply")
    try helper(available: true).execute(name: "macarchy.wifi", sender: "routine", colors: colors)
    for item in ["macarchy.wifi", "macarchy.wifi.up", "macarchy.wifi.down"] {
      #expect(requests.properties(item)["icon.drawing"] == "on")
    }
    #expect(
      requests.properties("macarchy.wifi")["icon"]
        == (family == "SF Pro" ? "\u{100648}" : "\u{f127}"))
    #expect(requests.properties("macarchy.wifi.down")["label"] == "Unavailable")
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
    func properties(_ item: String) -> [String: String] {
      values.withLock { calls in
        var properties: [String: String] = [:]
        for arguments in calls {
          var target = ""
          for (index, argument) in arguments.enumerated() {
            if index > 0, arguments[index - 1] == "--set" { target = argument }
            let pair = argument.split(
              separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if target == item, pair.count == 2 { properties[String(pair[0])] = String(pair[1]) }
          }
        }
        return properties
      }
    }
    func withLock<T>(_ body: (inout [[String]]) -> T) -> T {
      values.withLock { body(&$0) }
    }
  }

  private static func popupQuery(drawing: String) -> String {
    #"{"popup": {"drawing": "\#(drawing)", "items": ["macarchy.wifi.ssid"]}}"#
  }

  private func recording(
    _ requests: RequestLog, font: String = "MesloLGS Nerd Font Mono:Bold:13.00",
    output: @escaping @Sendable ([String]) -> String = { _ in "" }
  ) -> ProcessRunner {
    ProcessRunner { request in
      #expect(request.executableURL.path == "/opt/homebrew/bin/sketchybar")
      requests.withLock { $0.append(request.arguments) }
      if request.arguments == ["--query", "macarchy.wifi"] {
        return .init(
          terminationStatus: 0,
          output: #"{"name":"macarchy.wifi","icon":{"font":"\#(font)"}}"#)
      }
      return ProcessResult(terminationStatus: 0, output: output(request.arguments))
    }
  }
}
