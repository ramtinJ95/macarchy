import ArgumentParser
import Darwin
import Foundation
import ThemeCore

extension Desktop {
  struct MigrateOwnership: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Review and bind legacy retained originals to a persistent volume UUID (no service changes)."
    )

    @Argument(help: "One canonical provider: sketchybar, yabai, or skhd.")
    var provider: RetainedOwnershipMigration.Provider

    @Option(help: "Exact evidence digest from a reviewed preview; omitted means read-only preview.")
    var approve: String?

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let report = try RetainedOwnershipMigration(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
      ).execute(provider: provider, approval: approve)
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
      } else {
        print("\(report.provider.rawValue): \(report.status)")
        print("Retained original: \(report.retainedPath)")
        print("Volume UUID: \(report.volumeUUID); inode: \(report.inode)")
        print(
          "Recorded device: \(report.recordedDevice); observed device: \(report.observedDevice)")
        print(report.warning)
        print("Evidence: \(report.evidenceDigest)")
      }
    }
  }
}

/// A per-provider, ownership-only atomic update. Never republishes a generation or runs a service.
struct RetainedOwnershipMigration {
  enum Provider: String, Codable, ExpressibleByArgument {
    case sketchybar, yabai, skhd
  }

  struct Report: Codable, Equatable {
    let provider: Provider
    var status: String
    let retainedPath: String
    let volumeUUID: String
    let inode: UInt64
    let recordedDevice: UInt64
    let observedDevice: UInt64
    let generationID: String
    let warning: String
    var evidenceDigest: String
  }

  let homeDirectory: URL
  var stateRoot: URL { homeDirectory.appending(path: ".config/macarchy") }

  func execute(provider: Provider, approval: String? = nil) throws -> Report {
    guard let approval else { return try candidate(provider).report }
    return try ActivationLock(root: stateRoot).withLock {
      let reviewed = try candidate(provider)
      guard reviewed.report.evidenceDigest == approval else {
        throw failure("stale or incorrect approval; review a fresh ownership migration preview")
      }
      if reviewed.report.status == "already_bound" { return reviewed.report }
      // Re-read all evidence immediately before publication, under the shared activation lock.
      let current = try candidate(provider)
      guard current.report == reviewed.report else {
        throw failure("ownership migration evidence changed before publication")
      }
      try current.persist()
      var report = current.report
      report.status = "migrated"
      return report
    }
  }

  private struct Candidate {
    let report: Report
    let persist: () throws -> Void
  }

