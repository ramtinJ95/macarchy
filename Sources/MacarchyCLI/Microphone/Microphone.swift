import Foundation
import ThemeCore

/// Macarchy's record of an input it silenced by level, so unmute can restore it.
struct MicrophoneSilence: Codable, Equatable {
  let identity: String
  /// The volume scalar each element had before it was set to zero.
  let levels: [UInt32: Float32]
}

enum MicrophoneMuteState: Equatable {
  case live
  case hardwareMuted
  case silencedByLevel
  case unsupported
}

/// Derived from the hardware and the silence record on every read; never stored.
enum MicrophoneStatus: Equatable {
  case noInput
  case input(AudioDevice, MicrophoneMuteState)
}

enum MicrophoneRequest: Equatable {
  case mute
  case unmute
  case toggle
}

enum MicrophoneChange: Equatable {
  case changed(AudioDevice, from: MicrophoneMuteState, to: MicrophoneMuteState)
  case unchanged(AudioDevice, MicrophoneMuteState)
}

struct MicrophoneInput: Equatable {
  let device: AudioDevice
  let isDefault: Bool
  let control: MicrophoneMuteControl
}

struct MicrophoneError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Selects the default input and mutes it with the device's own mute, otherwise by setting its
/// input level to zero. The silence record is the only state Macarchy owns, and it holds only
/// while its device is present with every recorded element still at zero.
struct Microphone {
  static let barEvent = SketchyBarConfigurationComposer.microphoneEvent
  static let appsNote = "Apps that choose their own input are not affected."
  private static let lock = ProcessScopedFileLock<MicrophoneError>(
    filename: "microphone.lock",
    cannotCreateRunDirectory: { url, error in
      MicrophoneError("cannot create \(url.path): \(error)")
    },
    operationError: { operation, code in
      MicrophoneError("cannot \(operation) the microphone lock (errno \(code))")
    })

  let stateRoot: URL
  let hardware: MicrophoneHardware
  let notifyBar: () -> Void

  /// `<state root>/run/microphone-silence.json`.
  static func silenceRecord(stateRoot: URL) -> RunStateRecord<MicrophoneSilence> {
    RunStateRecord("microphone-silence.json", stateRoot: stateRoot) { silence in
      silence.identity.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        && !silence.levels.isEmpty && silence.levels.values.allSatisfy { (0...1).contains($0) }
    }
  }

  private var record: RunStateRecord<MicrophoneSilence> {
    Self.silenceRecord(stateRoot: stateRoot)
  }

  func inputs() throws -> [MicrophoneInput] {
    let inputs = try hardware.inputs()
    return try inputs.devices.map { device in
      MicrophoneInput(
        device: device, isDefault: device.id == inputs.selected,
        control: try hardware.control(device.id))
    }
  }

  func status() throws -> MicrophoneStatus {
    try Self.lock.withLock(root: stateRoot) { () throws -> MicrophoneStatus in
      let inputs = try hardware.inputs()
      guard let device = Self.defaultInput(inputs) else { return .noInput }
      return .input(device, try observe(device, silenced: try silence(in: inputs)).state)
    }
  }

  func apply(_ request: MicrophoneRequest) throws -> MicrophoneChange {
    let change = try Self.lock.withLock(root: stateRoot) { () throws -> MicrophoneChange in
      let inputs = try hardware.inputs()
      guard let device = Self.defaultInput(inputs) else {
        throw MicrophoneError("there is no default microphone; nothing changed")
      }
      let silenced = try silence(in: inputs)
      let observed = try observe(device, silenced: silenced)
      switch (request, observed) {
      case (.mute, .hardwareMuted(_, _, completely: true)),
        (.mute, .silencedByLevel(_, _, completely: true)), (.unmute, .live):
        return .unchanged(device, observed.state)
      case (.mute, _), (.toggle, .live):
        let muted = try mute(device, observed.control, replacing: silenced)
        return .changed(device, from: observed.state, to: muted)
      case (_, .hardwareMuted(_, let muted, _)):
        try write(device, .mute, Dictionary(uniqueKeysWithValues: muted.map { ($0, Float32(0)) }))
        return .changed(device, from: .hardwareMuted, to: .live)
      case (_, .silencedByLevel(_, let silence, _)):
        try restore(silence, on: device)
        return .changed(device, from: .silencedByLevel, to: .live)
      }
    }
    if case .changed = change { notifyBar() }
    return change
  }

  /// An exact name first, then an identity digest. A name several inputs share is ambiguous.
  func select(_ query: String) throws -> AudioDevice {
    let inputs = try hardware.inputs()
    let named = inputs.devices.filter { $0.name == query }
    guard named.count <= 1 else {
      throw MicrophoneError(
        "\(named.count) microphones are named \"\(query)\"; select one by the identity that "
          + "`macarchy mic list --json` shows")
    }
    guard let device = named.first ?? inputs.devices.first(where: { $0.identity == query }) else {
      throw MicrophoneError(
        "no microphone is named \"\(query)\" or has that identity; see `macarchy mic list`")
    }
    try select(device)
    return device
  }

