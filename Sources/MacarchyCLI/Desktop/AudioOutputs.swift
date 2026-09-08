import CoreAudio
import CryptoKit
import Foundation

struct AudioOutput: Codable, Equatable {
  let id: UInt32
  let name: String
  let identity: String
}

struct AudioOutputs: Codable, Equatable {
  let devices: [AudioOutput]
  let selected: UInt32

  func device(id: UInt32, identity: String) throws -> AudioOutput {
    guard let device = devices.first(where: { $0.id == id && $0.identity == identity }) else {
      throw AudioOutputError.invalidSelection
    }
    return device
  }

  static func read() throws -> Self {
    var address = property(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
    guard size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
      throw AudioOutputError.invalidInventory
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
    else { throw AudioOutputError.invalidInventory }
    var devices: [AudioOutput] = []
    for id in ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size) {
      var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
      var streamSize: UInt32 = 0
      try check(AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize))
      guard streamSize > 0 else { continue }
      let name = try string(id, selector: kAudioObjectPropertyName)
      let uid = try string(id, selector: kAudioDevicePropertyDeviceUID)
      guard !name.isEmpty, !uid.isEmpty else { throw AudioOutputError.invalidInventory }
      devices.append(.init(id: id, name: name, identity: digest(uid)))
    }
    var selected: AudioDeviceID = 0
    var selectedSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    address = property(kAudioHardwarePropertyDefaultOutputDevice)
    try check(AudioObjectGetPropertyData(system, &address, 0, nil, &selectedSize, &selected))
    guard Set(devices.map(\.id)).count == devices.count,
      selected == kAudioObjectUnknown || devices.contains(where: { $0.id == selected })
    else { throw AudioOutputError.invalidInventory }
    return Self(devices: devices.sorted { $0.id < $1.id }, selected: selected)
  }

  // Revalidate the UID digest immediately before using the transient CoreAudio ID.
  static func select(id: UInt32, identity: String) throws {
    try select(id: id, identity: identity, read: read, write: setDefault)
  }

  static func select(
    id: UInt32, identity: String,
    read: () throws -> Self, write: (UInt32) throws -> Void
  ) throws {
    _ = try read().device(id: id, identity: identity)
    try write(id)
    let actual = try read()
    _ = try actual.device(id: id, identity: identity)
    guard actual.selected == id else { throw AudioOutputError.selectionNotApplied }
  }

  private static func setDefault(_ id: UInt32) throws {
    var address = property(kAudioHardwarePropertyDefaultOutputDevice)
    var settable: DarwinBoolean = false
    try check(AudioObjectIsPropertySettable(system, &address, &settable))
    guard settable.boolValue else { throw AudioOutputError.notSettable }
    var target = id
    try check(
      AudioObjectSetPropertyData(
        system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &target))
  }

  static func digest(_ uid: String) -> String {
    SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static let system = AudioObjectID(kAudioObjectSystemObject)

  private static func property(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws
    -> String
  {
    var address = property(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
    guard let value else { throw AudioOutputError.invalidInventory }
    return value.takeRetainedValue() as String
  }

  private static func check(_ status: OSStatus) throws {
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
  }
}

enum AudioOutputError: Error, Equatable {
  case coreAudio(OSStatus)
  case invalidInventory
  case invalidSelection
  case notSettable
  case selectionNotApplied
  case pickerUpdateFailed
}
