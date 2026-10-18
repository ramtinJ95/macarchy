import CoreAudio
import Foundation

/// The two input-scope controls Macarchy can use to mute a microphone.
enum MicrophoneProperty: Sendable {
  case mute
  case level

  var selector: AudioObjectPropertySelector {
    switch self {
    case .mute: kAudioDevicePropertyMute
    case .level: kAudioDevicePropertyVolumeScalar
    }
  }

  var noun: String {
    switch self {
    case .mute: "hardware mute"
    case .level: "input level"
    }
  }
}

/// How a microphone can be muted, probed live, with the elements Macarchy writes.
enum MicrophoneMuteControl: Equatable {
  case hardware([UInt32])
  case inputLevel([UInt32])
  case unsupported
}

/// The public CoreAudio surface microphone controls use. Mute values are 0 or 1; levels are
/// volume scalars from 0 to 1.
struct MicrophoneHardware {
  let inputs: () throws -> AudioDevices
  let setDefault: (UInt32) throws -> Void
  let channels: (UInt32) throws -> UInt32
  /// nil when the element has no such property.
  let settable: (UInt32, MicrophoneProperty, UInt32) throws -> Bool?
  let value: (UInt32, MicrophoneProperty, UInt32) throws -> Float32
  let setValue: (UInt32, MicrophoneProperty, UInt32, Float32) throws -> Void

  /// The device's own mute when settable, otherwise its input level, otherwise neither.
  func control(_ id: UInt32) throws -> MicrophoneMuteControl {
    let mute = try elements(id, .mute)
    if !mute.isEmpty { return .hardware(mute) }
    let level = try elements(id, .level)
    return level.isEmpty ? .unsupported : .inputLevel(level)
  }

  /// The main element when it is settable, otherwise every channel element when each one is.
  private func elements(_ id: UInt32, _ property: MicrophoneProperty) throws -> [UInt32] {
    if try settable(id, property, kAudioObjectPropertyElementMain) == true {
      return [kAudioObjectPropertyElementMain]
    }
    let count = try channels(id)
    guard count > 0 else { return [] }
    let channelElements = Array(1...count)
    guard try channelElements.allSatisfy({ try settable(id, property, $0) == true }) else {
      return []
    }
    return channelElements
  }
}

extension MicrophoneHardware {
  static var live: Self {
    Self(
      inputs: { try AudioDevices.read(.input) },
      setDefault: { try AudioDevices.setDefault(.input, $0) },
      channels: { id in
        var address = AudioDevices.property(
          kAudioDevicePropertyStreamConfiguration, scope: AudioDirection.input.scope)
        var size: UInt32 = 0
        try AudioDevices.check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size))
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
          byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try AudioDevices.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage))
        let buffers = UnsafeMutableAudioBufferListPointer(
          storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
      },
      settable: { id, property, element in
        var address = Self.address(property, element)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var settable: DarwinBoolean = false
        try AudioDevices.check(AudioObjectIsPropertySettable(id, &address, &settable))
        return settable.boolValue
      },
      value: { id, property, element in
        var address = Self.address(property, element)
        // Mute is a UInt32 and the volume scalar a Float32; both are 32 bits wide.
        var bits: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try AudioDevices.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &bits))
        return property == .mute ? (bits == 0 ? 0 : 1) : Float32(bitPattern: bits)
      },
      setValue: { id, property, element, value in
        var address = Self.address(property, element)
        var settable: DarwinBoolean = false
        try AudioDevices.check(AudioObjectIsPropertySettable(id, &address, &settable))
        guard settable.boolValue else { throw AudioDeviceError.notSettable }
        var bits: UInt32 = property == .mute ? (value == 0 ? 0 : 1) : value.bitPattern
        try AudioDevices.check(
          AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bits))
      })
  }

  private static func address(_ property: MicrophoneProperty, _ element: UInt32)
    -> AudioObjectPropertyAddress
  {
    AudioDevices.property(property.selector, scope: AudioDirection.input.scope, element: element)
  }
}