  /// `pick` gets the input names and the default's index and returns the chosen index, or nil
  /// to cancel without changing anything.
  func choose(_ pick: (_ names: [String], _ selected: Int?) -> Int?) throws -> AudioDevice? {
    let inputs = try hardware.inputs()
    guard !inputs.devices.isEmpty else { throw MicrophoneError("no microphones are available") }
    let current = inputs.devices.firstIndex { $0.id == inputs.selected }
    guard let index = pick(inputs.devices.map(\.name), current) else { return nil }
    guard inputs.devices.indices.contains(index) else { throw AudioDeviceError.invalidSelection }
    try select(inputs.devices[index])
    return inputs.devices[index]
  }

  private func select(_ device: AudioDevice) throws {
    try AudioDevices.select(
      id: device.id, identity: device.identity, read: hardware.inputs, write: hardware.setDefault)
    notifyBar()
  }

  private static func defaultInput(_ inputs: AudioDevices) -> AudioDevice? {
    inputs.devices.first { $0.id == inputs.selected }
  }

  /// The default input's mute and what undoing it needs. A mute that covers only some elements
  /// reads as live, because the rest still records, yet unmute clears what remains of it.
  private enum Observed {
    case live(MicrophoneMuteControl)
    case hardwareMuted(MicrophoneMuteControl, muted: [UInt32], completely: Bool)
    case silencedByLevel(MicrophoneMuteControl, MicrophoneSilence, completely: Bool)

    var control: MicrophoneMuteControl {
      switch self {
      case .live(let control), .hardwareMuted(let control, _, _),
        .silencedByLevel(let control, _, _):
        control
      }
    }

    var state: MicrophoneMuteState {
      switch self {
      case .hardwareMuted(_, _, completely: true): .hardwareMuted
      case .silencedByLevel(_, _, completely: true): .silencedByLevel
      default: control == .unsupported ? .unsupported : .live
      }
    }
  }

  private typealias Silenced = (device: AudioDevice, silence: MicrophoneSilence)

  private func observe(_ device: AudioDevice, silenced: Silenced?) throws -> Observed {
    let control = try hardware.control(device.id)
    if let silenced, silenced.device == device {
      // Only the live input-level control can prove every element is at zero; without it the
      // silence may be partial, so it must not be reported as complete.
      var completely = false
      if case .inputLevel(let elements) = control {
        completely = try elements.allSatisfy { try hardware.value(device.id, .level, $0) == 0 }
      }
      return .silencedByLevel(control, silenced.silence, completely: completely)
    }
    guard case .hardware(let elements) = control else { return .live(control) }
    let muted = try elements.filter { try hardware.value(device.id, .mute, $0) != 0 }
    if muted.isEmpty { return .live(control) }
    return .hardwareMuted(control, muted: muted, completely: muted.count == elements.count)
  }

  /// Macarchy's level silence while it still holds. A record whose device is absent waits for its
  /// return; once the user raises a recorded level it is stale and removed without restoring.
  private func silence(in inputs: AudioDevices) throws -> Silenced? {
    guard let silence = try record.read(),
      let device = inputs.devices.first(where: { $0.identity == silence.identity })
    else { return nil }
    for element in silence.levels.keys {
      guard try hardware.settable(device.id, .level, element) != nil,
        try hardware.value(device.id, .level, element) == 0
      else {
        try record.remove()
        return nil
      }
    }
    return (device, silence)
  }

  /// Another input Macarchy silenced is restored first, so at most one record exists. The record
  /// is written before any level changes, so a crash leaves it stale rather than losing a level.
  private func mute(
    _ device: AudioDevice, _ control: MicrophoneMuteControl, replacing silenced: Silenced?
  ) throws -> MicrophoneMuteState {
    switch control {
    case .unsupported:
      throw MicrophoneError(
        "\(device.subject) not muted: this microphone has no mute or input-level control")
    case .hardware(let elements):
      if let silenced { try restore(silenced.silence, on: silenced.device) }
      try write(device, .mute, Dictionary(uniqueKeysWithValues: elements.map { ($0, Float32(1)) }))
      return .hardwareMuted
    case .inputLevel(let elements):
      if let silenced { try restore(silenced.silence, on: silenced.device) }
      let levels = try elements.map { ($0, try hardware.value(device.id, .level, $0)) }
      let silence = MicrophoneSilence(
        identity: device.identity, levels: Dictionary(uniqueKeysWithValues: levels))
      try record.write(silence)
      do {
        try write(device, .level, silence.levels.mapValues { _ in Float32(0) })
      } catch {
        throw rollBack(silence, on: device, after: error)
      }
      return .silencedByLevel
    }
  }

  /// A silence that did not complete must not strand the saved levels.
  private func rollBack(
    _ silence: MicrophoneSilence, on device: AudioDevice, after error: any Error
  ) -> any Error {
    do {
      try restore(silence, on: device)
      return error
    } catch let cleanup {
      return MicrophoneError("\(error); restoring the input level also failed: \(cleanup)")
    }
  }

