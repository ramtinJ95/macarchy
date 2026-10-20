import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarAudioPickerTests {
  private let path = "/tmp/a 'quoted'/volume.sh"
  private let device = AudioDevice(
    id: 7, name: "Speaker '\" $(bad)\n--remove all", identity: String(repeating: "a", count: 64))

  @Test func opensWithNamesAsArgumentsAndClosedIdentitySelectors() throws {
    let log = Log()
    var launches: [[String]] = []
    let picker = SketchyBarAudioPicker(
      processRunner: runner(log: log), read: { AudioDevices(devices: [device], selected: 7) },
      select: { _, _ in Issue.record("unexpected selection") },
      launch: { launches.append($0) })
    try picker.execute(
      action: "toggle", name: "macarchy.volume", pluginPath: path, text: "0xffffffff",
      muted: "0xff888888")
    let args = try #require(log.values.withLock { $0.last })
    let name = SketchyBarAudioPicker.prefix + "7." + device.identity
    #expect(args.contains("label=\(device.name)"))
    #expect(args.contains("label.color=0xffffffff"))
    #expect(args.contains("popup.drawing=on"))
    let click = SketchyBarAudioPicker.clickScript(name: name, pluginPath: path)
    #expect(args.contains("click_script=\(click)"))
    #expect(!click.contains(device.name))
    #expect(click.contains("'\\''"))
    #expect(launches == [["desktop", "_popup-watch", "--popup", "macarchy.volume.bracket"]])
  }

  @Test(arguments: ["close", "toggle", "select"])
  func closesAndRemovesOnlyValidatedRows(action: String) throws {
    let log = Log()
    let name = SketchyBarAudioPicker.prefix + "7." + device.identity
    var selections = 0
    let picker = SketchyBarAudioPicker(
      processRunner: runner(log: log, row: name, drawing: "on"),
      read: {
        Issue.record("closing must not query hardware")
        return AudioDevices(devices: [], selected: 0)
      },
      select: { id, identity in
        selections += 1
        #expect(id == 7)
        #expect(identity == device.identity)
      }, launch: { _ in Issue.record("closing must not start a popup watcher") })
    try picker.execute(
      action: action, name: name, pluginPath: path, text: "0xffffffff", muted: "0xff888888")
    #expect(selections == (action == "select" ? 1 : 0))
    #expect(
      log.values.withLock { $0.last } == [
        "--set", "macarchy.volume.bracket", "popup.drawing=off", "--remove", name,
      ])
  }

  /// SketchyBar prints a row's label verbatim, so the device name reaches the reply unescaped.
  @Test func closesRowsWhoseDeviceNamesSketchyBarPrintsVerbatim() throws {
    let log = Log()
    let name = SketchyBarAudioPicker.prefix + "7." + device.identity
    let plainPath = "/tmp/plain/volume.sh"
    let picker = SketchyBarAudioPicker(
      processRunner: runner(log: log, row: name, drawing: "on", nativeRowPluginPath: plainPath),
      read: { AudioDevices(devices: [], selected: 0) },
      select: { _, _ in Issue.record("unexpected selection") },
      launch: { _ in Issue.record("closing must not start a popup watcher") })
    try picker.execute(
      action: "close", name: name, pluginPath: plainPath, text: "0xffffffff", muted: "0xff888888")
    #expect(
      log.values.withLock { $0.last } == [
        "--set", "macarchy.volume.bracket", "popup.drawing=off", "--remove", name,
      ])
  }

  @Test func refusesUnownedRowsAndPreservesQueryFailures() throws {
    let log = Log()
    let name = SketchyBarAudioPicker.prefix + "7." + device.identity
    for invalid in [true, false] {
      let picker = SketchyBarAudioPicker(
        processRunner: runner(log: log, row: name, valid: !invalid),
        read: { throw AudioDeviceError.coreAudio(-1) }, select: { _, _ in },
        launch: { _ in Issue.record("a failed picker must not start a popup watcher") })
      #expect(throws: invalid ? AudioDeviceError.invalidInventory : .coreAudio(-1)) {
        try picker.execute(
          action: "toggle", name: "macarchy.volume", pluginPath: path, text: "0xffffffff",
          muted: "0xff888888")
      }
    }
    #expect(log.values.withLock { $0.allSatisfy { $0.first == "--query" } })
  }

  @Test(arguments: [
    "7.bad", "07." + String(repeating: "a", count: 64), "0." + String(repeating: "a", count: 64),
    "7." + String(repeating: "a", count: 64) + ";bad",
  ])
  func rejectsMalformedSelectors(suffix: String) {
    #expect(SketchyBarAudioPicker.selector(SketchyBarAudioPicker.prefix + suffix) == nil)
  }

  private final class Log: Sendable { let values = Mutex<[[String]]>([]) }

  private func runner(
    log: Log, row: String? = nil, drawing: String = "off", valid: Bool = true,
    nativeRowPluginPath: String? = nil
  ) -> ProcessRunner {
    let pluginPath = path
    let deviceName = device.name
    return ProcessRunner { request in
      log.values.withLock { $0.append(request.arguments) }
      if let row, let nativeRowPluginPath, request.arguments == ["--query", row] {
        return ProcessResult(
          terminationStatus: 0,
          output: SketchyBarNativeQuery.item(
            name: row, position: "popup", label: deviceName,
            clickScript: SketchyBarAudioPicker.clickScript(
              name: row, pluginPath: nativeRowPluginPath)))
      }
      var object: [String: Any] = [:]
      if request.arguments == ["--query", "bar"] {
        object = ["items": ["macarchy.volume", "unmanaged"] + (row.map { [$0] } ?? [])]
      } else if request.arguments == ["--query", "macarchy.volume.bracket"] {
        object = [
          "name": "macarchy.volume.bracket", "type": "bracket",
          "geometry": ["drawing": "on", "position": "right"],
          "label": ["drawing": "off", "value": ""],
          "scripting": ["script": "", "click_script": "", "update_freq": 0],
          "bracket": ["macarchy.volume", "macarchy.volume.icon"],
          "popup": [
            "drawing": drawing, "items": ["macarchy.volume.slider"] + (row.map { [$0] } ?? []),
          ],
        ]
      } else if let row, request.arguments == ["--query", row] {
        object = [
          "name": row, "type": "item", "geometry": ["drawing": "on", "position": "popup"],
          "label": ["drawing": "on", "value": "Speaker"],
          "scripting": [
            "script": "", "update_freq": 0,
            "click_script": valid
              ? SketchyBarAudioPicker.clickScript(name: row, pluginPath: pluginPath) : "unmanaged",
          ],
        ]
      }
      return ProcessResult(
        terminationStatus: 0,
        output: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
  }
}
