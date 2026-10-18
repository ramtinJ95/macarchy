import Foundation
import Testing

@testable import MacarchyCLI

struct MicrophoneTests {
  private static let builtIn = AudioDevice(
    id: 41, name: "MacBook Pro Microphone", identity: AudioDevices.digest("BuiltInMicrophone"))
  private static let usb = AudioDevice(
    id: 57, name: "USB Mic", identity: AudioDevices.digest("usb-mic-uid"))
  private static let lineIn = AudioDevice(
    id: 63, name: "Line In", identity: AudioDevices.digest("line-in-uid"))
  private static let appsNote = "Apps that choose their own input are not affected."

  @Test(arguments: [
    ("main-mute", MicrophoneMuteControl.hardware([0])),
    ("channel-mute", .hardware([1, 2])),
    ("partial-channel-mute", .inputLevel([1, 2])),
    ("read-only-mute", .inputLevel([0])),
    ("level-channels", .inputLevel([1, 2])),
    ("read-only-level", .unsupported),
    ("neither", .unsupported),
  ])
  func probePrefersTheDeviceMuteThenItsInputLevel(
    kind: String, expected: MicrophoneMuteControl
  ) throws {
    let on = Audio.Control(value: 0, settable: true)
    let readOnly = Audio.Control(value: 0, settable: false)
    let fixtures: [String: [MicrophoneProperty: [UInt32: Audio.Control]]] = [
      "main-mute": [.mute: [0: on], .level: [0: on]],
      "channel-mute": [.mute: [1: on, 2: on], .level: [0: on]],
      "partial-channel-mute": [.mute: [1: on, 2: readOnly], .level: [1: on, 2: on]],
      "read-only-mute": [.mute: [0: readOnly], .level: [0: on]],
      "level-channels": [.level: [1: on, 2: on]],
      "read-only-level": [.level: [0: readOnly]],
      "neither": [:],
    ]
    let audio = Audio(devices: [Self.usb], selected: Self.usb.id)
    audio.channels[Self.usb.id] = 2
    audio.controls[Self.usb.id] = fixtures[kind]!
    #expect(try audio.hardware.control(Self.usb.id) == expected)
  }

  @Test func hardwareMuteIsWrittenReadBackAndCleared() throws {
    let audio = Self.audio(selected: Self.usb)
    try withEngine(audio) { engine, record throws in
      let change = try engine.apply(.mute)
      #expect(change == .changed(Self.usb, from: .live, to: .hardwareMuted))
      #expect(change.message == "Microphone \"USB Mic\" muted (hardware mute). \(Self.appsNote)")
      #expect(audio.writes == [.init(device: Self.usb.id, property: .mute, element: 0, value: 1)])
      #expect(audio.value(Self.usb.id, .level, 0) == 0.6)
      #expect(try record.read() == nil)
      #expect(try engine.status() == .input(Self.usb, .hardwareMuted))
      #expect(try engine.apply(.mute) == .unchanged(Self.usb, .hardwareMuted))

      let unmuted = try engine.apply(.toggle)
      #expect(unmuted == .changed(Self.usb, from: .hardwareMuted, to: .live))
      #expect(unmuted.message == "Microphone \"USB Mic\" is live again (hardware mute off).")
      #expect(audio.value(Self.usb.id, .mute, 0) == 0)
      #expect(try engine.apply(.unmute) == .unchanged(Self.usb, .live))
      #expect(audio.notifications == 2)
    }
  }

  @Test func levelSilenceSavesEveryChannelAndRestoresIt() throws {
    let audio = Self.audio(selected: Self.builtIn)
    try withEngine(audio) { engine, record throws in
      let change = try engine.apply(.toggle)
      #expect(change == .changed(Self.builtIn, from: .live, to: .silencedByLevel))
      #expect(
        change.message
          == "Microphone \"MacBook Pro Microphone\" silenced by input level, not a hardware mute. "
          + Self.appsNote)
      #expect(
        try record.read()
          == MicrophoneSilence(identity: Self.builtIn.identity, levels: [1: 0.7, 2: 0.5]))
      #expect(audio.value(Self.builtIn.id, .level, 1) == 0)
      #expect(audio.value(Self.builtIn.id, .level, 2) == 0)
      #expect(try engine.status() == .input(Self.builtIn, .silencedByLevel))
      #expect(try engine.apply(.mute) == .unchanged(Self.builtIn, .silencedByLevel))

