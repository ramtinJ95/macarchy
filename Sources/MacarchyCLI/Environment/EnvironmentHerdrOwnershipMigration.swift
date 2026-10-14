import ArgumentParser
import Foundation
import ThemeCore

extension EnvironmentCommand {
  struct MigrateOwnership: ParsableCommand {
    enum Provider: String, ExpressibleByArgument {
      case herdr
    }

    static let configuration = CommandConfiguration(
      abstract: "Review and bind legacy environment ownership to a persistent volume UUID."
    )

    @Argument(help: "Canonical provider: herdr.")
    var provider: Provider

    @Option(help: "Exact evidence digest from a reviewed preview; omitted means read-only preview.")
    var approve: String?

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let report = try EnvironmentHerdrOwnershipMigration(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
      ).execute(approval: approve)
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
      } else {
        print("Herdr: \(report.status)")
        print("Directory link: \(report.path)")
        print("Volume UUID: \(report.volumeUUID); inode: \(report.inode)")
        print(
          "Recorded device: \(report.recordedDevice); observed device: \(report.observedDevice)")
        print(report.warning)
        print("Evidence: \(report.evidenceDigest)")
      }
    }
  }
}

/// Updates only the Herdr identity field. No provider configuration, generation or runtime changes.
struct EnvironmentHerdrOwnershipMigration {
  struct Report: Codable, Equatable {
    var status: String
    let path: String
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

  func execute(approval: String? = nil) throws -> Report {
    guard let approval else { return try candidate().report }
    // Match the environment -> activation lock order used by theme reconciliation.
    let lock = EnvironmentLifecycleLock(stateRoot: stateRoot)
    let descriptor = try lock.acquire()
    defer { lock.release(descriptor) }
    return try ActivationLock(root: stateRoot).withLock {
      let reviewed = try candidate()
      guard reviewed.report.evidenceDigest == approval else {
        throw ValidationError("stale or incorrect approval; review a fresh Herdr ownership preview")
      }
      if reviewed.report.status == "already_bound" { return reviewed.report }
      let current = try candidate()
      guard current.report == reviewed.report else {
        throw ValidationError("Herdr ownership evidence changed before publication")
      }
      try EnvironmentStateStore(stateRoot: stateRoot).writeOwnership(current.ownership)
      var report = current.report
      report.status = "migrated"
      return report
    }
  }

  private func candidate() throws -> (report: Report, ownership: EnvironmentOwnership) {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard !store.transactionExists,
      try UnifiedSetupTransactionStore(stateRoot: stateRoot).read() == nil,
      !DesktopAggregateTransactionStore(stateRoot: stateRoot).exists
    else { throw ValidationError("pending environment/setup transaction blocks Herdr migration") }
    guard let ownership = try store.readOwnership(), var herdr = ownership.herdr,
      let expected = herdr.directoryLink, let recordedDevice = expected.device,
      try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination()
        == "generations/\(ownership.generationID)"
    else { throw ValidationError("no matching applied Herdr directory-link ownership to migrate") }
    let directory = homeDirectory.appending(path: ".config/herdr")
    let observed = try EnvironmentProviderInspector().capture(directory, directoryLink: nil)
    let uuid = try EnvironmentHerdrDirectoryIdentity.volumeUUID(at: directory, matching: observed)
    let bound = herdr.directoryVolumeUUID != nil
    if !bound { herdr.directoryVolumeUUID = uuid }
    let file = EnvironmentHerdrFileTransaction(homeDirectory: homeDirectory, stateRoot: stateRoot)
    if ownership.herdrEnabled {
      try file.preflight(herdr)
    } else {
      try file.preflightOriginal(herdr)
    }
    guard let inode = observed.inode, let device = observed.device else {
      throw ValidationError("Herdr directory identity is incomplete")
    }
    var report = Report(
      status: bound ? "already_bound" : "review_required", path: directory.path,
      volumeUUID: uuid, inode: inode, recordedDevice: recordedDevice, observedDevice: device,
      generationID: ownership.generationID,
      warning: bound
        ? "Already UUID-bound; no ownership rewrite required."
        : "Legacy evidence did not record a volume UUID. Historical volume identity cannot be proven. Approval binds the matching surviving Herdr link to this observed volume; it does not change configuration, activate a theme or restart applications.",
      evidenceDigest: "")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var evidence = try encoder.encode(report)
    evidence.append(try encoder.encode(ownership))
    evidence.append(try encoder.encode(observed))
    // Bind review to current configuration too, without copying any of it into the report.
    evidence.append(try BoundedRegularFile.read(at: URL(filePath: herdr.resolvedPath)).data)
    report.evidenceDigest = sha256Digest(evidence)
    return (report, ownership.replacingHerdr(herdr))
  }
}
