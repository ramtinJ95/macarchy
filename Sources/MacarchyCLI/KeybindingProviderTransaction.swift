import Darwin
import Foundation
import ThemeCore

struct KeybindingProviderTransaction: Sendable {
  let homeDirectory: URL

  private var entry: URL {
    homeDirectory.appending(path: ".config/skhd/skhdrc")
  }

  func installEntry() throws {
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    var records = try manager.readRecords(context: context)
    guard !records.contains(where: { $0.id == KeybindingProviderInspector.ownershipID }) else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    let target = KeybindingProviderInspector.managedTarget
    let record = SetupOwnershipRecord(
      id: KeybindingProviderInspector.ownershipID,
      phase: .prepared,
      kind: .symbolicLink,
      targetPath: entry.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(target.utf8)),
      linkDestination: target
    )
    try manager.save(record: record, records: &records, context: context)
    do {
      try manager.createPinnedSymbolicLink(
        target: entry,
        destinationPath: target,
        homeDirectory: homeDirectory,
        label: "skhd entry"
      )
      try manager.save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(
        error,
        integrationID: KeybindingProviderInspector.ownershipID,
        target: entry
      )
    }
  }

  func removeInstalledEntry() throws {
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    var records = try manager.readRecords(context: context)
    guard let record = records.first(where: { $0.id == KeybindingProviderInspector.ownershipID })
    else { return }
    try KeybindingProviderInspector.validateOwnershipRecord(record, context: context)
    let target = KeybindingProviderInspector.managedTarget
    guard try manager.parentPathContainsSymlink(entry, below: homeDirectory) == false else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    let state = try manager.themeLinkState(
      id: KeybindingProviderInspector.ownershipID,
      url: entry,
      target: entry
    )
    let removalState = try manager.themeLinkRemovalState(
      id: KeybindingProviderInspector.ownershipID,
      target: entry
    )
    let alreadyClaimed: Bool
    switch (state, removalState) {
    case (.matching(let destination), .missing) where destination == target:
      alreadyClaimed = false
    case (.missing, .matching(let destination)) where destination == target:
      alreadyClaimed = true
    case (.missing, .missing):
      let parentDescriptor = try manager.openPinnedParent(
        target: entry,
        homeDirectory: homeDirectory,
        label: "skhd entry"
      )
      defer { Darwin.close(parentDescriptor) }
      guard fsync(parentDescriptor) == 0 else {
        throw SetupOwnershipError.system(
          "sync absent skhd entry",
          entry.deletingLastPathComponent(),
          String(cString: strerror(errno))
        )
      }
      records.removeAll { $0.id == KeybindingProviderInspector.ownershipID }
      try manager.persist(records: records, context: context)
      return
    default:
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    if state != .missing || alreadyClaimed {
      try manager.removePinnedSymbolicLink(
        id: KeybindingProviderInspector.ownershipID,
        target: entry,
        destinationPath: target,
        homeDirectory: homeDirectory,
        label: "skhd entry",
        alreadyClaimed: alreadyClaimed
      )
    }
    records.removeAll { $0.id == KeybindingProviderInspector.ownershipID }
    try manager.persist(records: records, context: context)
  }
}
