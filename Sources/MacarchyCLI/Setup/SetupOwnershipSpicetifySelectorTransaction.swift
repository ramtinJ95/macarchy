import Darwin
import Foundation
import ThemeCore

extension SetupOwnershipManager {
  func setupSpicetifySelectorOwnership(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if let record = records.first(where: { $0.id == Self.spicetifySelectorsID }) {
      return try resumeSpicetifySelectorOwnership(
        record: record,
        context: context,
        dryRun: dryRun,
        records: &records
      )
    }

    guard try itemExists(context.spicetifySelectorsBackup) == false else {
      throw SetupOwnershipError.orphanedBackup(context.spicetifySelectorsBackup)
    }
    let replacement = context.spicetifyConfiguration.deletingLastPathComponent()
      .appending(path: context.spicetifySelectorsReplacementName)
    guard try itemExists(replacement) == false else {
      throw SetupOwnershipError.orphanedReplacement(replacement)
    }
    let original = try readConfiguration(
      context.spicetifyConfiguration,
      id: Self.spicetifySelectorsID
    )
    if try spicetifySelectorsAreExternal(original, target: context.spicetifyConfiguration) {
      return integrationResult(
        id: Self.spicetifySelectorsID,
        target: context.spicetifyConfiguration,
        status: .external,
        message: "The exact Spicetify theme selection is already externally owned"
      )
    }
    guard
      try pathContainsSymlink(
        context.spicetifyConfiguration,
        below: context.homeDirectory
      ) == false
    else {
      throw SetupOwnershipError.configurationIsExternallyOwned(
        Self.spicetifySelectorsID,
        context.spicetifyConfiguration
      )
    }
    let installed = try installedConfiguration(
      id: Self.spicetifySelectorsID,
      target: context.spicetifyConfiguration,
      original: original,
      transform: {
        try addingSpicetifySelectors(to: $0, target: context.spicetifyConfiguration)
      }
    )
    if dryRun {
      return integrationResult(
        id: Self.spicetifySelectorsID,
        target: context.spicetifyConfiguration,
        status: .planned,
        message: "Would back up and atomically set the Spicetify theme selection"
      )
    }

    let record = spicetifySelectorRecord(
      phase: .prepared,
      context: context,
      originalDigest: sha256Digest(original),
      installedDigest: sha256Digest(installed)
    )
    do {
      try save(record: record, records: &records, context: context)
      try faultInjector(.manifestPrepared)
      try writeRegularBackup(
        original,
        record: record,
        backupURL: context.spicetifySelectorsBackup
      )
      try faultInjector(.backupWritten)
      try replaceRegularFile(
        target: context.spicetifyConfiguration,
        replacementName: context.spicetifySelectorsReplacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: sha256Digest(original),
        data: installed,
        label: "Spicetify theme selection"
      )
      try faultInjector(.targetWritten)
      try save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(
        error,
        integrationID: Self.spicetifySelectorsID,
        target: context.spicetifyConfiguration
      )
    }
    return integrationResult(
      id: Self.spicetifySelectorsID,
      target: context.spicetifyConfiguration,
      status: .owned,
      message: "Set the Spicetify theme selection and recorded Macarchy ownership",
      mutationAttempted: true
    )
  }