  private func candidate(_ provider: Provider) throws -> Candidate {
    guard !DesktopAggregateTransactionStore(stateRoot: stateRoot).exists,
      try UnifiedSetupTransactionStore(stateRoot: stateRoot).read() == nil
    else { throw failure("pending desktop/setup transaction blocks ownership migration") }
    switch provider {
    case .sketchybar:
      guard !SketchyBarTransactionStore(stateRoot: stateRoot).exists else {
        throw failure("pending SketchyBar transaction blocks ownership migration")
      }
      let store = SketchyBarOwnershipStore(stateRoot: stateRoot)
      guard let record = try store.read(), let path = record.retainedOriginalPath else {
        throw failure("no retained SketchyBar original to migrate")
      }
      var updated = record
      let uuid = try RetainedOriginalIdentity.volumeUUID(at: URL(filePath: path))
      if updated.original.volumeUUID == nil { updated.original.volumeUUID = uuid }
      let generation = SketchyBarGenerationInspector(stateRoot: stateRoot).inspect()
      let inspection = try SketchyBarProviderPlanInspector().inspectManaged(
        updated, entry: homeDirectory.appending(path: ".config/sketchybar/sketchybarrc"),
        expectedTarget: SketchyBarProviderPlanInspector.managedTarget(
          homeDirectory: homeDirectory, stateRoot: stateRoot), generation: generation
      )
      guard inspection.status == .managed else { throw failure(inspection.message) }
      return try candidateReport(
        provider, path: path, uuid: uuid,
        bound: record.original.volumeUUID != nil, device: record.original.device,
        generationID: record.generationID, evidence: record
      ) { try store.write(updated) }

    case .yabai:
      guard !YabaiTransactionStore(stateRoot: stateRoot).exists else {
        throw failure("pending yabai transaction blocks ownership migration")
      }
      let store = YabaiOwnershipStore(stateRoot: stateRoot)
      guard let record = try store.read(), let path = record.retainedOriginalPath else {
        throw failure("no retained yabai original to migrate")
      }
      let entry = homeDirectory.appending(path: ".config/yabai/yabairc")
      let retained = URL(filePath: path)
      let prefix = "retained-"
      guard
        retained.deletingLastPathComponent().path
          == stateRoot.appending(path: "desktop/yabai").path,
        retained.lastPathComponent.hasPrefix(prefix),
        UUID(uuidString: String(retained.lastPathComponent.dropFirst(prefix.count))) != nil,
        record.original.publicPath
          == (record.original.kind == .directorySymlink
            ? entry.deletingLastPathComponent().path : entry.path),
        record.managedTarget
          == YabaiProviderPlanInspector.managedTarget(
            homeDirectory: homeDirectory, stateRoot: stateRoot)
      else { throw failure("yabai ownership paths do not match the canonical provider") }
      let generation = YabaiGenerationInspector(stateRoot: stateRoot).inspect()
      guard generation.status == .current, generation.generationID == record.generationID else {
        throw failure("yabai selected generation does not match ownership")
      }
      var updated = record
      let uuid = try RetainedOriginalIdentity.volumeUUID(at: retained)
      if updated.original.volumeUUID == nil { updated.original.volumeUUID = uuid }
      let inspection = YabaiProviderPlanInspector().inspectManaged(updated, entry: entry)
      guard inspection.status == .managed else { throw failure(inspection.message) }
      return try candidateReport(
        provider, path: path, uuid: uuid,
        bound: record.original.volumeUUID != nil, device: record.original.device,
        generationID: record.generationID, evidence: record
      ) { try store.write(updated) }

    case .skhd:
      guard try KeybindingApplyTransactionStore(stateRoot: stateRoot).read() == nil else {
        throw failure("pending keybinding transaction blocks ownership migration")
      }
      let manager = SetupOwnershipManager()
      let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
      let records = try manager.readRecords(context: context)
      guard
        let index = records.firstIndex(where: { $0.id == KeybindingProviderInspector.ownershipID }),
        let path = records[index].retainedOriginalPath,
        records.allSatisfy({ $0.phase == .applied })
      else { throw failure("no applied retained skhd original, or setup ownership is pending") }
      let record = records[index]
      var updated = record
      let uuid = try RetainedOriginalIdentity.volumeUUID(at: URL(filePath: path))
      if updated.originalVolumeUUID == nil { updated.originalVolumeUUID = uuid }
      try KeybindingProviderInspector.validateOwnershipRecord(updated, context: context)
      let transaction = KeybindingProviderTransaction(homeDirectory: homeDirectory)
      let parent = try PinnedFilesystem.openDirectory(at: transaction.directory)
      defer { close(parent) }
      guard
        try transaction.leafState(descriptor: parent, name: "skhdrc", record: updated) == .managed
      else {
        throw failure("managed skhd entry or claim marker drifted")
      }
      try KeybindingProviderInspector().validateManagedOwnershipMarkers(
        directoryDescriptor: parent, entry: transaction.entry, record: updated)
      let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
      guard generation.status == .current, let generationID = generation.generationID else {
        throw failure("skhd selected generation is not valid")
      }
      return try candidateReport(
        provider, path: path, uuid: uuid,
        bound: record.originalVolumeUUID != nil, device: record.originalDevice,
        generationID: generationID, evidence: records
      ) {
        var replacement = records
        replacement[index] = updated
        try manager.persist(records: replacement, context: context)
      }
    }
  }

  private func candidateReport<E: Encodable>(
    _ provider: Provider, path: String, uuid: String, bound: Bool, device: UInt64?,
    generationID: String, evidence: E, persist: @escaping () throws -> Void
  ) throws -> Candidate {
    var metadata = stat()
    guard lstat(path, &metadata) == 0, let device,
      try RetainedOriginalIdentity.volumeUUID(at: URL(filePath: path), matching: metadata) == uuid
    else { throw failure("retained original identity changed during inspection") }
    var report = Report(
      provider: provider, status: bound ? "already_bound" : "review_required",
      retainedPath: path, volumeUUID: uuid, inode: UInt64(metadata.st_ino),
      recordedDevice: device, observedDevice: UInt64(metadata.st_dev), generationID: generationID,
      warning: bound
        ? "Already UUID-bound; no ownership rewrite required."
        : "Legacy evidence did not record a volume UUID. Historical volume identity cannot be proven. Approval binds the matching surviving original to this observed volume; it does not regenerate configuration or restart services.",
      evidenceDigest: ""
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(report)
    data.append(try encoder.encode(evidence))
    report.evidenceDigest = sha256Digest(data)
    return Candidate(report: report, persist: persist)
  }

  private func failure(_ message: String) -> ValidationError { ValidationError(message) }
}
