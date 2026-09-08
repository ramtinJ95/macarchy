import ArgumentParser
import Foundation
import ThemeCore

struct SketchyBarAudioPicker {
  static let prefix = "macarchy.volume.device."
  static let popupOwner = "macarchy.volume.bracket"
  let processRunner: ProcessRunner
  let read: () throws -> AudioOutputs
  let select: (UInt32, String) throws -> Void

  static func selector(_ name: String) -> (id: UInt32, identity: String)? {
    guard name.hasPrefix(prefix) else { return nil }
    let parts = name.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let id = UInt32(parts[0]), id > 0,
      String(id) == parts[0],
      parts[1].range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    else { return nil }
    return (id, String(parts[1]))
  }

  static func clickScript(name: String, pluginPath: String) -> String {
    func quote(_ value: String) -> String {
      "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return "SENDER=macarchy.output NAME=\(quote(name)) \(quote(pluginPath))"
  }

  // These rows exist only while the popup is open. Validate them before excluding
  // them from durable runtime evidence; never persist hardware identities there.
  struct Row: Decodable {
    struct Geometry: Decodable {
      let drawing: String
      let position: String
    }
    struct Label: Decodable {
      let drawing: String
      let value: String
    }
    struct Scripting: Decodable {
      let script: String
      let clickScript: String
      let updateFrequency: Int
      enum CodingKeys: String, CodingKey {
        case script
        case clickScript = "click_script"
        case updateFrequency = "update_freq"
      }
    }
    let name: String
    let type: String
    let geometry: Geometry
    let label: Label
    let scripting: Scripting

    func valid(name expected: String, pluginPath: String) -> Bool {
      name == expected && SketchyBarAudioPicker.selector(name) != nil && type == "item"
        && geometry.drawing == "on" && geometry.position == "popup"
        && label.drawing == "on" && !label.value.isEmpty
        && (scripting.script.isEmpty || scripting.script == "(null)")
        && scripting.updateFrequency == 0
        && scripting.clickScript
          == SketchyBarAudioPicker.clickScript(name: name, pluginPath: pluginPath)
    }
  }

  struct Parent: Decodable {
    struct Popup: Decodable {
      let drawing: String
      let items: [String]
    }
    let name: String
    let type: String
    let geometry: Row.Geometry
    let label: Row.Label
    let scripting: Row.Scripting
    let bracket: [String]
    let popup: Popup
    func owns(rows: [String]) -> Bool {
      name == SketchyBarAudioPicker.popupOwner && type == "bracket"
        && bracket.sorted() == ["macarchy.volume", "macarchy.volume.icon"]
        && popup.items.sorted() == (rows + ["macarchy.volume.slider"]).sorted()
        && ["on", "off"].contains(popup.drawing)
    }
  }

  func execute(action: String, name: String, pluginPath: String, text: String, muted: String) throws
  {
    guard ["toggle", "close", "select"].contains(action), pluginPath.hasPrefix("/"),
      [text, muted].allSatisfy({
        $0.range(of: #"^0x[0-9a-f]{8}$"#, options: .regularExpression) != nil
      })
    else { throw AudioOutputError.invalidSelection }
    struct Bar: Decodable { let items: [String] }
    let inventory = try JSONDecoder().decode(Bar.self, from: Data(bar(["--query", "bar"]).utf8))
    let rows = inventory.items.filter { $0.hasPrefix(Self.prefix) }
    guard Set(rows).count == rows.count else { throw AudioOutputError.invalidInventory }
    for row in rows {
      let value = try JSONDecoder().decode(Row.self, from: Data(bar(["--query", row]).utf8))
      guard value.valid(name: row, pluginPath: pluginPath) else {
        throw AudioOutputError.invalidInventory
      }
    }
    let parent = try JSONDecoder().decode(
      Parent.self, from: Data(bar(["--query", Self.popupOwner]).utf8))
    guard parent.owns(rows: rows) else { throw AudioOutputError.invalidInventory }
    if action == "select" {
      guard let target = Self.selector(name) else { throw AudioOutputError.invalidSelection }
      try select(target.id, target.identity)
    }
    let opening = action == "toggle" && parent.popup.drawing == "off"
    // Read before mutating the popup so a failed inventory query leaves it intact.
    let outputs = opening ? try read() : nil
    var args = ["--set", Self.popupOwner, "popup.drawing=off"]
    for row in rows { args += ["--remove", row] }
    if let outputs {
      for device in outputs.devices {
        let row = Self.prefix + String(device.id) + "." + device.identity
        guard Self.selector(row) != nil else { throw AudioOutputError.invalidInventory }
        args += [
          "--add", "item", row, "popup." + Self.popupOwner, "--set", row,
          "width=250", "icon.drawing=off", "label.drawing=on", "label.align=center",
          "label=\(device.name)", "label.color=\(device.id == outputs.selected ? text : muted)",
          "script=", "update_freq=0",
          "click_script=\(Self.clickScript(name: row, pluginPath: pluginPath))",
        ]
      }
      args += ["--set", Self.popupOwner, "popup.drawing=on"]
    }
    try bar(args)
  }

  @discardableResult private func bar(_ arguments: [String]) throws -> String {
    let result = try processRunner.run(
      .init(
        executableURL: URL(filePath: "/opt/homebrew/bin/sketchybar"), arguments: arguments,
        timeout: 1))
    guard result.terminationStatus == 0 else { throw AudioOutputError.pickerUpdateFailed }
    return result.output
  }
}

extension Desktop {
  struct AudioPicker: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_audio-picker", shouldDisplay: false)
    @Option var action: String
    @Option var name = "macarchy.volume"
    @Option var pluginPath: String
    @Option var textColor: String
    @Option var mutedColor: String

    mutating func run() throws {
      try SketchyBarAudioPicker(
        processRunner: .live, read: AudioOutputs.read, select: AudioOutputs.select
      )
      .execute(
        action: action, name: name, pluginPath: pluginPath, text: textColor, muted: mutedColor)
    }
  }
}
