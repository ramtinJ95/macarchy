import Foundation
import ThemeCore

struct SketchyBarWiFi {
  struct Colors {
    let text: String
    let accent: String
    let muted: String
    let error: String

    var valid: Bool {
      [text, accent, muted, error].allSatisfy {
        $0.range(of: #"^0x[0-9a-f]{8}$"#, options: .regularExpression) != nil
      }
    }
  }

  let processRunner: ProcessRunner
  let read: () throws -> WiFiState
  let sleep: (TimeInterval) -> Void
  let uptime: () -> TimeInterval
  let copy: (String) throws -> Void

  func execute(name: String, sender: String, colors: Colors) throws {
    let mainItems = ["macarchy.wifi", "macarchy.wifi.up", "macarchy.wifi.down"]
    let detailItems = ["ssid", "hostname", "ip", "mask", "router"].map { "macarchy.wifi.\($0)" }
    guard colors.valid, (mainItems + detailItems).contains(name) else {
      throw WiFiError.invalidInvocation
    }
    if sender == "mouse.exited.global" {
      try bar(["--set", "macarchy.wifi.bracket", "popup.drawing=off"])
      return
    }
    if sender == "mouse.clicked", detailItems.contains(name) {
      let result = try bar(["--query", name])
      struct Item: Decodable {
        struct Label: Decodable { let value: String }
        let label: Label
      }
      let value = try JSONDecoder().decode(Item.self, from: Data(result.utf8)).label.value
      guard value.utf8.count <= 1024, !value.isEmpty else { throw WiFiError.invalidInvocation }
      try copy(value)
      try bar(["--set", name, "label=􀉄"])
      sleep(1)
      try bar(["--set", name, "label=\(value)"])
      return
    }
    if sender != "mouse.clicked", name != "macarchy.wifi" { return }
    do {
      let previous = try read()
      if sender == "mouse.clicked" {
        var arguments = ["--set", "macarchy.wifi.bracket", "popup.drawing=toggle"]
        for (field, value) in previous.details {
          arguments += ["--set", "macarchy.wifi.\(field)", "label=\(value)"]
        }
        try bar(arguments)
        return
      }
      guard mainItems.contains(name) else { throw WiFiError.invalidInvocation }
      let start = uptime()
      if previous.interface != nil { sleep(1) }
      let current = previous.interface == nil ? previous : try read()
      let rates =
        current.interface == nil
        ? (upload: "Unavailable", download: "Unavailable")
        : try current.rates(since: previous, seconds: uptime() - start)
      let uploadColor =
        rates.upload == "000 Bps" || current.interface == nil ? colors.muted : colors.error
      let downloadColor =
        rates.download == "000 Bps" || current.interface == nil ? colors.muted : colors.accent
      let connected = current.address != nil
      var arguments = [
        "--set", "macarchy.wifi", "icon=\(connected ? "􀙇" : "􀙈")",
        "icon.color=\(connected ? colors.text : colors.error)",
        "--set", "macarchy.wifi.up", "label=\(rates.upload)", "label.color=\(uploadColor)",
        "icon.color=\(uploadColor)",
        "--set", "macarchy.wifi.down", "label=\(rates.download)", "label.color=\(downloadColor)",
        "icon.color=\(downloadColor)",
      ]
      for (field, value) in current.details {
        arguments += ["--set", "macarchy.wifi.\(field)", "label=\(value)"]
      }
      try bar(arguments)
    } catch {
      do {
        try bar([
          "--set", "macarchy.wifi.up", "label=ERR", "label.color=\(colors.error)",
          "--set", "macarchy.wifi.down", "label=ERR", "label.color=\(colors.error)",
          "--set", "macarchy.wifi.ssid", "label=Network query failed",
        ])
      } catch let reportingError {
        throw WiFiError.queryFailed(
          "network query failed (\(error)); error presentation failed (\(reportingError))")
      }
      throw error
    }
  }

  @discardableResult
  private func bar(_ arguments: [String]) throws -> String {
    let result = try processRunner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/opt/homebrew/bin/sketchybar"), arguments: arguments,
        timeout: 1))
    guard result.terminationStatus == 0 else {
      throw WiFiError.queryFailed("SketchyBar rejected Wi-Fi update")
    }
    return result.output
  }
}
