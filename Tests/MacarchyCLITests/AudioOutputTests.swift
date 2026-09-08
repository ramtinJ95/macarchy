import Foundation
import Testing

@testable import MacarchyCLI

struct AudioOutputTests {
  @Test func selectionWritesOnlyAfterIdentityValidationAndVerifiesReadback() throws {
    let device = AudioOutput(id: 7, name: "Speaker", identity: AudioOutputs.digest("original"))
    var state = AudioOutputs(devices: [device], selected: 0)
    var writes: [UInt32] = []
    var reads = 0
    try AudioOutputs.select(
      id: 7, identity: device.identity,
      read: {
        reads += 1
        return state
      },
      write: {
        writes.append($0)
        state = AudioOutputs(devices: [device], selected: $0)
      })
    #expect(writes == [7])
    #expect(reads == 2)
    writes = []
    #expect(throws: AudioOutputError.invalidSelection) {
      try AudioOutputs.select(
        id: 7, identity: AudioOutputs.digest("stale"), read: { state },
        write: { writes.append($0) })
    }
    #expect(writes.isEmpty)
  }

  @Test func selectionPreservesWriteAndReadFailures() {
    let device = AudioOutput(id: 7, name: "Speaker", identity: AudioOutputs.digest("original"))
    let state = AudioOutputs(devices: [device], selected: 0)
    for failure in [AudioOutputError.notSettable, .coreAudio(-1)] {
      var reads = 0
      #expect(throws: failure) {
        try AudioOutputs.select(
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
    #expect(throws: AudioOutputError.coreAudio(-2)) {
      try AudioOutputs.select(
        id: 7, identity: device.identity,
        read: {
          if written { throw AudioOutputError.coreAudio(-2) }
          return state
        }, write: { _ in written = true })
    }
    #expect(written)
  }

  @Test func selectionRejectsIgnoredWriteAndHotplugDuringWrite() {
    let device = AudioOutput(id: 7, name: "Speaker", identity: AudioOutputs.digest("original"))
    for actual in [
      AudioOutputs(devices: [device], selected: 0),
      AudioOutputs(devices: [], selected: 0),
      AudioOutputs(
        devices: [.init(id: 7, name: "Other", identity: AudioOutputs.digest("new"))], selected: 7),
    ] {
      var written = false
      let expected: AudioOutputError =
        actual.devices == [device] ? .selectionNotApplied : .invalidSelection
      #expect(throws: expected) {
        try AudioOutputs.select(
          id: 7, identity: device.identity,
          read: { written ? actual : AudioOutputs(devices: [device], selected: 0) },
          write: { _ in written = true })
      }
      #expect(written)
    }
  }

  @Test func selectionRejectsDisconnectedOrReusedIDs() throws {
    let original = AudioOutput(id: 7, name: "Speaker", identity: AudioOutputs.digest("original"))
    let replacement = AudioOutput(
      id: 7, name: "Speaker", identity: AudioOutputs.digest("replacement"))
    let state = AudioOutputs(devices: [replacement], selected: 7)
    #expect(throws: AudioOutputError.self) {
      try state.device(id: original.id, identity: original.identity)
    }
    #expect(throws: AudioOutputError.self) {
      try state.device(id: 8, identity: replacement.identity)
    }
    #expect(try state.device(id: 7, identity: replacement.identity) == replacement)
  }

  @Test func namesAreJSONDataAndIdentityDoesNotExposeUID() throws {
    let uid = "private-hardware-uid"
    let name = "Speaker '\" $(touch /tmp/unwanted)\n --remove all"
    let device = AudioOutput(id: 7, name: name, identity: AudioOutputs.digest(uid))
    let data = try JSONEncoder().encode(AudioOutputs(devices: [device], selected: 7))
    #expect(try JSONDecoder().decode(AudioOutputs.self, from: data).devices == [device])
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