      let restored = try engine.apply(.unmute)
      #expect(restored == .changed(Self.builtIn, from: .silencedByLevel, to: .live))
      #expect(
        restored.message
          == "Microphone \"MacBook Pro Microphone\" is live again (input level restored).")
      #expect(audio.value(Self.builtIn.id, .level, 1) == 0.7)
      #expect(audio.value(Self.builtIn.id, .level, 2) == 0.5)
      #expect(try record.read() == nil)
      #expect(try engine.status() == .input(Self.builtIn, .live))
      #expect(audio.notifications == 2)
    }
  }

  @Test(arguments: ["hardware", "level"])
  func writesThatReturnWithoutApplyingFailAndLeaveTheInputLive(path: String) throws {
    let audio = Self.audio(selected: path == "hardware" ? Self.usb : Self.builtIn)
    audio.ignores = { _ in true }
    try withEngine(audio) { engine, record throws in
      let error = #expect(throws: MicrophoneError.self) { try engine.apply(.mute) }
      #expect(error?.description.contains("accepted but not applied") == true)
      #expect(!audio.writes.isEmpty)
      #expect(try record.read() == nil)
      #expect(try engine.status() == .input(path == "hardware" ? Self.usb : Self.builtIn, .live))
      #expect(audio.notifications == 0)
    }
  }

  @Test(arguments: ["hardware", "level"])
  func refusedSettersFailExplicitly(path: String) throws {
    let audio = Self.audio(selected: path == "hardware" ? Self.usb : Self.builtIn)
    audio.refuses = { _ in true }
    try withEngine(audio) { engine, record throws in
      #expect(throws: AudioDeviceError.notSettable) { try engine.apply(.mute) }
      #expect(audio.writes.isEmpty)
      #expect(try record.read() == nil)
      #expect(audio.value(Self.builtIn.id, .level, 1) == 0.7)
      #expect(audio.notifications == 0)
    }
  }

  @Test func aSilenceThatFailsHalfwayRestoresOnlyTheChannelsItZeroed() throws {
    let audio = Self.audio(selected: Self.builtIn)
    audio.refuses = { $0.element == 2 && $0.value == 0 }
    try withEngine(audio) { engine, record throws in
      #expect(throws: AudioDeviceError.notSettable) { try engine.apply(.mute) }
      #expect(
        audio.writes == [
          .init(device: Self.builtIn.id, property: .level, element: 1, value: 0),
          .init(device: Self.builtIn.id, property: .level, element: 1, value: 0.7),
        ])
      #expect(audio.value(Self.builtIn.id, .level, 2) == 0.5)
      #expect(try record.read() == nil)
      #expect(try engine.status() == .input(Self.builtIn, .live))
    }
  }

  @Test func microphoneWithoutMuteOrLevelControlIsReportedAndNeverWritten() throws {
    let audio = Self.audio(selected: Self.lineIn)
    try withEngine(audio) { engine, record throws in
      #expect(try engine.status() == .input(Self.lineIn, .unsupported))
      #expect(
        try engine.status().message
          == "Microphone \"Line In\" is live; this microphone has no mute or input-level control.")
      for request in [MicrophoneRequest.mute, .toggle] {
        let error = #expect(throws: MicrophoneError.self) { try engine.apply(request) }
        #expect(
          error?.description
            == "Microphone \"Line In\" not muted: this microphone has no mute or input-level control"
        )
      }
      #expect(try engine.apply(.unmute) == .unchanged(Self.lineIn, .unsupported))
      #expect(audio.writes.isEmpty)
      #expect(try record.read() == nil)
      #expect(audio.notifications == 0)
    }
  }

  @Test func raisingASilencedLevelElsewhereMakesTheRecordStaleWithoutRestoring() throws {
    let audio = Self.audio(selected: Self.builtIn)
    try withEngine(audio) { engine, record throws in
      _ = try engine.apply(.mute)
      audio.set(Self.builtIn.id, .level, 2, 0.3)
      let writes = audio.writes.count
      #expect(try engine.status() == .input(Self.builtIn, .live))
      #expect(try record.read() == nil)
      #expect(try engine.apply(.unmute) == .unchanged(Self.builtIn, .live))
      #expect(audio.writes.count == writes)
      #expect(audio.value(Self.builtIn.id, .level, 1) == 0)
      #expect(audio.value(Self.builtIn.id, .level, 2) == 0.3)
    }
  }

  @Test func aSilencedInputThatDisconnectsIsRestoredWhenItReturns() throws {
    let audio = Self.audio(selected: Self.builtIn)
    try withEngine(audio) { engine, record throws in
      _ = try engine.apply(.mute)
      let saved = try record.read()
      let levels = audio.controls[Self.builtIn.id]
      audio.devices.removeAll { $0 == Self.builtIn }
      audio.selected = Self.usb.id
      #expect(try engine.status() == .input(Self.usb, .live))
      #expect(try record.read() == saved)

      let returned = AudioDevice(
        id: 77, name: Self.builtIn.name, identity: Self.builtIn.identity)
      audio.devices.append(returned)
      audio.controls[returned.id] = levels
      audio.selected = returned.id
      #expect(try engine.status() == .input(returned, .silencedByLevel))
      #expect(try engine.apply(.unmute) == .changed(returned, from: .silencedByLevel, to: .live))
      #expect(audio.value(returned.id, .level, 1) == 0.7)
      #expect(audio.value(returned.id, .level, 2) == 0.5)
      #expect(try record.read() == nil)
    }
  }

  @Test(arguments: ["hardware", "level"])
  func mutingANewDefaultRestoresThePreviouslySilencedInputFirst(newDefault: String) throws {
    let audio = Self.audio(selected: Self.builtIn)
    if newDefault == "level" { audio.controls[Self.usb.id]?[.mute]?[0]?.settable = false }
    try withEngine(audio) { engine, record throws in
      _ = try engine.apply(.mute)
      audio.selected = Self.usb.id
      #expect(try engine.status() == .input(Self.usb, .live))
      audio.writes = []

      let level = newDefault == "level"
      let muted: MicrophoneMuteState = level ? .silencedByLevel : .hardwareMuted
      let muting = Audio.Write(
        device: Self.usb.id, property: level ? .level : .mute, element: 0, value: level ? 0 : 1)
      #expect(try engine.apply(.mute) == .changed(Self.usb, from: .live, to: muted))
      #expect(
        audio.writes == [
          .init(device: Self.builtIn.id, property: .level, element: 1, value: 0.7),
          .init(device: Self.builtIn.id, property: .level, element: 2, value: 0.5),
          muting,
        ])
      let replacement = MicrophoneSilence(identity: Self.usb.identity, levels: [0: 0.6])
      #expect(try record.read() == (level ? replacement : nil))
    }
  }

  @Test(arguments: ["truncated", "foreign-identity", "no-levels", "out-of-range"])
  func invalidRecordsAreTreatedAsAbsentAndNeverRestored(kind: String) throws {
    let audio = Self.audio(selected: Self.builtIn)
    audio.set(Self.builtIn.id, .level, 1, 0)
    audio.set(Self.builtIn.id, .level, 2, 0)
    try withEngine(audio) { engine, record throws in
      try FileManager.default.createDirectory(
        at: record.directory, withIntermediateDirectories: true)
      let identity = kind == "foreign-identity" ? "not-a-digest" : Self.builtIn.identity
      let levels: [UInt32: Float32] =
        switch kind {
        case "no-levels": [:]
        case "out-of-range": [1: 2, 2: 0.5]
        default: [1: 0.7, 2: 0.5]
        }
      let data =
        try kind == "truncated"
        ? Data("{\"identity\":".utf8)
        : JSONEncoder().encode(MicrophoneSilence(identity: identity, levels: levels))
      try data.write(to: record.url)

      #expect(try engine.status() == .input(Self.builtIn, .live))
      #expect(try engine.apply(.unmute) == .unchanged(Self.builtIn, .live))
      #expect(audio.writes.isEmpty)
    }
  }

  @Test(arguments: ["name", "identity"])
  func selectMatchesAnExactNameThenAnIdentityAndReadsBack(selector: String) throws {
    let audio = Self.audio(selected: Self.builtIn)
    try withEngine(audio) { engine, _ throws in
      #expect(try engine.select(selector == "name" ? "USB Mic" : Self.usb.identity) == Self.usb)
      #expect(audio.selected == Self.usb.id)
      #expect(audio.notifications == 1)
    }
  }

  @Test(arguments: ["ambiguous", "missing", "partial-name", "not-applied"])
  func selectRejectsAmbiguousMissingAndUnappliedSelections(failure: String) throws {
    let audio = Self.audio(selected: Self.builtIn)
    if failure == "ambiguous" {
      audio.devices.append(
        AudioDevice(id: 90, name: "USB Mic", identity: AudioDevices.digest("second-usb")))
    }
    audio.ignoresSelection = failure == "not-applied"
    try withEngine(audio) { engine, _ throws in
      let query = ["missing": "Webcam", "partial-name": "USB"][failure] ?? "USB Mic"
      if failure == "not-applied" {
        #expect(throws: AudioDeviceError.selectionNotApplied) { try engine.select(query) }
      } else {
        #expect(throws: MicrophoneError.self) { try engine.select(query) }
      }
      #expect(audio.selected == Self.builtIn.id)
      #expect(audio.notifications == 0)
    }
  }

  @Test func chooserOffersEveryInputWithTheDefaultPreselected() throws {
    let audio = Self.audio(selected: Self.usb)
    try withEngine(audio) { engine, _ throws in
      var offered: [String] = []
      var preselected: Int?
      let cancelled = try engine.choose { names, selected in
        offered = names
        preselected = selected
        return nil
      }
      #expect(cancelled == nil)
      #expect(offered == ["MacBook Pro Microphone", "USB Mic", "Line In"])
      #expect(preselected == 1)
      #expect(audio.selected == Self.usb.id)
      #expect(audio.notifications == 0)

      let chosen = try engine.choose { _, _ in 0 }
      #expect(chosen == Self.builtIn)
      #expect(audio.selected == Self.builtIn.id)
      #expect(audio.notifications == 1)
    }
  }

  @Test(arguments: ["replaced", "empty"])
  func chooserRejectsAStaleOrEmptyInventory(condition: String) throws {
    let audio = Self.audio(selected: Self.usb)
    if condition == "empty" {
      audio.devices = []
      audio.selected = 0
    }
    try withEngine(audio) { engine, _ throws in
      if condition == "empty" {
        #expect(throws: MicrophoneError.self) { try engine.choose { _, _ in 0 } }
      } else {
        #expect(throws: AudioDeviceError.invalidSelection) {
          try engine.choose { _, _ in
            audio.devices[0] = AudioDevice(
              id: Self.builtIn.id, name: Self.builtIn.name,
              identity: AudioDevices.digest("replacement"))
            return 0
          }
        }
      }
      #expect(audio.selected == (condition == "empty" ? 0 : Self.usb.id))
      #expect(audio.notifications == 0)
    }
  }

  @Test func listShowsTheDefaultAndMuteKindWithoutExposingUIDs() throws {
    let audio = Self.audio(selected: Self.usb)
    try withEngine(audio) { engine, _ throws in
      let inputs = try engine.inputs()
      #expect(
        MicrophoneInput.render(inputs) == """
            MacBook Pro Microphone (mutes by input level, not a hardware mute)
          * USB Mic (hardware mute)
            Line In (no mute or input-level control)
          """)
      let json = try MicrophoneInput.renderJSON(inputs)
      #expect(!json.contains("usb-mic-uid"))
      let document = try #require(
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [[String: Any]]])
      let rows = try #require(document["inputs"])
      #expect(rows.map { $0["mute"] as? String } == ["input-level", "hardware", "unsupported"])
      #expect(rows.map { $0["default"] as? Bool } == [false, true, false])
      #expect(rows[1]["identity"] as? String == Self.usb.identity)
    }
    #expect(MicrophoneInput.render([]) == "No microphones are available.")
  }

  @Test func statusRendersOneLineAndStableJSON() throws {
    #expect(MicrophoneStatus.noInput.message == "There is no default microphone.")
    #expect(
      MicrophoneStatus.input(Self.usb, .hardwareMuted).message
        == "Microphone \"USB Mic\" is muted (hardware mute).")
    #expect(
      MicrophoneStatus.input(Self.usb, .silencedByLevel).message
        == "Microphone \"USB Mic\" is silenced by input level, not a hardware mute.")
    #expect(MicrophoneStatus.input(Self.usb, .live).message == "Microphone \"USB Mic\" is live.")
    #expect(
      try MicrophoneStatus.noInput.renderJSON()
        == #"{"identity":null,"name":null,"state":"no-input"}"#)
    #expect(
      try MicrophoneStatus.input(Self.usb, .silencedByLevel).renderJSON()
        == #"{"identity":"\#(Self.usb.identity)","name":"USB Mic","state":"silenced-by-level"}"#)
  }

  @Test func withoutADefaultInputStatusSaysSoAndMuteChangesNothing() throws {
    let audio = Self.audio(selected: Self.usb)
    audio.selected = 0
    try withEngine(audio) { engine, _ throws in
      #expect(try engine.status() == .noInput)
      #expect(throws: MicrophoneError.self) { try engine.apply(.mute) }
      #expect(audio.writes.isEmpty)
    }
  }

  @Test func commandLineParsesSelectorsJSONAndTheMenuAlertFlag() throws {
    #expect(try MicrophoneCommand.Select.parse(["USB Mic"]).input == "USB Mic")
    #expect(throws: (any Error).self) { try MicrophoneCommand.Select.parse([]) }
    #expect(try MicrophoneCommand.Toggle.parse(["--alert-on-error"]).options.alertOnError)
    #expect(try MicrophoneCommand.Choose.parse(["--alert-on-error"]).options.alertOnError)
    #expect(try !MicrophoneCommand.Mute.parse([]).options.alertOnError)
    #expect(try MicrophoneCommand.Status.parse(["--json"]).json)
    #expect(try MicrophoneCommand.List.parse(["--json"]).json)
  }

  /// The built-in microphone has a stereo input level and no mute, the USB microphone its own
  /// mute and an input level, and the line input only a fixed level.
  private static func audio(selected: AudioDevice) -> Audio {
    let audio = Audio(devices: [builtIn, usb, lineIn], selected: selected.id)
    audio.channels = [builtIn.id: 2, usb.id: 1, lineIn.id: 1]
    audio.controls = [
      builtIn.id: [
        .level: [1: .init(value: 0.7, settable: true), 2: .init(value: 0.5, settable: true)]
      ],
      usb.id: [
        .mute: [0: .init(value: 0, settable: true)], .level: [0: .init(value: 0.6, settable: true)],
      ],
      lineIn.id: [.level: [0: .init(value: 1, settable: false)]],
    ]
    return audio
  }

  /// The inputs and per-element controls the engine can observe or change.
  private final class Audio {
    struct Control {
      var value: Float32
      var settable: Bool
    }

    struct Write: Equatable {
      let device: UInt32
      let property: MicrophoneProperty
      let element: UInt32
      let value: Float32
    }

    var devices: [AudioDevice]
    var selected: UInt32
    var channels: [UInt32: UInt32] = [:]
    var controls: [UInt32: [MicrophoneProperty: [UInt32: Control]]] = [:]
    var writes: [Write] = []
    /// Throws notSettable before the write.
    var refuses: (Write) -> Bool = { _ in false }
    /// Returns as if written but leaves the value unchanged.
    var ignores: (Write) -> Bool = { _ in false }
    var ignoresSelection = false
    var notifications = 0

    init(devices: [AudioDevice], selected: UInt32) {
      self.devices = devices
      self.selected = selected
    }

    func value(_ id: UInt32, _ property: MicrophoneProperty, _ element: UInt32) -> Float32? {
      controls[id]?[property]?[element]?.value
    }

    func set(_ id: UInt32, _ property: MicrophoneProperty, _ element: UInt32, _ value: Float32) {
      controls[id]?[property]?[element]?.value = value
    }

    var hardware: MicrophoneHardware {
      MicrophoneHardware(
        inputs: { try AudioDevices.inventory(self.devices, selected: self.selected) },
        setDefault: { id in
          if !self.ignoresSelection { self.selected = id }
        },
        channels: { self.channels[$0] ?? 0 },
        settable: { id, property, element in self.controls[id]?[property]?[element]?.settable },
        value: { id, property, element in
          guard let value = self.value(id, property, element) else {
            throw AudioDeviceError.coreAudio(-1)
          }
          return value
        },
        setValue: { id, property, element, value in
          let write = Write(device: id, property: property, element: element, value: value)
          if self.refuses(write) { throw AudioDeviceError.notSettable }
          self.writes.append(write)
          if !self.ignores(write) { self.set(id, property, element, value) }
        })
    }
  }

  private func withEngine(
    _ audio: Audio, _ body: (Microphone, RunStateRecord<MicrophoneSilence>) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-microphone-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = Microphone(
      stateRoot: root, hardware: audio.hardware, notifyBar: { audio.notifications += 1 })
    try body(engine, Microphone.silenceRecord(stateRoot: root))
  }
}
