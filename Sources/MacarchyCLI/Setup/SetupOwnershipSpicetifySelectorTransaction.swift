import Darwin
import Foundation
import ThemeCore

extension SetupOwnershipManager {
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
      try attributingFailure(to: record.id, target: context.spicetifyConfiguration) {
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
        try attributingFailure(to: record.id, target: context.spicetifyConfiguration) {
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
      try attributingFailure(to: record.id, target: context.spicetifyConfiguration) {
        try clearSpicetifySelectorOwnership(
          id: record.id,
          context: context,
          records: &records
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
    try attributingFailure(to: record.id, target: context.spicetifyConfiguration) {
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
    return try withReplacementResidue(
      target: target,
      replacementName: context.spicetifySelectorsReplacementName,
      homeDirectory: context.homeDirectory,
      label: "Spicetify theme selection",
      residueDescription: "Spicetify replacement residue",
      remove: remove
    ) { displaced, current in
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
      return SpicetifySelectorResidue(current: current)
    }
  }
}
