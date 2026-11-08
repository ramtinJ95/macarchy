import CoreAudio
import CryptoKit
import Foundation

/// Which side of the HAL a device list, its streams and its default device belong to.
enum AudioDirection: Sendable {
  case input
  case output

  var scope: AudioObjectPropertyScope {
    switch self {
    case .input: kAudioDevicePropertyScopeInput
    case .output: kAudioDevicePropertyScopeOutput
    }
  }

  var defaultDevice: AudioObjectPropertySelector {
    switch self {
    case .input: kAudioHardwarePropertyDefaultInputDevice
    case .output: kAudioHardwarePropertyDefaultOutputDevice
    }
  }
}

struct AudioDevice: Codable, Equatable {
  let id: UInt32
  let name: String
  let identity: String
}

/// The devices with streams in one direction and that direction's default device. The numeric
/// ID is transient; the SHA-256 digest of the device UID identifies a device without exposing it.
struct AudioDevices: Codable, Equatable {
  let devices: [AudioDevice]
  let selected: UInt32

  func device(id: UInt32, identity: String) throws -> AudioDevice {
    guard let device = devices.first(where: { $0.id == id && $0.identity == identity }) else {
      throw AudioDeviceError.invalidSelection
    }
    return device
  }

  /// Rejects duplicate IDs and a default device that is not among the devices.
  static func inventory(_ devices: [AudioDevice], selected: UInt32) throws -> Self {
    guard Set(devices.map(\.id)).count == devices.count,
      selected == kAudioObjectUnknown || devices.contains(where: { $0.id == selected })
    else { throw AudioDeviceError.invalidInventory }
    return Self(devices: devices.sorted { $0.id < $1.id }, selected: selected)
  }

  static func read(_ direction: AudioDirection) throws -> Self {
    var address = property(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
    guard size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
      throw AudioDeviceError.invalidInventory
    }
    let capacity = Int(size) / MemoryLayout<AudioDeviceID>.size
    // CoreAudio requires a non-null output pointer even for an empty inventory.
    var ids = [AudioDeviceID](repeating: 0, count: max(1, capacity))
    let status = ids.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
    }
    try check(status)
    guard size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0,
      Int(size) / MemoryLayout<AudioDeviceID>.size <= capacity
    else { throw AudioDeviceError.invalidInventory }
    var devices: [AudioDevice] = []
    for id in ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size) {
      var streams = property(kAudioDevicePropertyStreams, scope: direction.scope)
      var streamSize: UInt32 = 0
      try check(AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize))
      guard streamSize > 0 else { continue }
      let name = try string(id, selector: kAudioObjectPropertyName)
      let uid = try string(id, selector: kAudioDevicePropertyDeviceUID)
      guard !name.isEmpty, !uid.isEmpty else { throw AudioDeviceError.invalidInventory }
      devices.append(.init(id: id, name: name, identity: digest(uid)))
    }
    var selected: AudioDeviceID = 0
    var selectedSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    address = property(direction.defaultDevice)
    try check(AudioObjectGetPropertyData(system, &address, 0, nil, &selectedSize, &selected))
    return try inventory(devices, selected: selected)
  }

  // Revalidate the UID digest immediately before using the transient CoreAudio ID.
  static func select(_ direction: AudioDirection, id: UInt32, identity: String) throws {
    try select(
      id: id, identity: identity, read: { try read(direction) },
      write: { try setDefault(direction, $0) })
  }

  static func select(
    id: UInt32, identity: String,
    read: () throws -> Self, write: (UInt32) throws -> Void
  ) throws {
    _ = try read().device(id: id, identity: identity)
    try write(id)
    let actual = try read()
    _ = try actual.device(id: id, identity: identity)
    guard actual.selected == id else { throw AudioDeviceError.selectionNotApplied }
  }

  static func setDefault(_ direction: AudioDirection, _ id: UInt32) throws {
    var address = property(direction.defaultDevice)
    var settable: DarwinBoolean = false
    try check(AudioObjectIsPropertySettable(system, &address, &settable))
    guard settable.boolValue else { throw AudioDeviceError.notSettable }
    var target = id
    try check(
      AudioObjectSetPropertyData(
        system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &target))
  }

  static func digest(_ uid: String) -> String {
    SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static let system = AudioObjectID(kAudioObjectSystemObject)

  static func property(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: element)
  }

  private static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws
    -> String
  {
    var address = property(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
    guard let value else { throw AudioDeviceError.invalidInventory }
    return value.takeRetainedValue() as String
  }

  static func check(_ status: OSStatus) throws {
    guard status == noErr else { throw AudioDeviceError.coreAudio(status) }
  }
}

enum AudioDeviceError: Error, Equatable, CustomStringConvertible {
  case coreAudio(OSStatus)
  case invalidInventory
  case invalidSelection
  case notSettable
  case selectionNotApplied
  case pickerUpdateFailed

  var description: String {
    switch self {
    case .coreAudio(let status): "CoreAudio request failed (OSStatus \(status))"
    case .invalidInventory: "CoreAudio returned an inconsistent device list"
    case .invalidSelection: "the device changed or disconnected; list the devices again"
    case .notSettable: "the device does not allow this setting to be changed"
    case .selectionNotApplied: "the new default device was accepted but not applied"
    case .pickerUpdateFailed: "SketchyBar did not update the output picker"
    }
  }
}
