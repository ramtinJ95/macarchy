import Foundation
import ThemeCore

struct SketchyBarWiFi {
  var symbolFont = SketchyBarSymbolFont()
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
  let launch: ([String]) throws -> Void

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
      let value = try SketchyBarLabelQuery.value(from: bar(["--query", name]))
      guard value.utf8.count <= 1024, !value.isEmpty else { throw WiFiError.invalidInvocation }
      try copy(value)
      try bar(["--set", name, "label=Copied"])
      sleep(1)
      try bar(["--set", name, "label=\(value)"])
      return
    }
    if sender != "mouse.clicked", name != "macarchy.wifi" { return }
    do {
      let previous = try read()
      if sender == "mouse.clicked" {
        var labels: [String] = []
        for (field, value) in previous.details {
          labels += ["--set", "macarchy.wifi.\(field)", "label=\(value)"]
        }
        try SketchyBarPopupToggle(popup: .wifi, processRunner: processRunner, launch: launch)
          .execute(alongside: labels)
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
        "--set", "macarchy.wifi",
        "icon=\(try symbolFont.icon(connected ? SketchyBarSymbol.wifi.rawValue : SketchyBarSymbol.disconnected.rawValue, item: "macarchy.wifi", bar: bar))",
        "icon.drawing=on", "icon.color=\(connected ? colors.text : colors.error)",
        "--set", "macarchy.wifi.up", "label=\(rates.upload)", "label.color=\(uploadColor)",
        "icon.drawing=on", "icon.color=\(uploadColor)",
        "--set", "macarchy.wifi.down", "label=\(rates.download)", "label.color=\(downloadColor)",
        "icon.drawing=on", "icon.color=\(downloadColor)",
      ]
      for (field, value) in current.details {
        arguments += ["--set", "macarchy.wifi.\(field)", "label=\(value)"]
      }
      try bar(arguments)
    } catch {
      let detail =
        error is SketchyBarSymbolFont.Failure
        ? "Symbol font unavailable; run macarchy setup plan and apply"
        : "Network query failed"
      do {
        try bar([
          "--set", "macarchy.wifi", "icon.drawing=off",
          "--set", "macarchy.wifi.up", "icon.drawing=off", "label.drawing=on",
          "label=ERR", "label.color=\(colors.error)",
          "--set", "macarchy.wifi.down", "icon.drawing=off", "label.drawing=on",
          "label=ERR", "label.color=\(colors.error)",
          "--set", "macarchy.wifi.ssid", "label=\(detail)",
        ])
      } catch let reportingError {
        throw WiFiError.queryFailed(
          "network query failed (\(error)); error presentation failed (\(reportingError))")
      }
      throw error
    }
  }

  private var bar: SketchyBarControl {
    SketchyBarControl(processRunner: processRunner) { _, _ in
      WiFiError.queryFailed("SketchyBar rejected Wi-Fi update")
    }
  }
}
