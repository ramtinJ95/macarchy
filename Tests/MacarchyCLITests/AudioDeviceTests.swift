import Foundation
import Testing

@testable import MacarchyCLI

struct AudioDeviceTests {
  @Test func selectionWritesOnlyAfterIdentityValidationAndVerifiesReadback() throws {
    let device = AudioDevice(id: 7, name: "Speaker", identity: AudioDevices.digest("original"))
    var state = AudioDevices(devices: [device], selected: 0)
    var writes: [UInt32] = []
    var reads = 0
    try AudioDevices.select(
      id: 7, identity: device.identity,
      read: {
        reads += 1
        return state
      },
      write: {
        writes.append($0)
        state = AudioDevices(devices: [device], selected: $0)
      })
    #expect(writes == [7])
    #expect(reads == 2)
    writes = []
    #expect(throws: AudioDeviceError.invalidSelection) {
      try AudioDevices.select(
        id: 7, identity: AudioDevices.digest("stale"), read: { state },
        write: { writes.append($0) })
    }
    #expect(writes.isEmpty)
  }

  @Test func selectionPreservesWriteAndReadFailures() {
    let device = AudioDevice(id: 7, name: "Speaker", identity: AudioDevices.digest("original"))
    let state = AudioDevices(devices: [device], selected: 0)
    for failure in [AudioDeviceError.notSettable, .coreAudio(-1)] {
      var reads = 0
      #expect(throws: failure) {
        try AudioDevices.select(
          id: 7, identity: device.identity,
          read: {
            reads += 1
            return state
          },
          write: { _ in throw failure })
      }
      #expect(reads == 1)
    }
    var written = false
    #expect(throws: AudioDeviceError.coreAudio(-2)) {
      try AudioDevices.select(
        id: 7, identity: device.identity,
        read: {
          if written { throw AudioDeviceError.coreAudio(-2) }
          return state
        }, write: { _ in written = true })
    }
    #expect(written)
  }

  @Test func selectionRejectsIgnoredWriteAndHotplugDuringWrite() {
    let device = AudioDevice(id: 7, name: "Speaker", identity: AudioDevices.digest("original"))
    for actual in [
      AudioDevices(devices: [device], selected: 0),
      AudioDevices(devices: [], selected: 0),
      AudioDevices(
        devices: [.init(id: 7, name: "Other", identity: AudioDevices.digest("new"))], selected: 7),
    ] {
      var written = false
      let expected: AudioDeviceError =
        actual.devices == [device] ? .selectionNotApplied : .invalidSelection
      #expect(throws: expected) {
        try AudioDevices.select(
          id: 7, identity: device.identity,
          read: { written ? actual : AudioDevices(devices: [device], selected: 0) },
          write: { _ in written = true })
      }
      #expect(written)
    }
  }

  @Test func selectionRejectsDisconnectedOrReusedIDs() throws {
    let original = AudioDevice(id: 7, name: "Speaker", identity: AudioDevices.digest("original"))
    let replacement = AudioDevice(
      id: 7, name: "Speaker", identity: AudioDevices.digest("replacement"))
    let state = AudioDevices(devices: [replacement], selected: 7)
    #expect(throws: AudioDeviceError.self) {
      try state.device(id: original.id, identity: original.identity)
    }
    #expect(throws: AudioDeviceError.self) {
      try state.device(id: 8, identity: replacement.identity)
    }
    #expect(try state.device(id: 7, identity: replacement.identity) == replacement)
  }

  @Test func inventoryRejectsDuplicateIDsAndADefaultOutsideTheList() throws {
    let microphone = AudioDevice(id: 9, name: "Mic", identity: AudioDevices.digest("mic"))
    let headset = AudioDevice(id: 4, name: "Headset", identity: AudioDevices.digest("headset"))
    #expect(
      try AudioDevices.inventory([microphone, headset], selected: 9)
        == AudioDevices(devices: [headset, microphone], selected: 9))
    #expect(try AudioDevices.inventory([], selected: 0) == AudioDevices(devices: [], selected: 0))
    #expect(try AudioDevices.inventory([headset], selected: 0).selected == 0)
    let clone = AudioDevice(id: 4, name: "Headset", identity: AudioDevices.digest("clone"))
    let invalid: [([AudioDevice], UInt32)] = [([headset, clone], 4), ([], 4), ([headset], 9)]
    for (devices, selected) in invalid {
      #expect(throws: AudioDeviceError.invalidInventory) {
        try AudioDevices.inventory(devices, selected: selected)
      }
    }
  }

  @Test func namesAreJSONDataAndIdentityDoesNotExposeUID() throws {
    let uid = "private-hardware-uid"
    let name = "Speaker '\" $(touch /tmp/unwanted)\n --remove all"
    let device = AudioDevice(id: 7, name: name, identity: AudioDevices.digest(uid))
    let data = try JSONEncoder().encode(AudioDevices(devices: [device], selected: 7))
    #expect(try JSONDecoder().decode(AudioDevices.self, from: data).devices == [device])
    #expect(!String(decoding: data, as: UTF8.self).contains(uid))
    #expect(device.identity.count == 64)
  }

  @Test func commandRequiresCompleteValidatedSelector() throws {
    _ = try Desktop.AudioOutputCommand.parse([])
    _ = try Desktop.AudioOutputCommand.parse([
      "--id", "7", "--identity", String(repeating: "a", count: 64),
    ])
    for args in [
      ["--id", "7"], ["--identity", "x"], ["--id", "7", "--identity", "$(bad)"],
      ["--id", "-1", "--identity", String(repeating: "a", count: 64)],
    ] {
      #expect(throws: (any Error).self) { try Desktop.AudioOutputCommand.parse(args) }
    }
  }
}