  private func resumeSpicetifySelectorOwnership(
    record: SetupOwnershipRecord,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try validateSpicetifySelectorRecord(
      record,
      target: context.spicetifyConfiguration,
      backupURL: context.spicetifySelectorsBackup,
      context: context
    )
    guard
      try regularFilePathContainsSymlink(
        id: record.id,
        target: context.spicetifyConfiguration,
        context: context
      ) == false
    else {
      throw SetupOwnershipError.ownershipDrift(context.spicetifyConfiguration)
    }

    let backupExists = try itemExists(context.spicetifySelectorsBackup)
    let current = try readConfiguration(
      context.spicetifyConfiguration,
      id: Self.spicetifySelectorsID
    )
    let original: Data
    if backupExists {
      original = try readRegularBackup(
        record: record,
        backupURL: context.spicetifySelectorsBackup
      )
    } else {
      guard record.phase == .prepared,
        sha256Digest(current) == (try requiredOriginalDigest(record))
      else {
        throw SetupOwnershipError.corruptBackup(context.spicetifySelectorsBackup)
      }
      original = current
    }
    let originalSelection = try spicetifySelection(
      original,
      target: context.spicetifyConfiguration
    )

    let residue = try validateSpicetifySelectorResidue(
      record: record,
      originalSelection: originalSelection,
      context: context,
      remove: false
    )
    if residue != nil, record.phase == .prepared {
      if dryRun {
        return integrationResult(
          id: record.id,
          target: context.spicetifyConfiguration,
          status: .planned,
          message: "Would finalize the interrupted Spicetify theme selection"
        )
      }
      do {
        _ = try validateSpicetifySelectorResidue(
          record: record,
          originalSelection: originalSelection,
          context: context,
          remove: true
        )
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(
          error,
          integrationID: record.id,
          target: context.spicetifyConfiguration
        )
      }
      return integrationResult(
        id: record.id,
        target: context.spicetifyConfiguration,
        status: .owned,
        message: "Finalized the interrupted Spicetify theme selection",
        mutationAttempted: true
      )
    }

    var currentForUpdate = residue?.current ?? current
    if residue != nil {
      guard record.phase == .teardownPrepared else {
        throw SetupOwnershipError.ownershipDrift(context.spicetifyConfiguration)
      }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: context.spicetifyConfiguration,
          status: .planned,
          message: "Would restore ownership after the interrupted Spicetify teardown"
        )
      }
      do {
        _ = try validateSpicetifySelectorResidue(
          record: record,
          originalSelection: originalSelection,
          context: context,
          remove: true
        )
      } catch {
        throw SetupOwnershipTransactionError(
          error,
          integrationID: record.id,
          target: context.spicetifyConfiguration
        )
      }
      currentForUpdate = try readConfiguration(
        context.spicetifyConfiguration,
        id: Self.spicetifySelectorsID
      )
    }

    let currentSelection = try spicetifySelection(
      currentForUpdate,
      target: context.spicetifyConfiguration
    )
    if spicetifySelectionIsDesired(currentSelection) {
      if record.phase == .applied {
        return integrationResult(
          id: record.id,
          target: context.spicetifyConfiguration,
          status: .owned,
          message: "The Spicetify theme selection is Macarchy-owned and current"
        )
      }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: context.spicetifyConfiguration,
          status: .planned,
          message: "Would finalize the Spicetify theme selection ownership record"
        )
      }
      do {
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(
          error,
          integrationID: record.id,
          target: context.spicetifyConfiguration
        )
      }
      return integrationResult(
        id: record.id,
        target: context.spicetifyConfiguration,
        status: .owned,
        message: "Finalized the Spicetify theme selection ownership record",
        mutationAttempted: true
      )
    }
    guard spicetifySelectionsEqual(currentSelection, originalSelection) else {
      throw SetupOwnershipError.ownershipDrift(context.spicetifyConfiguration)
    }

    let installed = try addingSpicetifySelectors(
      to: currentForUpdate,
      target: context.spicetifyConfiguration
    )
    if dryRun {
      return integrationResult(
        id: record.id,
        target: context.spicetifyConfiguration,
        status: .planned,
        message: "Would resume the recorded Spicetify theme selection"
      )
    }
    let prepared = spicetifySelectorRecord(
      phase: .prepared,
      context: context,
      originalDigest: try requiredOriginalDigest(record),
      installedDigest: sha256Digest(installed)
    )
    do {
      try save(record: prepared, records: &records, context: context)
      if !backupExists {
        try writeRegularBackup(
          original,
          record: prepared,
          backupURL: context.spicetifySelectorsBackup
        )
      }
      try replaceRegularFile(
        target: context.spicetifyConfiguration,
        replacementName: context.spicetifySelectorsReplacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: sha256Digest(currentForUpdate),
        data: installed,
        label: "Spicetify theme selection"
      )
      try faultInjector(.targetWritten)
      try save(record: prepared.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(
        error,
        integrationID: record.id,
        target: context.spicetifyConfiguration
      )
    }
    return integrationResult(
      id: record.id,
      target: context.spicetifyConfiguration,
      status: .owned,
      message: "Resumed the recorded Spicetify theme selection",
      mutationAttempted: true
    )
  }

  func teardownSpicetifySelectorOwnership(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    guard let record = records.first(where: { $0.id == Self.spicetifySelectorsID }) else {
      return integrationResult(
        id: Self.spicetifySelectorsID,
        target: context.spicetifyConfiguration,
        status: .none,
        message: "No Macarchy-owned Spicetify theme selection exists"
      )
    }
    try validateSpicetifySelectorRecord(
      record,
      target: context.spicetifyConfiguration,
      backupURL: context.spicetifySelectorsBackup,
      context: context
    )
    guard
      try regularFilePathContainsSymlink(
        id: record.id,
        target: context.spicetifyConfiguration,
        context: context
      ) == false
    else {
      throw SetupOwnershipError.ownershipDrift(context.spicetifyConfiguration)
    }
    let original = try readRegularBackup(
      record: record,
      backupURL: context.spicetifySelectorsBackup
    )
    let originalSelection = try spicetifySelection(
      original,
      target: context.spicetifyConfiguration
    )
    let residue = try validateSpicetifySelectorResidue(
      record: record,
      originalSelection: originalSelection,
      context: context,
      remove: false
    )
    if residue != nil, record.phase == .teardownPrepared {
      if dryRun {
        return integrationResult(
          id: record.id,
          target: context.spicetifyConfiguration,
          status: .planned,
          message: "Would finish the interrupted Spicetify theme selection removal"
        )
      }
      do {
        _ = try validateSpicetifySelectorResidue(
          record: record,
          originalSelection: originalSelection,
          context: context,
          remove: true
        )
        try clearSpicetifySelectorOwnership(
          id: record.id,
          context: context,
          records: &records
        )
      } catch {
        throw SetupOwnershipTransactionError(
          error,
          integrationID: record.id,
          target: context.spicetifyConfiguration
        )
      }
      return integrationResult(
        id: record.id,
        target: context.spicetifyConfiguration,
        status: .removed,
        message: "Finished the interrupted Spicetify theme selection removal",
        mutationAttempted: true
      )
    }

    var current: Data
    if let residue {
      current = residue.current
    } else {
      current = try readConfiguration(
        context.spicetifyConfiguration,
        id: Self.spicetifySelectorsID
      )
    }
    if residue != nil {
      guard record.phase == .prepared else {
        throw SetupOwnershipError.ownershipDrift(context.spicetifyConfiguration)
      }
      if !dryRun {
        do {
          _ = try validateSpicetifySelectorResidue(
            record: record,
            originalSelection: originalSelection,
            context: context,
            remove: true
          )
          current = try readConfiguration(
            context.spicetifyConfiguration,
            id: Self.spicetifySelectorsID
          )
        } catch {
          throw SetupOwnershipTransactionError(
            error,
            integrationID: record.id,
            target: context.spicetifyConfiguration
          )
        }
      }
    }
    let currentSelection = try spicetifySelection(
      current,
      target: context.spicetifyConfiguration
    )
    if spicetifySelectionsEqual(currentSelection, originalSelection) {
      if record.phase == .teardownPrepared {
        guard record.replacementDigest == sha256Digest(current) else {
          throw SetupOwnershipError.ownershipDrift(context.spicetifyConfiguration)
        }
      }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: context.spicetifyConfiguration,
          status: .planned,
          message: "Would clear the restored Spicetify theme selection ownership record"
        )
      }
      do {
        try clearSpicetifySelectorOwnership(
          id: record.id,
          context: context,
          records: &records
        )
      } catch {
        throw SetupOwnershipTransactionError(
          error,
          integrationID: record.id,
          target: context.spicetifyConfiguration
        )
      }
      return integrationResult(
        id: record.id,
        target: context.spicetifyConfiguration,
        status: .removed,
        message: "Cleared the restored Spicetify theme selection ownership record",
        mutationAttempted: true
      )
    }
    guard spicetifySelectionIsDesired(currentSelection) else {
      throw SetupOwnershipError.ownershipDrift(context.spicetifyConfiguration)
    }
    let restored = try restoringSpicetifySelectors(
      in: current,
      from: originalSelection,
      target: context.spicetifyConfiguration
    )
    if dryRun {
      return integrationResult(
        id: record.id,
        target: context.spicetifyConfiguration,
        status: .planned,
        message: "Would restore only the original Spicetify theme selection"
      )
    }

    let teardownPrepared = spicetifySelectorRecord(
      phase: .teardownPrepared,
      context: context,
      originalDigest: try requiredOriginalDigest(record),
      installedDigest: sha256Digest(current),
      replacementDigest: sha256Digest(restored)
    )
    do {
      try save(record: teardownPrepared, records: &records, context: context)
      try faultInjector(.teardownReady)
      try replaceRegularFile(
        target: context.spicetifyConfiguration,
        replacementName: context.spicetifySelectorsReplacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: sha256Digest(current),
        data: restored,
        label: "Spicetify theme selection"
      )
      try faultInjector(.targetWritten)
      try clearSpicetifySelectorOwnership(
        id: record.id,
        context: context,
        records: &records
      )
    } catch {
      throw SetupOwnershipTransactionError(
        error,
        integrationID: record.id,
        target: context.spicetifyConfiguration
      )
    }
    return integrationResult(
      id: record.id,
      target: context.spicetifyConfiguration,
      status: .removed,
      message: "Restored only the original Spicetify theme selection",
      mutationAttempted: true
    )
  }

  func validateSpicetifySelectorRecord(
    _ record: SetupOwnershipRecord,
    target: URL,
    backupURL: URL,
    context: Context
  ) throws {
    guard record.kind == .spicetifySelection, record.targetPath == target.path else {
      throw SetupOwnershipError.invalidManifest("\(record.id) target is not allowlisted")
    }
    guard record.backupPath == relativePath(backupURL, below: context.stateRoot),
      record.linkDestination == nil
    else {
      throw SetupOwnershipError.invalidManifest("\(record.id) backup is not allowlisted")
    }
    _ = try requiredOriginalDigest(record)
    switch record.phase {
    case .prepared, .applied:
      guard record.replacementDigest == nil else {
        throw SetupOwnershipError.invalidManifest("\(record.id) has invalid replacement state")
      }
    case .teardownPrepared:
      guard record.replacementDigest != nil else {
        throw SetupOwnershipError.invalidManifest("\(record.id) is missing replacement state")
      }
    }
  }

  private func spicetifySelectorRecord(
    phase: SetupOwnershipRecord.Phase,
    context: Context,
    originalDigest: String,
    installedDigest: String,
    replacementDigest: String? = nil
  ) -> SetupOwnershipRecord {
    SetupOwnershipRecord(
      id: Self.spicetifySelectorsID,
      phase: phase,
      kind: .spicetifySelection,
      targetPath: context.spicetifyConfiguration.path,
      backupPath: relativePath(context.spicetifySelectorsBackup, below: context.stateRoot),
      originalDigest: originalDigest,
      installedDigest: installedDigest,
      linkDestination: nil,
      replacementDigest: replacementDigest
    )
  }

  private func clearSpicetifySelectorOwnership(
    id: String,
    context: Context,
    records: inout [SetupOwnershipRecord]
  ) throws {
    try removeRegularFileIfPresent(
      context.spicetifySelectorsBackup,
      unsafe: .corruptBackup(context.spicetifySelectorsBackup)
    )
    records.removeAll { $0.id == id }
    try persist(records: records, context: context)
  }

  private struct SpicetifySelectorResidue {
    let current: Data
  }

  private func validateSpicetifySelectorResidue(
    record: SetupOwnershipRecord,
    originalSelection: SpicetifyAdapter.ConfigurationSelection,
    context: Context,
    remove: Bool
  ) throws -> SpicetifySelectorResidue? {
    let target = context.spicetifyConfiguration
    let replacementName = context.spicetifySelectorsReplacementName
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: context.homeDirectory,
      label: "Spicetify theme selection"
    )
    defer { Darwin.close(parentDescriptor) }
    let replacementURL = target.deletingLastPathComponent().appending(path: replacementName)
    let residueDescriptor = replacementName.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    if residueDescriptor < 0, errno == ENOENT { return nil }
    guard residueDescriptor >= 0 else {
      throw posixError("open Spicetify replacement residue", replacementURL)
    }
    defer { Darwin.close(residueDescriptor) }
    let displaced = try readPinnedRegularFile(
      descriptor: residueDescriptor,
      url: replacementURL,
      label: "Spicetify theme selection"
    ).data
    let current = try readPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: target.lastPathComponent,
      url: target,
      label: "Spicetify theme selection"
    ).data
    let currentSelection = try spicetifySelection(current, target: target)
    let displacedSelection = try spicetifySelection(displaced, target: target)
    switch record.phase {
    case .prepared:
      guard sha256Digest(current) == record.installedDigest,
        sha256Digest(displaced) == (try requiredOriginalDigest(record)),
        spicetifySelectionIsDesired(currentSelection),
        spicetifySelectionsEqual(displacedSelection, originalSelection)
      else {
        throw SetupOwnershipError.ownershipDrift(target)
      }
    case .teardownPrepared:
      guard sha256Digest(displaced) == record.installedDigest,
        sha256Digest(current) == record.replacementDigest,
        spicetifySelectionIsDesired(displacedSelection),
        spicetifySelectionsEqual(currentSelection, originalSelection)
      else {
        throw SetupOwnershipError.ownershipDrift(target)
      }
    case .applied:
      throw SetupOwnershipError.ownershipDrift(target)
    }
    if remove {
      guard replacementName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
        throw posixError("remove Spicetify replacement residue", replacementURL)
      }
    }
    return SpicetifySelectorResidue(current: current)
  }
}