  /// Saved levels return only to elements still at zero, so a level the user set elsewhere wins.
  private func restore(_ silence: MicrophoneSilence, on device: AudioDevice) throws {
    var targets: [UInt32: Float32] = [:]
    for (element, level) in silence.levels where level > 0 {
      if try hardware.value(device.id, .level, element) == 0 { targets[element] = level }
    }
    do {
      try write(device, .level, targets)
    } catch {
      throw keepPending(targets, on: device, after: error)
    }
    try record.remove()
  }

  /// After a partial restore the record keeps only the elements still at zero, so a level that
  /// did return is not mistaken for the user's change and a later unmute can finish.
  private func keepPending(
    _ targets: [UInt32: Float32], on device: AudioDevice, after error: any Error
  ) -> any Error {
    do {
      let pending = try targets.filter { try hardware.value(device.id, .level, $0.key) == 0 }
      if pending.isEmpty {
        try record.remove()
      } else {
        try record.write(MicrophoneSilence(identity: device.identity, levels: pending))
      }
      return error
    } catch let cleanup {
      return MicrophoneError(
        "\(error); recording the levels still to restore also failed: \(cleanup)")
    }
  }

  /// Every write is read back: a setter that returns noErr without taking effect fails, as in
  /// default-device selection. Hardware may snap a restored level to its own steps, so a
  /// nonzero target only has to leave zero.
  private func write(
    _ device: AudioDevice, _ property: MicrophoneProperty, _ targets: [UInt32: Float32]
  ) throws {
    let ordered = targets.sorted { $0.key < $1.key }
    for (element, target) in ordered {
      try hardware.setValue(device.id, property, element, target)
    }
    for (element, target) in ordered {
      let actual = try hardware.value(device.id, property, element)
      guard target == 0 ? actual == 0 : actual > 0 else {
        throw MicrophoneError(
          "\(device.subject): the \(property.noun) change was accepted but not applied")
      }
    }
  }
}

extension Microphone {
  static func live(stateRoot: URL) -> Self {
    Self(
      stateRoot: stateRoot, hardware: .live,
      notifyBar: { ClockCompanion.hintRunningBar(event: barEvent) })
  }
}

extension AudioDevice {
  /// `Microphone "<name>"`, the subject of every microphone message.
  var subject: String { "Microphone \"\(name)\"" }
}

extension MicrophoneMuteState {
  /// Completes `Microphone "<name>" is …`.
  var phrase: String {
    switch self {
    case .live: "live"
    case .hardwareMuted: "muted (hardware mute)"
    case .silencedByLevel: "silenced by input level, not a hardware mute"
    case .unsupported: "live; this microphone has no mute or input-level control"
    }
  }

  var key: String {
    switch self {
    case .live: "live"
    case .hardwareMuted: "hardware-muted"
    case .silencedByLevel: "silenced-by-level"
    case .unsupported: "unsupported"
    }
  }
}

extension MicrophoneChange {
  var message: String {
    switch self {
    case .changed(let device, let from, .live):
      let undone = from == .hardwareMuted ? "hardware mute off" : "input level restored"
      return "\(device.subject) is live again (\(undone))."
    case .changed(let device, _, let muted):
      return "\(device.subject) \(muted.phrase). \(Microphone.appsNote)"
    case .unchanged(let device, let state):
      return "\(device.subject) is already \(state.phrase)."
    }
  }
}

extension MicrophoneStatus {
  var message: String {
    switch self {
    case .noInput: "There is no default microphone."
    case .input(let device, let state): "\(device.subject) is \(state.phrase)."
    }
  }

  func renderJSON() throws -> String {
    var document: [String: Any] = ["state": "no-input", "name": NSNull(), "identity": NSNull()]
    if case .input(let device, let state) = self {
      document = ["state": state.key, "name": device.name, "identity": device.identity]
    }
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}

extension MicrophoneMuteControl {
  var summary: String {
    switch self {
    case .hardware: "hardware mute"
    case .inputLevel: "mutes by input level, not a hardware mute"
    case .unsupported: "no mute or input-level control"
    }
  }

  var key: String {
    switch self {
    case .hardware: "hardware"
    case .inputLevel: "input-level"
    case .unsupported: "unsupported"
    }
  }
}

extension MicrophoneInput {
  /// One line per input; `*` marks the default.
  static func render(_ inputs: [Self]) -> String {
    guard !inputs.isEmpty else { return "No microphones are available." }
    return inputs.map { "\($0.isDefault ? "*" : " ") \($0.device.name) (\($0.control.summary))" }
      .joined(separator: "\n")
  }

  /// Identities are UID digests, never UIDs.
  static func renderJSON(_ inputs: [Self]) throws -> String {
    let document: [String: Any] = [
      "inputs": inputs.map { input -> [String: Any] in
        [
          "name": input.device.name, "identity": input.device.identity,
          "default": input.isDefault, "mute": input.control.key,
        ]
      }
    ]
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
