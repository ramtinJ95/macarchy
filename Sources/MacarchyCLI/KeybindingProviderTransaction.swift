import Darwin
import Foundation
import ThemeCore

struct KeybindingProviderTransaction: Sendable {
  let homeDirectory: URL

  private var manager: SetupOwnershipManager { SetupOwnershipManager() }
  private var context: SetupOwnershipManager.Context {
    SetupOwnershipManager.Context(homeDirectory: homeDirectory)
  }
  private var entry: URL {
    homeDirectory.appending(path: ".config/skhd/skhdrc")
  }

  func installEntry() throws {
    let manager = manager
    let context = context
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
    let manager = manager
    let context = context
    var records = try manager.readRecords(context: context)
    guard let record = records.first(where: { $0.id == KeybindingProviderInspector.ownershipID })
    else { return }
    try KeybindingProviderInspector.validateOwnershipRecord(record, context: context)
    let target = KeybindingProviderInspector.managedTarget
    guard try manager.parentPathContainsSymlink(entry, below: homeDirectory) == false else {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    var metadata = stat()
    let inspected = lstat(entry.path, &metadata)
    if inspected == 0, metadata.st_mode & S_IFMT == S_IFLNK {
      try manager.removePinnedSymbolicLink(
        id: KeybindingProviderInspector.ownershipID,
        target: entry,
        destinationPath: target,
        homeDirectory: homeDirectory,
        label: "skhd entry",
        alreadyClaimed: false
      )
    } else if inspected == 0 || errno != ENOENT || record.phase == .applied {
      throw SetupOwnershipError.ownershipDrift(entry)
    }
    records.removeAll { $0.id == KeybindingProviderInspector.ownershipID }
    try manager.persist(records: records, context: context)
  }
}
