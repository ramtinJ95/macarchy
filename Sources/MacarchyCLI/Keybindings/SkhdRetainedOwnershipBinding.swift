import ArgumentParser
import Darwin
import Foundation
import ThemeCore

/// skhd's part of `desktop migrate-ownership`: the applied retained original and the setup
/// ownership rewrite that binds it to its observed volume UUID. Only `persist` writes.
struct SkhdRetainedOwnershipBinding {
  let retainedPath: String
  let volumeUUID: String
  let alreadyBound: Bool
  let recordedDevice: UInt64?
  let generationID: String
  /// The setup ownership records a reviewed approval covers.
  let evidence: [SetupOwnershipRecord]
  let persist: () throws -> Void

  /// Throws `ValidationError` when pending work, drift or an invalid generation blocks binding.
  static func inspect(homeDirectory: URL, stateRoot: URL) throws -> Self {
    guard try KeybindingApplyTransactionStore(stateRoot: stateRoot).read() == nil else {
      throw ValidationError("pending keybinding transaction blocks ownership migration")
    }
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let records = try manager.readRecords(context: context)
    guard
      let index = records.firstIndex(where: { $0.id == KeybindingProviderInspector.ownershipID }),
      let path = records[index].retainedOriginalPath,
      records.allSatisfy({ $0.phase == .applied })
    else {
      throw ValidationError(
        "no applied retained skhd original, or setup ownership is pending")
    }
    let record = records[index]
    var updated = record
    let uuid = try RetainedOriginalIdentity.volumeUUID(at: URL(filePath: path))
    if updated.originalVolumeUUID == nil { updated.originalVolumeUUID = uuid }
    try KeybindingProviderInspector.validateOwnershipRecord(updated, context: context)
    let transaction = KeybindingProviderTransaction(homeDirectory: homeDirectory)
    let parent = try PinnedFilesystem.openDirectory(at: transaction.directory)
    defer { close(parent) }
    guard
      try transaction.leafState(
        descriptor: parent, name: SkhdLayout.configurationName, record: updated) == .managed
    else {
      throw ValidationError("managed skhd entry or claim marker drifted")
    }
    try KeybindingProviderInspector().validateManagedOwnershipMarkers(
      directoryDescriptor: parent, layout: transaction.layout, record: updated)
    let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    guard generation.status == .current, let generationID = generation.generationID else {
      throw ValidationError("skhd selected generation is not valid")
    }
    return Self(
      retainedPath: path, volumeUUID: uuid, alreadyBound: record.originalVolumeUUID != nil,
      recordedDevice: record.originalDevice, generationID: generationID, evidence: records
    ) {
      var replacement = records
      replacement[index] = updated
      try manager.persist(records: replacement, context: context)
    }
  }
}
