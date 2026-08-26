import Darwin
import Foundation
import ThemeCore

enum SetupOwnershipCheckpoint: Equatable, Sendable {
  case manifestPrepared
  case backupWritten
  case replacementReady
  case replacementSwapped
  case targetWritten
  case teardownReady
}

enum SetupOwnershipError: Error, CustomStringConvertible, Equatable, Sendable {
  case conflictingKittyInclude(URL)
  case conflictingDirective(String, URL)
  case conflictingThemeLink(String, URL)
  case configurationIsExternallyOwned(String, URL)
  case configurationTooLarge(String, URL)
  case corruptBackup(URL)
  case invalidManifest(String)
  case kittyConfigurationIsExternallyOwned(URL)
  case kittyConfigurationTooLarge(URL)
  case missingConfiguration(String, URL)
  case missingKittyConfiguration(URL)
  case orphanedBackup(URL)
  case orphanedReplacement(URL)
  case ownershipDrift(URL)
  case system(String, URL, String)
  case unreadableConfiguration(String, URL)
  case unreadableKittyConfiguration(URL)

  var description: String {
    switch self {
    case .conflictingKittyInclude(let url):
      "Kitty configuration at \(url.path) contains a conflicting Macarchy include"
    case .conflictingDirective(let id, let url):
      "Configuration at \(url.path) contains a conflicting \(id) directive"
    case .conflictingThemeLink(let id, let url):
      "Theme path at \(url.path) conflicts with the required \(id) link"
    case .configurationIsExternallyOwned(let id, let url):
      "Configuration for \(id) at \(url.path) is symlinked or inside a symlinked directory; update its external source instead"
    case .configurationTooLarge(let id, let url):
      "Configuration for \(id) at \(url.path) exceeds 1 MiB"
    case .corruptBackup(let url):
      "Macarchy-owned backup at \(url.path) is missing or corrupt"
    case .invalidManifest(let reason):
      "Setup ownership manifest is invalid: \(reason)"
    case .kittyConfigurationIsExternallyOwned(let url):
      "Kitty configuration at \(url.path) is symlinked or inside a symlinked directory; update its external source instead"
    case .kittyConfigurationTooLarge(let url):
      "Kitty configuration at \(url.path) exceeds 1 MiB"
    case .missingKittyConfiguration(let url):
      "Kitty configuration must already exist as an ordinary file at \(url.path)"
    case .missingConfiguration(let id, let url):
      "Configuration for \(id) must already exist as an ordinary file at \(url.path)"
    case .orphanedBackup(let url):
      "Setup backup exists without an ownership manifest at \(url.path); refusing to overwrite recovery evidence"
    case .orphanedReplacement(let url):
      "Setup replacement residue exists without an ownership manifest at \(url.path); refusing to overwrite recovery evidence"
    case .ownershipDrift(let url):
      "Macarchy-owned integration at \(url.path) changed after setup; refusing to overwrite it"
    case .system(let operation, let url, let cause):
      "Cannot \(operation) \(url.path): \(cause)"
    case .unreadableConfiguration(let id, let url):
      "Cannot read configuration for \(id) at \(url.path) as UTF-8"
    case .unreadableKittyConfiguration(let url):
      "Cannot read Kitty configuration at \(url.path) as UTF-8"
    }
  }

}

struct SetupOwnershipTransactionError: Error, CustomStringConvertible, Sendable {
  let cause: String
  let integrationID: String
  let target: String
  let completedResults: [SetupIntegrationResult]
  let failureMutationAttempted: Bool

  init(
    _ error: any Error,
    integrationID: String,
    target: URL,
    completedResults: [SetupIntegrationResult] = [],
    failureMutationAttempted: Bool = true
  ) {
    cause = String(describing: error)
    self.integrationID = integrationID
    self.target = target.path
    self.completedResults = completedResults
    self.failureMutationAttempted = failureMutationAttempted
  }

  init(
    wrapping error: SetupOwnershipTransactionError,
    completedResults: [SetupIntegrationResult]
  ) {
    cause = error.cause
    integrationID = error.integrationID
    target = error.target
    self.completedResults = completedResults + error.completedResults
    failureMutationAttempted = error.failureMutationAttempted
  }

  var description: String { cause }
}

struct SetupIntegrationResult: Encodable, Sendable {
  enum Status: String, Encodable, Sendable {
    case external
    case failed
    case none
    case owned
    case planned
    case removed
  }

  let id: String
  let status: Status
  let target: String
  let message: String
  let mutationAttempted: Bool

  var succeeded: Bool {
    status != .failed
  }
}

struct SetupOwnershipManager: Sendable {
  static let integrationID = "kitty.include"
  static let batSelectorID = "bat.selector"
  static let batThemeLinkID = "bat.theme-link"
  static let ezaEnvironmentID = "eza.environment"
  static let ezaThemeLinkID = "eza.theme-link"
  static let maximumConfigurationSize = 1_048_576
  private static let integrationOrder = [
    integrationID,
    batSelectorID,
    batThemeLinkID,
    ezaEnvironmentID,
    ezaThemeLinkID,
  ]

  let faultInjector: @Sendable (SetupOwnershipCheckpoint) throws -> Void

  init(
    faultInjector: @escaping @Sendable (SetupOwnershipCheckpoint) throws -> Void = { _ in }
  ) {
    self.faultInjector = faultInjector
  }

  static func failureResult(_ error: any Error, homeDirectory: URL) -> SetupIntegrationResult {
    let context = Context(homeDirectory: homeDirectory)
    let mutationAttempted =
      (error as? SetupOwnershipTransactionError)?.failureMutationAttempted ?? false
    let identity: (id: String, target: String)
    if let transaction = error as? SetupOwnershipTransactionError {
      identity = (transaction.integrationID, transaction.target)
    } else if let ownershipError = error as? SetupOwnershipError {
      switch ownershipError {
      case .conflictingDirective(let id, let url),
        .conflictingThemeLink(let id, let url),
        .configurationIsExternallyOwned(let id, let url),
        .configurationTooLarge(let id, let url),
        .missingConfiguration(let id, let url),
        .unreadableConfiguration(let id, let url):
        identity = (id, url.path)
      case .ownershipDrift(let url):
        identity = integrationIdentity(for: url, context: context)
      case .corruptBackup(let url), .orphanedBackup(let url), .orphanedReplacement(let url):
        identity = integrationIdentity(for: url, context: context)
      case .system(_, let url, _):
        identity = integrationIdentity(for: url, context: context)
      case .invalidManifest:
        identity = ("setup.ownership", context.manifestURL.path)
      default:
        identity = (integrationID, context.kittyConfiguration.path)
      }
    } else {
      identity = ("setup.ownership", context.manifestURL.path)
    }
    return SetupIntegrationResult(
      id: identity.id,
      status: .failed,
      target: identity.target,
      message: String(describing: error),
      mutationAttempted: mutationAttempted
    )
  }

  static func failureResults(
    _ error: any Error,
    homeDirectory: URL
  ) -> [SetupIntegrationResult] {
    let completed = (error as? SetupOwnershipTransactionError)?.completedResults ?? []
    let order = Dictionary(uniqueKeysWithValues: integrationOrder.enumerated().map { ($1, $0) })
    return (completed + [failureResult(error, homeDirectory: homeDirectory)]).sorted {
      order[$0.id, default: Int.max] < order[$1.id, default: Int.max]
    }
  }

  private static func integrationIdentity(
    for url: URL,
    context: Context
  ) -> (id: String, target: String) {
    switch url.path {
    case context.batConfiguration.path, context.batSelectorBackup.path,
      context.batConfiguration.deletingLastPathComponent()
      .appending(path: context.batSelectorReplacementName).path:
      (batSelectorID, url.path)
    case context.batThemeLink.path:
      (batThemeLinkID, url.path)
    case context.shellConfiguration.path, context.ezaEnvironmentBackup.path,
      context.shellConfiguration.deletingLastPathComponent()
      .appending(path: context.ezaEnvironmentReplacementName).path:
      (ezaEnvironmentID, url.path)
    case context.ezaThemeLink.path:
      (ezaThemeLinkID, url.path)
    case context.kittyConfiguration.path, context.backupURL.path, context.replacementURL.path:
      (integrationID, url.path)
    default:
      ("setup.ownership", url.path)
    }
  }

  func setup(
    homeDirectory: URL,
    dryRun: Bool
  ) throws -> [SetupIntegrationResult] {
    let context = Context(homeDirectory: homeDirectory)
    if dryRun { return try setup(context: context, dryRun: true) }
    return try ActivationLock(root: context.stateRoot).withLock {
      try setup(context: context, dryRun: false)
    }
  }

  func teardown(homeDirectory: URL, dryRun: Bool) throws -> [SetupIntegrationResult] {
    let context = Context(homeDirectory: homeDirectory)
    if dryRun { return try teardown(context: context, dryRun: true) }
    return try ActivationLock(root: context.stateRoot).withLock {
      try teardown(context: context, dryRun: false)
    }
  }

  private func setup(
    context: Context,
    dryRun: Bool
  ) throws -> [SetupIntegrationResult] {
    var records = try readRecords(context: context)
    var results = [SetupIntegrationResult]()
    do {
      results.append(try setupKitty(context: context, dryRun: dryRun, records: &records))
      results.append(try setupBatSelector(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupBatThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupEzaEnvironment(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupEzaThemeLink(context: context, dryRun: dryRun, records: &records))
      return results
    } catch let error as SetupOwnershipTransactionError {
      throw SetupOwnershipTransactionError(wrapping: error, completedResults: results)
    } catch {
      guard results.contains(where: \.mutationAttempted) else { throw error }
      let failure = Self.failureResult(error, homeDirectory: context.homeDirectory)
      throw SetupOwnershipTransactionError(
        error,
        integrationID: failure.id,
        target: URL(filePath: failure.target),
        completedResults: results,
        failureMutationAttempted: false
      )
    }
  }

  private func setupKitty(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupRegularFile(
      id: Self.integrationID,
      target: context.kittyConfiguration,
      backupURL: context.backupURL,
      replacementName: context.replacementName,
      label: "Kitty include",
      read: { try readConfiguration($0) },
      isExternal: { try hasValidExternalInclude($0, context: context) },
      installedData: { addingLine($0, context.includeDirective) },
      externalOwnershipError: .kittyConfigurationIsExternallyOwned(context.kittyConfiguration),
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  private func setupBatSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    let exactLine = BatAdapter.themeDirective
    return try setupRegularFile(
      id: Self.batSelectorID,
      target: context.batConfiguration,
      backupURL: context.batSelectorBackup,
      replacementName: context.batSelectorReplacementName,
      label: "bat selector",
      read: { try readConfiguration($0, id: Self.batSelectorID) },
      isExternal: { data in
        try exactLineIsExternal(
          data,
          exactLine: exactLine,
          id: Self.batSelectorID,
          target: context.batConfiguration,
          isRelevantLine: { $0.hasPrefix("--theme=") || $0.hasPrefix("--theme ") }
        )
      },
      installedData: { addingLine($0, exactLine) },
      externalOwnershipError: .configurationIsExternallyOwned(
        Self.batSelectorID,
        context.batConfiguration
      ),
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  private func setupBatThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.batThemeLinkID,
      target: context.batThemeLink,
      destination: context.batThemeDestination,
      label: "bat theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  private func setupEzaEnvironment(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    let exactLine = EzaAdapter.environmentDirective(
      configurationDirectoryURL: context.ezaThemeLink.deletingLastPathComponent()
    )
    return try setupRegularFile(
      id: Self.ezaEnvironmentID,
      target: context.shellConfiguration,
      backupURL: context.ezaEnvironmentBackup,
      replacementName: context.ezaEnvironmentReplacementName,
      label: "eza environment",
      read: { try readConfiguration($0, id: Self.ezaEnvironmentID) },
      isExternal: { data in
        try exactLineIsExternal(
          data,
          exactLine: exactLine,
          id: Self.ezaEnvironmentID,
          target: context.shellConfiguration,
          isRelevantLine: Self.isEzaEnvironmentDirective
        )
      },
      installedData: { addingLine($0, exactLine) },
      externalOwnershipError: .configurationIsExternallyOwned(
        Self.ezaEnvironmentID,
        context.shellConfiguration
      ),
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  private func setupEzaThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.ezaThemeLinkID,
      target: context.ezaThemeLink,
      destination: context.ezaThemeDestination,
      label: "eza theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  private static func isEzaEnvironmentDirective(_ line: String) -> Bool {
    var assignment = line[...]
    let fields = assignment.split(
      maxSplits: 1,
      omittingEmptySubsequences: true,
      whereSeparator: { $0.isWhitespace }
    )
    if fields.first == "export" {
      guard fields.count == 2 else { return false }
      assignment = fields[1]
    }
    guard assignment.hasPrefix("EZA_CONFIG_DIR") else { return false }
    let suffix = assignment.dropFirst("EZA_CONFIG_DIR".count)
    guard let first = suffix.first else { return false }
    return first == "=" || first.isWhitespace
  }

  private func setupRegularFile(
    id: String,
    target: URL,
    backupURL: URL,
    replacementName: String,
    label: String,
    read: (URL) throws -> Data,
    isExternal: (Data) throws -> Bool,
    installedData: (Data) -> Data,
    externalOwnershipError: SetupOwnershipError,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if let record = records.first(where: { $0.id == id }) {
      return try resumeRegularFile(
        record: record,
        target: target,
        backupURL: backupURL,
        replacementName: replacementName,
        label: label,
        read: read,
        installedData: installedData,
        context: context,
        dryRun: dryRun,
        records: &records
      )
    }

    guard try itemExists(backupURL) == false else {
      throw SetupOwnershipError.orphanedBackup(backupURL)
    }
    let replacementURL = target.deletingLastPathComponent().appending(path: replacementName)
    guard try itemExists(replacementURL) == false else {
      throw SetupOwnershipError.orphanedReplacement(replacementURL)
    }
    let original = try read(target)
    if try isExternal(original) {
      return integrationResult(
        id: id,
        target: target,
        status: .external,
        message: "The exact \(label) is already externally owned"
      )
    }
    guard try pathContainsSymlink(target, below: context.homeDirectory) == false else {
      throw externalOwnershipError
    }

    let installed = installedData(original)
    if dryRun {
      return integrationResult(
        id: id,
        target: target,
        status: .planned,
        message: "Would back up the configuration and add the exact \(label)"
      )
    }

    let record = SetupOwnershipRecord(
      id: id,
      phase: .prepared,
      kind: .regularFile,
      targetPath: target.path,
      backupPath: relativePath(backupURL, below: context.stateRoot),
      originalDigest: sha256Digest(original),
      installedDigest: sha256Digest(installed),
      linkDestination: nil
    )
    do {
      try save(record: record, records: &records, context: context)
      try faultInjector(.manifestPrepared)
      try writeRegularBackup(original, record: record, backupURL: backupURL)
      try faultInjector(.backupWritten)
      try replaceRegularFile(
        target: target,
        replacementName: replacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: try requiredOriginalDigest(record),
        data: installed,
        label: label
      )
      try faultInjector(.targetWritten)
      try save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error, integrationID: id, target: target)
    }
    return integrationResult(
      id: id,
      target: target,
      status: .owned,
      message: "Added the \(label) and recorded Macarchy ownership",
      mutationAttempted: true
    )
  }

  private func resumeRegularFile(
    record: SetupOwnershipRecord,
    target: URL,
    backupURL: URL,
    replacementName: String,
    label: String,
    read: (URL) throws -> Data,
    installedData: (Data) -> Data,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try validateRegularFileRecord(record, target: target, backupURL: backupURL, context: context)
    let originalDigest = try requiredOriginalDigest(record)
    guard
      try regularFilePathContainsSymlink(id: record.id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let replacementResidueExists = try validateRegularReplacementResidue(
      record: record,
      target: target,
      replacementName: replacementName,
      context: context,
      remove: false,
      label: label
    )
    let current = try read(target)
    let digest = sha256Digest(current)

    if digest == record.installedDigest {
      let original = try readRegularBackup(record: record, backupURL: backupURL)
      guard sha256Digest(installedData(original)) == record.installedDigest else {
        throw SetupOwnershipError.invalidManifest(
          installedDigestError(recordID: record.id, label: label)
        )
      }
      if record.phase == .applied {
        if replacementResidueExists {
          if dryRun {
            return integrationResult(
              id: record.id,
              target: target,
              status: .planned,
              message: "Would remove the validated interrupted \(label) replacement"
            )
          }
          do {
            _ = try validateRegularReplacementResidue(
              record: record,
              target: target,
              replacementName: replacementName,
              context: context,
              remove: true,
              label: label
            )
          } catch {
            throw SetupOwnershipTransactionError(
              error, integrationID: record.id, target: target)
          }
          return integrationResult(
            id: record.id,
            target: target,
            status: .owned,
            message: "Removed the validated interrupted \(label) replacement",
            mutationAttempted: true
          )
        }
        return integrationResult(
          id: record.id,
          target: target,
          status: .owned,
          message: "The \(label) is Macarchy-owned and current"
        )
      }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: target,
          status: .planned,
          message: "Would finalize the interrupted \(label) ownership record"
        )
      }
      do {
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(error, integrationID: record.id, target: target)
      }
      return integrationResult(
        id: record.id,
        target: target,
        status: .owned,
        message: "Finalized the interrupted \(label) ownership record",
        mutationAttempted: true
      )
    }

    guard digest == originalDigest else { throw SetupOwnershipError.ownershipDrift(target) }
    if dryRun {
      return integrationResult(
        id: record.id,
        target: target,
        status: .planned,
        message: "Would resume the recorded \(label) change"
      )
    }

    let backupExists = try itemExists(backupURL)
    let original =
      backupExists ? try readRegularBackup(record: record, backupURL: backupURL) : current
    let installed = installedData(original)
    guard sha256Digest(installed) == record.installedDigest else {
      throw SetupOwnershipError.invalidManifest(
        installedDigestError(recordID: record.id, label: label)
      )
    }
    do {
      if replacementResidueExists {
        _ = try validateRegularReplacementResidue(
          record: record,
          target: target,
          replacementName: replacementName,
          context: context,
          remove: true,
          label: label
        )
      }
      if !backupExists {
        try writeRegularBackup(original, record: record, backupURL: backupURL)
      }
      try replaceRegularFile(
        target: target,
        replacementName: replacementName,
        homeDirectory: context.homeDirectory,
        expectedDigest: originalDigest,
        data: installed,
        label: label
      )
      try faultInjector(.targetWritten)
      try save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error, integrationID: record.id, target: target)
    }
    return integrationResult(
      id: record.id,
      target: target,
      status: .owned,
      message: "Resumed the recorded \(label) change",
      mutationAttempted: true
    )
  }

  private func setupThemeLink(
    id: String,
    target: URL,
    destination: URL,
    label: String,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if let record = records.first(where: { $0.id == id }) {
      return try resumeThemeLink(
        record: record,
        target: target,
        destination: destination,
        label: label,
        context: context,
        dryRun: dryRun,
        records: &records
      )
    }

    guard try themeLinkRemovalState(id: id, target: target) == .missing else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    switch try themeLinkState(id: id, url: target, target: target) {
    case .matching(let current) where current == destination.path:
      return integrationResult(
        id: id,
        target: target,
        status: .external,
        message: "The exact \(label) link is already externally owned"
      )
    case .missing:
      break
    case .matching, .other:
      throw SetupOwnershipError.conflictingThemeLink(id, target)
    }
    guard try themeLinkParentContainsSymlink(id: id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.configurationIsExternallyOwned(id, target)
    }
    if dryRun {
      return integrationResult(
        id: id,
        target: target,
        status: .planned,
        message: "Would create the exact \(label) canonical link"
      )
    }

    let record = SetupOwnershipRecord(
      id: id,
      phase: .prepared,
      kind: .symbolicLink,
      targetPath: target.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(destination.path.utf8)),
      linkDestination: destination.path
    )
    do {
      try save(record: record, records: &records, context: context)
      try faultInjector(.manifestPrepared)
      try createPinnedSymbolicLink(
        target: target,
        destination: destination,
        homeDirectory: context.homeDirectory,
        label: label
      )
      try faultInjector(.targetWritten)
      try save(record: record.applied, records: &records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error, integrationID: id, target: target)
    }
    return integrationResult(
      id: id,
      target: target,
      status: .owned,
      message: "Created the \(label) canonical link and recorded Macarchy ownership",
      mutationAttempted: true
    )
  }

  private func resumeThemeLink(
    record: SetupOwnershipRecord,
    target: URL,
    destination: URL,
    label: String,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try validateThemeLinkRecord(record, target: target, destination: destination)
    guard
      try themeLinkParentContainsSymlink(id: record.id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let state = try themeLinkState(id: record.id, url: target, target: target)
    let removalState = try themeLinkRemovalState(id: record.id, target: target)
    if case .matching(let current) = removalState, current == destination.path {
      guard state == .missing else { throw SetupOwnershipError.ownershipDrift(target) }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: target,
          status: .planned,
          message: "Would restore the interrupted \(label) link removal"
        )
      }
      do {
        try restorePinnedThemeLinkRemoval(
          id: record.id,
          target: target,
          destination: destination,
          homeDirectory: context.homeDirectory,
          label: label
        )
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(error, integrationID: record.id, target: target)
      }
      return integrationResult(
        id: record.id,
        target: target,
        status: .owned,
        message: "Restored the interrupted \(label) link removal",
        mutationAttempted: true
      )
    }
    guard removalState == .missing else { throw SetupOwnershipError.ownershipDrift(target) }
    switch state {
    case .matching(let current) where current == destination.path:
      if record.phase == .applied {
        return integrationResult(
          id: record.id,
          target: target,
          status: .owned,
          message: "The \(label) link is Macarchy-owned and current"
        )
      }
      if dryRun {
        return integrationResult(
          id: record.id,
          target: target,
          status: .planned,
          message: "Would finalize the interrupted \(label) link record"
        )
      }
      do {
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(error, integrationID: record.id, target: target)
      }
      return integrationResult(
        id: record.id,
        target: target,
        status: .owned,
        message: "Finalized the interrupted \(label) link record",
        mutationAttempted: true
      )
    case .missing:
      if dryRun {
        return integrationResult(
          id: record.id,
          target: target,
          status: .planned,
          message: "Would resume the recorded \(label) link creation"
        )
      }
      do {
        try createPinnedSymbolicLink(
          target: target,
          destination: destination,
          homeDirectory: context.homeDirectory,
          label: label
        )
        try faultInjector(.targetWritten)
        try save(record: record.applied, records: &records, context: context)
      } catch {
        throw SetupOwnershipTransactionError(error, integrationID: record.id, target: target)
      }
      return integrationResult(
        id: record.id,
        target: target,
        status: .owned,
        message: "Resumed the recorded \(label) link creation",
        mutationAttempted: true
      )
    case .matching, .other:
      throw SetupOwnershipError.ownershipDrift(target)
    }
  }

  private func teardown(context: Context, dryRun: Bool) throws -> [SetupIntegrationResult] {
    var records = try readRecords(context: context)
    if !dryRun {
      var preflightRecords = records
      _ = try teardownIntegrations(
        context: context,
        dryRun: true,
        records: &preflightRecords
      )
    }
    return try teardownIntegrations(context: context, dryRun: dryRun, records: &records)
  }

  private func teardownIntegrations(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    var reversed = [SetupIntegrationResult]()
    do {
      reversed.append(
        try teardownThemeLink(
          id: Self.ezaThemeLinkID,
          target: context.ezaThemeLink,
          destination: context.ezaThemeDestination,
          label: "eza",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      reversed.append(
        try teardownRegularFile(
          id: Self.ezaEnvironmentID,
          target: context.shellConfiguration,
          backupURL: context.ezaEnvironmentBackup,
          replacementName: context.ezaEnvironmentReplacementName,
          label: "eza environment",
          read: { try readConfiguration($0, id: Self.ezaEnvironmentID) },
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      reversed.append(
        try teardownThemeLink(
          id: Self.batThemeLinkID,
          target: context.batThemeLink,
          destination: context.batThemeDestination,
          label: "bat",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      reversed.append(
        try teardownRegularFile(
          id: Self.batSelectorID,
          target: context.batConfiguration,
          backupURL: context.batSelectorBackup,
          replacementName: context.batSelectorReplacementName,
          label: "bat selector",
          read: { try readConfiguration($0, id: Self.batSelectorID) },
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      reversed.append(
        try teardownRegularFile(
          id: Self.integrationID,
          target: context.kittyConfiguration,
          backupURL: context.backupURL,
          replacementName: context.replacementName,
          label: "Kitty include",
          read: { try readConfiguration($0) },
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      return reversed.reversed()
    } catch let error as SetupOwnershipTransactionError {
      throw SetupOwnershipTransactionError(
        wrapping: error,
        completedResults: Array(reversed.reversed())
      )
    } catch {
      let completed = Array(reversed.reversed())
      guard completed.contains(where: \.mutationAttempted) else { throw error }
      let failure = Self.failureResult(error, homeDirectory: context.homeDirectory)
      throw SetupOwnershipTransactionError(
        error,
        integrationID: failure.id,
        target: URL(filePath: failure.target),
        completedResults: completed,
        failureMutationAttempted: false
      )
    }
  }

  private func teardownRegularFile(
    id: String,
    target: URL,
    backupURL: URL,
    replacementName: String,
    label: String,
    read: (URL) throws -> Data,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    guard let record = records.first(where: { $0.id == id }) else {
      return integrationResult(
        id: id,
        target: target,
        status: .none,
        message: "No Macarchy-owned \(label) exists"
      )
    }
    try validateRegularFileRecord(record, target: target, backupURL: backupURL, context: context)
    let originalDigest = try requiredOriginalDigest(record)
    guard try regularFilePathContainsSymlink(id: id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let replacementResidueExists = try validateRegularReplacementResidue(
      record: record,
      target: target,
      replacementName: replacementName,
      context: context,
      remove: false,
      label: label
    )
    let current = try read(target)
    let digest = sha256Digest(current)
    guard digest == record.installedDigest || digest == originalDigest else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let original =
      digest == record.installedDigest
      ? try readRegularBackup(record: record, backupURL: backupURL) : nil
    _ = try validateRegularFileIfPresent(backupURL, unsafe: .corruptBackup(backupURL))
    if dryRun {
      return integrationResult(
        id: id,
        target: target,
        status: .planned,
        message:
          digest == record.installedDigest
          ? "Would restore the backed-up \(label) configuration"
          : "Would clear the already-reverted \(label) ownership record"
      )
    }

    do {
      if replacementResidueExists {
        _ = try validateRegularReplacementResidue(
          record: record,
          target: target,
          replacementName: replacementName,
          context: context,
          remove: true,
          label: label
        )
      }
      if let original {
        try faultInjector(.teardownReady)
        try replaceRegularFile(
          target: target,
          replacementName: replacementName,
          homeDirectory: context.homeDirectory,
          expectedDigest: record.installedDigest,
          data: original,
          label: label
        )
      }
      try removeRegularFileIfPresent(backupURL, unsafe: .corruptBackup(backupURL))
      records.removeAll { $0.id == id }
      try persist(records: records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error, integrationID: id, target: target)
    }
    return integrationResult(
      id: id,
      target: target,
      status: .removed,
      message: "Removed only the recorded Macarchy-owned \(label)",
      mutationAttempted: true
    )
  }

  private func teardownThemeLink(
    id: String,
    target: URL,
    destination: URL,
    label: String,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    guard let record = records.first(where: { $0.id == id }) else {
      return integrationResult(
        id: id,
        target: target,
        status: .none,
        message: "No Macarchy-owned \(label) link exists"
      )
    }
    try validateThemeLinkRecord(record, target: target, destination: destination)
    guard try themeLinkParentContainsSymlink(id: id, target: target, context: context) == false
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let state = try themeLinkState(id: id, url: target, target: target)
    let removalState = try themeLinkRemovalState(id: id, target: target)
    let removalClaimed: Bool
    switch (state, removalState) {
    case (.matching(let current), .missing) where current == destination.path:
      removalClaimed = false
    case (.missing, .matching(let current)) where current == destination.path:
      removalClaimed = true
    case (.missing, .missing):
      removalClaimed = false
    default:
      throw SetupOwnershipError.ownershipDrift(target)
    }
    if dryRun {
      return integrationResult(
        id: id,
        target: target,
        status: .planned,
        message:
          removalClaimed
          ? "Would finish the interrupted \(label) link removal"
          : state == .missing
            ? "Would clear the already-removed \(label) link record"
            : "Would remove the recorded \(label) canonical link"
      )
    }

    do {
      if state != .missing || removalClaimed {
        try faultInjector(.teardownReady)
        try removePinnedSymbolicLink(
          id: id,
          target: target,
          destination: destination,
          homeDirectory: context.homeDirectory,
          label: label,
          alreadyClaimed: removalClaimed
        )
      }
      records.removeAll { $0.id == id }
      try persist(records: records, context: context)
    } catch {
      throw SetupOwnershipTransactionError(error, integrationID: id, target: target)
    }
    return integrationResult(
      id: id,
      target: target,
      status: .removed,
      message: "Removed only the recorded Macarchy-owned \(label) link",
      mutationAttempted: true
    )
  }

  private func readRecords(context: Context) throws -> [SetupOwnershipRecord] {
    guard try itemExists(context.manifestURL) else { return [] }
    let data: Data
    do {
      data = try BoundedRegularFile.read(
        at: context.manifestURL,
        maximumSize: 65_536
      ).data
    } catch {
      throw SetupOwnershipError.system(
        "read", context.manifestURL, String(describing: error))
    }
    let manifest: SetupOwnershipManifest
    do {
      try validateManifestKeys(data)
      manifest = try JSONDecoder().decode(SetupOwnershipManifest.self, from: data)
    } catch {
      throw SetupOwnershipError.invalidManifest(String(describing: error))
    }
    guard manifest.schemaVersion == SetupOwnershipManifest.currentSchemaVersion else {
      throw SetupOwnershipError.invalidManifest(
        "unsupported schema version \(manifest.schemaVersion)"
      )
    }
    guard Set(manifest.records.map(\.id)).count == manifest.records.count else {
      throw SetupOwnershipError.invalidManifest("integration identifiers must be unique")
    }
    for record in manifest.records {
      switch record.id {
      case Self.integrationID:
        try validateRegularFileRecord(
          record,
          target: context.kittyConfiguration,
          backupURL: context.backupURL,
          context: context
        )
      case Self.batSelectorID:
        try validateRegularFileRecord(
          record,
          target: context.batConfiguration,
          backupURL: context.batSelectorBackup,
          context: context
        )
      case Self.batThemeLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.batThemeLink,
          destination: context.batThemeDestination
        )
      case Self.ezaEnvironmentID:
        try validateRegularFileRecord(
          record,
          target: context.shellConfiguration,
          backupURL: context.ezaEnvironmentBackup,
          context: context
        )
      case Self.ezaThemeLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.ezaThemeLink,
          destination: context.ezaThemeDestination
        )
      default:
        throw SetupOwnershipError.invalidManifest("unknown integration \(record.id)")
      }
    }
    return manifest.records
  }

  private func validateManifestKeys(_ data: Data) throws {
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: data)
    } catch {
      return
    }
    guard let manifest = value as? [String: Any] else { return }
    let manifestKeys = Set(SetupOwnershipManifest.CodingKeys.allCases.map(\.stringValue))
    let unknownManifestKeys = Set(manifest.keys).subtracting(manifestKeys)
    guard unknownManifestKeys.isEmpty else {
      throw SetupOwnershipError.invalidManifest(
        "unknown manifest fields: \(unknownManifestKeys.sorted().joined(separator: ", "))"
      )
    }
    guard let records = manifest["records"] as? [[String: Any]] else { return }
    let recordKeys = Set(SetupOwnershipRecord.CodingKeys.allCases.map(\.stringValue))
    for (index, record) in records.enumerated() {
      let unknownRecordKeys = Set(record.keys).subtracting(recordKeys)
      guard unknownRecordKeys.isEmpty else {
        throw SetupOwnershipError.invalidManifest(
          "unknown fields in record \(index): \(unknownRecordKeys.sorted().joined(separator: ", "))"
        )
      }
    }
  }

  private func save(
    record: SetupOwnershipRecord,
    records: inout [SetupOwnershipRecord],
    context: Context
  ) throws {
    records.removeAll { $0.id == record.id }
    records.append(record)
    records.sort { $0.id < $1.id }
    try persist(records: records, context: context)
  }

  private func persist(records: [SetupOwnershipRecord], context: Context) throws {
    if records.isEmpty {
      try removeRegularFileIfPresent(
        context.manifestURL,
        unsafe: .invalidManifest("ownership path is not an ordinary file")
      )
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: context.manifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(SetupOwnershipManifest(records: records)).write(
        to: context.manifestURL,
        options: .atomic
      )
    } catch {
      throw SetupOwnershipError.system(
        "write", context.manifestURL, String(describing: error))
    }
  }

  private func requiredOriginalDigest(_ record: SetupOwnershipRecord) throws -> String {
    guard let digest = record.originalDigest else {
      throw SetupOwnershipError.invalidManifest("regular-file record is missing original digest")
    }
    return digest
  }

  private func installedDigestError(recordID: String, label: String) -> String {
    recordID == Self.integrationID
      ? "Kitty installed digest cannot be reproduced"
      : "\(label) digest cannot be reproduced"
  }

  private func validateRegularFileRecord(
    _ record: SetupOwnershipRecord,
    target: URL,
    backupURL: URL,
    context: Context
  ) throws {
    guard record.kind == .regularFile, record.targetPath == target.path else {
      throw SetupOwnershipError.invalidManifest("\(record.id) target is not allowlisted")
    }
    guard record.backupPath == relativePath(backupURL, below: context.stateRoot) else {
      throw SetupOwnershipError.invalidManifest("\(record.id) backup is not allowlisted")
    }
    guard record.linkDestination == nil else {
      throw SetupOwnershipError.invalidManifest("\(record.id) cannot own a symbolic link")
    }
    _ = try requiredOriginalDigest(record)
  }

  private func validateThemeLinkRecord(
    _ record: SetupOwnershipRecord,
    target: URL,
    destination: URL
  ) throws {
    guard record.kind == .symbolicLink, record.targetPath == target.path else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link target is not allowlisted")
    }
    guard record.backupPath == nil, record.originalDigest == nil else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link cannot contain backup state")
    }
    guard record.linkDestination == destination.path else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link destination is not allowlisted")
    }
    guard record.installedDigest == sha256Digest(Data(destination.path.utf8)) else {
      throw SetupOwnershipError.invalidManifest("\(record.id) link digest is invalid")
    }
  }

  private func readConfiguration(_ url: URL, id: String) throws -> Data {
    var metadata = stat()
    guard stat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      throw SetupOwnershipError.missingConfiguration(id, url)
    }
    let data: Data
    do {
      data = try BoundedRegularFile.read(
        at: url.resolvingSymlinksInPath(),
        maximumSize: Self.maximumConfigurationSize
      ).data
    } catch BoundedRegularFileError.tooLarge {
      throw SetupOwnershipError.configurationTooLarge(id, url)
    } catch {
      throw SetupOwnershipError.system("read", url, String(describing: error))
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw SetupOwnershipError.unreadableConfiguration(id, url)
    }
    return data
  }

  private func configurationLines(_ data: Data) -> [String] {
    String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  private func exactLineIsExternal(
    _ data: Data,
    exactLine: String,
    id: String,
    target: URL,
    isRelevantLine: (String) -> Bool
  ) throws -> Bool {
    let relevant = configurationLines(data).filter(isRelevantLine)
    if relevant == [exactLine] { return true }
    guard relevant.isEmpty else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return false
  }

  private func addingLine(_ original: Data, _ line: String) -> Data {
    var configuration = String(decoding: original, as: UTF8.self)
    if !configuration.isEmpty, !configuration.hasSuffix("\n") {
      configuration.append("\n")
    }
    configuration.append("\(line)\n")
    return Data(configuration.utf8)
  }

  private func relativePath(_ url: URL, below root: URL) -> String {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    precondition(url.path.hasPrefix(prefix))
    return String(url.path.dropFirst(prefix.count))
  }

  private func readRegularBackup(
    record: SetupOwnershipRecord,
    backupURL: URL
  ) throws -> Data {
    let backup: BoundedRegularFile
    do {
      backup = try BoundedRegularFile.read(
        at: backupURL,
        maximumSize: Self.maximumConfigurationSize
      )
    } catch {
      throw SetupOwnershipError.corruptBackup(backupURL)
    }
    guard
      backup.permissions == 0o600,
      sha256Digest(backup.data) == (try requiredOriginalDigest(record))
    else {
      throw SetupOwnershipError.corruptBackup(backupURL)
    }
    return backup.data
  }

  private func writeRegularBackup(
    _ data: Data,
    record: SetupOwnershipRecord,
    backupURL: URL
  ) throws {
    guard sha256Digest(data) == (try requiredOriginalDigest(record)) else {
      throw SetupOwnershipError.invalidManifest(
        "\(record.id) original digest changed before backup")
    }
    do {
      try FileManager.default.createDirectory(
        at: backupURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      throw SetupOwnershipError.system(
        "create backup directory", backupURL, String(describing: error))
    }

    let safeID = record.id.replacingOccurrences(of: ".", with: "-")
    let temporary = backupURL.deletingLastPathComponent()
      .appending(path: ".\(safeID)-backup-\(UUID().uuidString).tmp")
    let descriptor = temporary.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else { throw posixError("create temporary backup", temporary) }
    defer { Darwin.close(descriptor) }
    var published = false
    defer {
      if !published { _ = Darwin.unlink(temporary.path) }
    }
    try write(
      data,
      descriptor: descriptor,
      url: temporary,
      operation: "write temporary \(record.id) backup"
    )
    guard fsync(descriptor) == 0 else { throw posixError("sync temporary backup", temporary) }
    let publication = temporary.path.withCString { source in
      backupURL.path.withCString { destination in
        Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
      }
    }
    guard publication == 0 else { throw posixError("publish backup", backupURL) }
    published = true
    _ = try readRegularBackup(record: record, backupURL: backupURL)
  }

  private func validateRegularReplacementResidue(
    record: SetupOwnershipRecord,
    target: URL,
    replacementName: String,
    context: Context,
    remove: Bool,
    label: String
  ) throws -> Bool {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: context.homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let replacementURL = target.deletingLastPathComponent().appending(path: replacementName)
    let residueDescriptor = replacementName.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    if residueDescriptor < 0, errno == ENOENT { return false }
    guard residueDescriptor >= 0 else {
      throw posixError("open replacement residue", replacementURL)
    }
    defer { Darwin.close(residueDescriptor) }

    let residue = try readPinnedRegularFile(
      descriptor: residueDescriptor,
      url: replacementURL,
      label: label
    )
    let current = try readPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: target.lastPathComponent,
      url: target,
      label: label
    )
    let currentDigest = sha256Digest(current.data)
    let residueDigest = sha256Digest(residue.data)
    let originalDigest = try requiredOriginalDigest(record)
    guard
      (currentDigest == record.installedDigest && residueDigest == originalDigest)
        || (currentDigest == originalDigest && residueDigest == record.installedDigest)
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    if remove {
      guard replacementName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
        throw posixError("remove replacement residue", replacementURL)
      }
    }
    return true
  }

  private func replaceRegularFile(
    target: URL,
    replacementName: String,
    homeDirectory: URL,
    expectedDigest: String,
    data: Data,
    label: String
  ) throws {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let targetName = target.lastPathComponent
    let currentDescriptor = try openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: targetName,
      url: target,
      label: label
    )
    defer { Darwin.close(currentDescriptor) }
    let current = try readPinnedRegularFile(
      descriptor: currentDescriptor, url: target, label: label)
    let originalSnapshot = try regularFileSnapshot(
      descriptor: currentDescriptor,
      url: target,
      label: label
    )
    guard sha256Digest(current.data) == expectedDigest else {
      throw SetupOwnershipError.ownershipDrift(target)
    }

    let temporaryDescriptor = replacementName.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
    }
    guard temporaryDescriptor >= 0 else { throw posixError("create temporary \(label)", target) }
    defer { Darwin.close(temporaryDescriptor) }
    var cleanupTemporary = true
    defer {
      if cleanupTemporary {
        _ = replacementName.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
      }
    }

    try write(
      data,
      descriptor: temporaryDescriptor,
      url: target,
      operation: "write temporary \(label) configuration"
    )
    guard fsync(temporaryDescriptor) == 0 else { throw posixError("sync \(label)", target) }
    guard
      fcopyfile(
        currentDescriptor,
        temporaryDescriptor,
        nil,
        copyfile_flags_t(COPYFILE_METADATA)
      ) == 0
    else {
      throw posixError("copy \(label) metadata", target)
    }
    guard fsync(temporaryDescriptor) == 0 else {
      throw posixError("sync \(label) metadata", target)
    }
    try faultInjector(.replacementReady)
    let recheckedDescriptor = try openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: targetName,
      url: target,
      label: label
    )
    defer { Darwin.close(recheckedDescriptor) }
    let rechecked = try readPinnedRegularFile(
      descriptor: recheckedDescriptor,
      url: target,
      label: label
    )
    let recheckedSnapshot = try regularFileSnapshot(
      descriptor: recheckedDescriptor,
      url: target,
      label: label
    )
    guard
      sha256Digest(rechecked.data) == expectedDigest,
      recheckedSnapshot == originalSnapshot
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    guard swap(parentDescriptor: parentDescriptor, first: replacementName, second: targetName) == 0
    else {
      throw posixError("replace \(label)", target)
    }
    do {
      try faultInjector(.replacementSwapped)
    } catch {
      cleanupTemporary = false
      throw error
    }

    let displaced: BoundedRegularFile
    let displacedSnapshot: RegularFileSnapshot
    do {
      let displacedDescriptor = try openPinnedRegularFile(
        parentDescriptor: parentDescriptor,
        name: replacementName,
        url: target.deletingLastPathComponent().appending(path: replacementName),
        label: label
      )
      defer { Darwin.close(displacedDescriptor) }
      displaced = try readPinnedRegularFile(
        descriptor: displacedDescriptor,
        url: target.deletingLastPathComponent().appending(path: replacementName),
        label: label
      )
      displacedSnapshot = try regularFileSnapshot(
        descriptor: displacedDescriptor,
        url: target.deletingLastPathComponent().appending(path: replacementName),
        label: label
      )
    } catch {
      let restored = swap(
        parentDescriptor: parentDescriptor,
        first: replacementName,
        second: targetName
      )
      guard restored == 0 else {
        cleanupTemporary = false
        throw posixError("restore concurrently changed \(label)", target)
      }
      throw error
    }
    guard
      sha256Digest(displaced.data) == expectedDigest,
      originalSnapshot.matchesDisplaced(displacedSnapshot)
    else {
      let restored = swap(
        parentDescriptor: parentDescriptor,
        first: replacementName,
        second: targetName
      )
      guard restored == 0 else {
        cleanupTemporary = false
        throw posixError("restore concurrently changed \(label)", target)
      }
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let installedDescriptor = try openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: targetName,
      url: target,
      label: label
    )
    defer { Darwin.close(installedDescriptor) }
    let installed = try readPinnedRegularFile(
      descriptor: installedDescriptor,
      url: target,
      label: label
    )
    let installedSnapshot = try regularFileSnapshot(
      descriptor: installedDescriptor,
      url: target,
      label: label
    )
    if sha256Digest(installed.data) != sha256Digest(data)
      || !installedSnapshot.hasCopiedMetadata(from: originalSnapshot)
    {
      let restored = swap(
        parentDescriptor: parentDescriptor,
        first: replacementName,
        second: targetName
      )
      guard restored == 0 else {
        cleanupTemporary = false
        throw posixError("restore concurrently changed \(label)", target)
      }
      throw SetupOwnershipError.ownershipDrift(target)
    }
    cleanupTemporary = false
    guard replacementName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
      throw posixError("remove displaced \(label)", target)
    }
  }

  private func openPinnedParent(
    target: URL,
    homeDirectory: URL,
    label: String
  ) throws -> Int32 {
    let home = homeDirectory.standardizedFileURL
    let target = target.standardizedFileURL
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard target.path.hasPrefix(prefix) else {
      throw SetupOwnershipError.invalidManifest("\(label) target is outside the selected home")
    }
    let parent = target.deletingLastPathComponent()
    let relativeParent =
      parent.path == home.path ? ""[...] : parent.path.dropFirst(prefix.count)
    var descriptor = home.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw posixError("open home directory", home) }
    var candidate = home
    for component in relativeParent.split(separator: "/") {
      candidate.append(path: String(component))
      let next = component.withCString {
        Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      }
      let code = errno
      Darwin.close(descriptor)
      guard next >= 0 else {
        throw posixError("open pinned \(label) directory", candidate, code: code)
      }
      descriptor = next
    }
    return descriptor
  }

  private func openPinnedRegularFile(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    label: String
  ) throws -> Int32 {
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw posixError("open pinned \(label)", url) }
    return descriptor
  }

  private func readPinnedRegularFile(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    label: String
  ) throws -> BoundedRegularFile {
    let descriptor = try openPinnedRegularFile(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url,
      label: label
    )
    defer { Darwin.close(descriptor) }
    return try readPinnedRegularFile(descriptor: descriptor, url: url, label: label)
  }

  private func readPinnedRegularFile(
    descriptor: Int32,
    url: URL,
    label: String
  ) throws -> BoundedRegularFile {
    do {
      return try BoundedRegularFile.read(
        descriptor: descriptor,
        maximumSize: Self.maximumConfigurationSize
      )
    } catch {
      throw SetupOwnershipError.system("read pinned \(label)", url, String(describing: error))
    }
  }

  private func regularFileSnapshot(
    descriptor: Int32,
    url: URL,
    label: String
  ) throws -> RegularFileSnapshot {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw posixError("inspect pinned \(label) metadata", url)
    }
    return try RegularFileSnapshot(
      metadata: metadata,
      extendedAttributes: extendedAttributes(
        descriptor: descriptor,
        url: url,
        label: label
      )
    )
  }

  private func extendedAttributes(
    descriptor: Int32,
    url: URL,
    label: String
  ) throws -> [String: Data] {
    let size = Darwin.flistxattr(descriptor, nil, 0, 0)
    guard size >= 0 else { throw posixError("list pinned \(label) attributes", url) }
    guard size > 0 else { return [:] }
    var names = [CChar](repeating: 0, count: size)
    let count = Darwin.flistxattr(descriptor, &names, names.count, 0)
    guard count == size else { throw posixError("read pinned \(label) attribute names", url) }

    var attributes = [String: Data]()
    let bytes = names.prefix(count).map { UInt8(bitPattern: $0) }
    for nameBytes in bytes.split(separator: 0) {
      guard let name = String(bytes: nameBytes, encoding: .utf8) else {
        throw SetupOwnershipError.system(
          "read pinned \(label) attribute names",
          url,
          "attribute name is not UTF-8"
        )
      }
      let valueSize = name.withCString {
        Darwin.fgetxattr(descriptor, $0, nil, 0, 0, 0)
      }
      guard valueSize >= 0 else { throw posixError("inspect pinned \(label) attribute", url) }
      var value = Data(count: valueSize)
      let valueCount = value.withUnsafeMutableBytes { bytes in
        name.withCString {
          Darwin.fgetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
      guard valueCount == valueSize else {
        throw posixError("read pinned \(label) attribute", url)
      }
      attributes[name] = value
    }
    return attributes
  }

  private func readConfiguration(_ url: URL) throws -> Data {
    var metadata = stat()
    guard stat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      throw SetupOwnershipError.missingKittyConfiguration(url)
    }
    let data: Data
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      data = try handle.read(upToCount: Self.maximumConfigurationSize + 1) ?? Data()
    } catch {
      throw SetupOwnershipError.system("read", url, String(describing: error))
    }
    guard data.count <= Self.maximumConfigurationSize else {
      throw SetupOwnershipError.kittyConfigurationTooLarge(url)
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw SetupOwnershipError.unreadableKittyConfiguration(url)
    }
    return data
  }

  private func swap(parentDescriptor: Int32, first: String, second: String) -> Int32 {
    first.withCString { firstPath in
      second.withCString { secondPath in
        Darwin.renameatx_np(
          parentDescriptor,
          firstPath,
          parentDescriptor,
          secondPath,
          UInt32(RENAME_SWAP)
        )
      }
    }
  }

  private func write(
    _ data: Data,
    descriptor: Int32,
    url: URL,
    operation: String
  ) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          throw posixError(operation, url)
        }
        guard count > 0 else {
          throw SetupOwnershipError.system(
            operation, url, "write returned zero bytes"
          )
        }
        offset += count
      }
    }
  }

  private func posixError(
    _ operation: String,
    _ url: URL,
    code: Int32 = errno
  ) -> SetupOwnershipError {
    .system(operation, url, String(cString: strerror(code)))
  }

  private func removeRegularFileIfPresent(
    _ url: URL,
    unsafe error: SetupOwnershipError
  ) throws {
    guard try validateRegularFileIfPresent(url, unsafe: error) else { return }
    guard Darwin.unlink(url.path) == 0 else {
      throw posixError("remove setup state", url)
    }
  }

  private func validateRegularFileIfPresent(
    _ url: URL,
    unsafe error: SetupOwnershipError
  ) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) != 0 {
      if errno == ENOENT { return false }
      throw posixError("inspect setup state for removal", url)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else { throw error }
    return true
  }

  private func itemExists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return true }
    if errno == ENOENT { return false }
    throw SetupOwnershipError.system(
      "inspect", url, String(cString: strerror(errno))
    )
  }

  private func hasValidExternalInclude(_ data: Data, context: Context) throws -> Bool {
    let configuration = String(decoding: data, as: UTF8.self)
    let targets = configuration.components(separatedBy: .newlines).compactMap { line in
      includeTarget(line, context: context)
    }
    let macarchyTargets = targets.filter { target in
      target.path == context.stateRoot.path
        || target.path.hasPrefix(context.stateRoot.path + "/")
    }
    let expectedCount = macarchyTargets.count { $0.path == context.bridgeURL.path }
    if expectedCount > 1 || macarchyTargets.count != expectedCount {
      throw SetupOwnershipError.conflictingKittyInclude(context.kittyConfiguration)
    }
    return expectedCount == 1
  }

  private func includeTarget(_ line: String, context: Context) -> URL? {
    let fields = line.split(
      maxSplits: 1,
      omittingEmptySubsequences: true,
      whereSeparator: { $0.isWhitespace }
    )
    guard fields.count == 2, fields[0] == "include" else { return nil }
    var path = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    if (path.hasPrefix("\"") && path.hasSuffix("\""))
      || (path.hasPrefix("'") && path.hasSuffix("'"))
    {
      path.removeFirst()
      path.removeLast()
    }
    if path.hasPrefix("~/") {
      return context.homeDirectory.appending(path: String(path.dropFirst(2))).standardizedFileURL
    }
    if path.hasPrefix("/") {
      return URL(filePath: path).standardizedFileURL
    }
    return context.kittyConfiguration.deletingLastPathComponent()
      .appending(path: path).standardizedFileURL
  }

  private func pathContainsSymlink(_ target: URL, below home: URL) throws -> Bool {
    let home = home.standardizedFileURL
    let target = target.standardizedFileURL
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard target.path.hasPrefix(prefix) else {
      throw SetupOwnershipError.invalidManifest("integration target is outside the selected home")
    }

    let relative = String(target.path.dropFirst(prefix.count))
    var candidate = home
    for component in relative.split(separator: "/") {
      candidate.append(path: String(component))
      var metadata = stat()
      guard lstat(candidate.path, &metadata) == 0 else {
        let cause = String(cString: strerror(errno))
        throw SetupOwnershipError.system("inspect", candidate, cause)
      }
      if metadata.st_mode & S_IFMT == S_IFLNK { return true }
    }
    return false
  }

  private func regularFilePathContainsSymlink(
    id: String,
    target: URL,
    context: Context
  ) throws -> Bool {
    do {
      return try pathContainsSymlink(target, below: context.homeDirectory)
    } catch SetupOwnershipError.system(let operation, _, let cause) {
      throw SetupOwnershipError.system("\(operation) for \(id)", target, cause)
    }
  }

  private func parentPathContainsSymlink(_ target: URL, below home: URL) throws -> Bool {
    let parent = target.deletingLastPathComponent()
    let home = home.standardizedFileURL
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard parent.path == home.path || parent.path.hasPrefix(prefix) else {
      throw SetupOwnershipError.invalidManifest("integration target is outside the selected home")
    }
    let relative = parent.path == home.path ? "" : String(parent.path.dropFirst(prefix.count))
    var candidate = home
    for component in relative.split(separator: "/") {
      candidate.append(path: String(component))
      var metadata = stat()
      guard lstat(candidate.path, &metadata) == 0 else {
        throw posixError("inspect integration parent", candidate)
      }
      if metadata.st_mode & S_IFMT == S_IFLNK { return true }
      guard metadata.st_mode & S_IFMT == S_IFDIR else {
        throw SetupOwnershipError.system("inspect integration parent", candidate, "not a directory")
      }
    }
    return false
  }

  private enum SymbolicLinkState: Equatable {
    case matching(String)
    case missing
    case other
  }

  private func symbolicLinkState(_ url: URL) throws -> SymbolicLinkState {
    var metadata = stat()
    if lstat(url.path, &metadata) != 0 {
      if errno == ENOENT { return .missing }
      throw posixError("inspect theme link", url)
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK else { return .other }
    do {
      return .matching(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
    } catch {
      throw SetupOwnershipError.system("read theme link", url, String(describing: error))
    }
  }

  private func themeLinkState(id: String, url: URL, target: URL) throws -> SymbolicLinkState {
    do {
      return try symbolicLinkState(url)
    } catch SetupOwnershipError.system(let operation, _, let cause) {
      throw SetupOwnershipError.system("\(operation) for \(id)", target, cause)
    }
  }

  private func themeLinkRemovalURL(id: String, target: URL) -> URL {
    let safeID = id.replacingOccurrences(of: ".", with: "-")
    return target.deletingLastPathComponent()
      .appending(path: ".macarchy-\(safeID)-removal")
  }

  private func themeLinkRemovalState(id: String, target: URL) throws -> SymbolicLinkState {
    try themeLinkState(
      id: id,
      url: themeLinkRemovalURL(id: id, target: target),
      target: target
    )
  }

  private func themeLinkParentContainsSymlink(
    id: String,
    target: URL,
    context: Context
  ) throws -> Bool {
    do {
      return try parentPathContainsSymlink(target, below: context.homeDirectory)
    } catch SetupOwnershipError.system(let operation, _, let cause) {
      throw SetupOwnershipError.system("\(operation) for \(id)", target, cause)
    }
  }

  private func createPinnedSymbolicLink(
    target: URL,
    destination: URL,
    homeDirectory: URL,
    label: String
  ) throws {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let name = target.lastPathComponent
    var metadata = stat()
    let inspection = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard inspection != 0, errno == ENOENT else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    let created = destination.path.withCString { destinationPath in
      name.withCString { namePath in
        Darwin.symlinkat(destinationPath, parentDescriptor, namePath)
      }
    }
    guard created == 0 else { throw posixError("create \(label) link", target) }
    guard
      try readPinnedSymbolicLink(parentDescriptor: parentDescriptor, name: name, url: target)
        == destination.path
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    guard fsync(parentDescriptor) == 0 else { throw posixError("sync \(label) link", target) }
  }

  private func removePinnedSymbolicLink(
    id: String,
    target: URL,
    destination: URL,
    homeDirectory: URL,
    label: String,
    alreadyClaimed: Bool
  ) throws {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let name = target.lastPathComponent
    let removalURL = themeLinkRemovalURL(id: id, target: target)
    let removalName = removalURL.lastPathComponent
    if !alreadyClaimed {
      let claimed = name.withCString { source in
        removalName.withCString { claimed in
          Darwin.renameatx_np(
            parentDescriptor,
            source,
            parentDescriptor,
            claimed,
            UInt32(RENAME_EXCL)
          )
        }
      }
      guard claimed == 0 else {
        throw SetupOwnershipError.ownershipDrift(target)
      }
    }

    let claimedLinkMatches: Bool
    do {
      claimedLinkMatches = try pinnedSymbolicLinkMatches(
        parentDescriptor: parentDescriptor,
        name: removalName,
        url: removalURL,
        destination: destination.path
      )
    } catch {
      if !alreadyClaimed {
        try restorePinnedThemeLinkClaim(
          parentDescriptor: parentDescriptor,
          removalName: removalName,
          targetName: name,
          removalURL: removalURL,
          target: target,
          label: label
        )
      }
      throw error
    }
    guard claimedLinkMatches else {
      if !alreadyClaimed {
        try restorePinnedThemeLinkClaim(
          parentDescriptor: parentDescriptor,
          removalName: removalName,
          targetName: name,
          removalURL: removalURL,
          target: target,
          label: label
        )
      }
      throw SetupOwnershipError.ownershipDrift(target)
    }
    guard removalName.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
      throw posixError("remove claimed \(label) link", removalURL)
    }
    guard fsync(parentDescriptor) == 0 else {
      throw posixError("sync removed \(label) link", target)
    }
  }

  private func restorePinnedThemeLinkRemoval(
    id: String,
    target: URL,
    destination: URL,
    homeDirectory: URL,
    label: String
  ) throws {
    let parentDescriptor = try openPinnedParent(
      target: target,
      homeDirectory: homeDirectory,
      label: label
    )
    defer { Darwin.close(parentDescriptor) }
    let name = target.lastPathComponent
    let removalURL = themeLinkRemovalURL(id: id, target: target)
    let removalName = removalURL.lastPathComponent
    guard
      try pinnedSymbolicLinkMatches(
        parentDescriptor: parentDescriptor,
        name: removalName,
        url: removalURL,
        destination: destination.path
      )
    else {
      throw SetupOwnershipError.ownershipDrift(target)
    }
    try restorePinnedThemeLinkClaim(
      parentDescriptor: parentDescriptor,
      removalName: removalName,
      targetName: name,
      removalURL: removalURL,
      target: target,
      label: label
    )
  }

  private func restorePinnedThemeLinkClaim(
    parentDescriptor: Int32,
    removalName: String,
    targetName: String,
    removalURL: URL,
    target: URL,
    label: String
  ) throws {
    let restored = removalName.withCString { source in
      targetName.withCString { restored in
        Darwin.renameatx_np(
          parentDescriptor,
          source,
          parentDescriptor,
          restored,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard restored == 0 else {
      throw posixError("restore concurrently replaced \(label) link", removalURL)
    }
    guard fsync(parentDescriptor) == 0 else {
      throw posixError("sync restored \(label) link", target)
    }
  }

  private func pinnedSymbolicLinkMatches(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    destination: String
  ) throws -> Bool {
    var metadata = stat()
    let inspection = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard inspection == 0 else { throw posixError("inspect claimed theme link", url) }
    guard metadata.st_mode & S_IFMT == S_IFLNK else { return false }
    return try readPinnedSymbolicLink(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    ) == destination
  }

  private func readPinnedSymbolicLink(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = name.withCString {
      Darwin.readlinkat(parentDescriptor, $0, &buffer, buffer.count - 1)
    }
    guard count >= 0 else { throw posixError("read pinned theme link", url) }
    let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    guard let destination = String(bytes: bytes, encoding: .utf8) else {
      throw SetupOwnershipError.system("read pinned theme link", url, "destination is not UTF-8")
    }
    return destination
  }

  private func integrationResult(
    id: String,
    target: URL,
    status: SetupIntegrationResult.Status,
    message: String,
    mutationAttempted: Bool = false
  ) -> SetupIntegrationResult {
    SetupIntegrationResult(
      id: id,
      status: status,
      target: target.path,
      message: message,
      mutationAttempted: mutationAttempted
    )
  }

  private struct Context {
    let homeDirectory: URL
    let stateRoot: URL
    let kittyConfiguration: URL
    let batConfiguration: URL
    let batThemeLink: URL
    let batThemeDestination: URL
    let shellConfiguration: URL
    let ezaThemeLink: URL
    let ezaThemeDestination: URL
    let includeDirective: String
    let manifestURL: URL
    let backupRelativePath = "state/setup/backups/kitty.conf"
    let batSelectorBackupRelativePath = "state/setup/backups/bat-config"
    let ezaEnvironmentBackupRelativePath = "state/setup/backups/zshrc"

    init(homeDirectory: URL) {
      let homeDirectory = homeDirectory.standardizedFileURL
      let stateRoot = homeDirectory.appending(
        path: ".config/macarchy", directoryHint: .isDirectory)
      self.homeDirectory = homeDirectory
      self.stateRoot = stateRoot
      kittyConfiguration = homeDirectory.appending(path: ".config/kitty/kitty.conf")
      batConfiguration = homeDirectory.appending(path: ".config/bat/config")
      batThemeLink = homeDirectory.appending(
        path: ".config/bat/themes/\(BatAdapter.themeFileName)")
      batThemeDestination = stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
      shellConfiguration = homeDirectory.appending(path: ".zshrc")
      ezaThemeLink = homeDirectory.appending(
        path: ".config/eza/\(EzaAdapter.themeFileName)")
      ezaThemeDestination = stateRoot.appending(path: "current/\(EzaAdapter.outputPath)")
      includeDirective = ThemeActivationCoordinator.kittyIncludeDirective(root: stateRoot)
      manifestURL = stateRoot.appending(path: "state/setup/ownership.json")
    }

    var backupURL: URL {
      stateRoot.appending(path: backupRelativePath)
    }

    var batSelectorBackup: URL {
      stateRoot.appending(path: batSelectorBackupRelativePath)
    }

    var ezaEnvironmentBackup: URL {
      stateRoot.appending(path: ezaEnvironmentBackupRelativePath)
    }

    var bridgeURL: URL {
      stateRoot.appending(path: "state/adapters/kitty.conf")
    }

    let replacementName = ".macarchy-kitty-transaction"
    let batSelectorReplacementName = ".macarchy-bat-config-transaction"
    let ezaEnvironmentReplacementName = ".macarchy-zshrc-transaction"

    var replacementURL: URL {
      kittyConfiguration.deletingLastPathComponent().appending(path: replacementName)
    }
  }

  private struct RegularFileSnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let flags: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let extendedAttributes: [String: Data]

    init(metadata: stat, extendedAttributes: [String: Data]) {
      device = UInt64(metadata.st_dev)
      inode = UInt64(metadata.st_ino)
      mode = UInt32(metadata.st_mode)
      owner = metadata.st_uid
      group = metadata.st_gid
      flags = metadata.st_flags
      size = metadata.st_size
      modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
      modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
      changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
      changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
      self.extendedAttributes = extendedAttributes
    }

    func matchesDisplaced(_ other: Self) -> Bool {
      device == other.device
        && inode == other.inode
        && size == other.size
        && hasCopiedMetadata(from: other)
    }

    func hasCopiedMetadata(from other: Self) -> Bool {
      mode == other.mode
        && owner == other.owner
        && group == other.group
        && flags == other.flags
        && modifiedSeconds == other.modifiedSeconds
        && modifiedNanoseconds == other.modifiedNanoseconds
        && extendedAttributes == other.extendedAttributes
    }
  }
}

private struct SetupOwnershipManifest: Codable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let records: [SetupOwnershipRecord]

  init(records: [SetupOwnershipRecord]) {
    schemaVersion = Self.currentSchemaVersion
    self.records = records
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case records
  }
}

private struct SetupOwnershipRecord: Codable, Equatable {
  enum Kind: String, Codable, Equatable {
    case regularFile = "regular_file"
    case symbolicLink = "symbolic_link"
  }

  enum Phase: String, Codable, Equatable {
    case applied
    case prepared
  }

  let id: String
  let phase: Phase
  let kind: Kind
  let targetPath: String
  let backupPath: String?
  let originalDigest: String?
  let installedDigest: String
  let linkDestination: String?

  var applied: SetupOwnershipRecord {
    SetupOwnershipRecord(
      id: id,
      phase: .applied,
      kind: kind,
      targetPath: targetPath,
      backupPath: backupPath,
      originalDigest: originalDigest,
      installedDigest: installedDigest,
      linkDestination: linkDestination
    )
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case phase
    case kind
    case targetPath = "target_path"
    case backupPath = "backup_path"
    case originalDigest = "original_digest"
    case installedDigest = "installed_digest"
    case linkDestination = "link_destination"
  }

  init(
    id: String,
    phase: Phase,
    kind: Kind,
    targetPath: String,
    backupPath: String?,
    originalDigest: String?,
    installedDigest: String,
    linkDestination: String?
  ) {
    self.id = id
    self.phase = phase
    self.kind = kind
    self.targetPath = targetPath
    self.backupPath = backupPath
    self.originalDigest = originalDigest
    self.installedDigest = installedDigest
    self.linkDestination = linkDestination
  }

}

struct TeardownCommandRunner: Sendable {
  let ownershipManager: SetupOwnershipManager

  static let live = TeardownCommandRunner(ownershipManager: SetupOwnershipManager())

  func execute(
    homeDirectory: URL,
    dryRun: Bool,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let integrations: [SetupIntegrationResult]
    do {
      integrations = try ownershipManager.teardown(
        homeDirectory: homeDirectory,
        dryRun: dryRun
      )
    } catch {
      integrations = SetupOwnershipManager.failureResults(error, homeDirectory: homeDirectory)
    }
    let report = TeardownReport(dryRun: dryRun, integrations: integrations)
    return (try report.render(json: json), integrations.allSatisfy(\.succeeded))
  }
}

private struct TeardownReport: Encodable {
  let schemaVersion = 1
  let operation = "teardown"
  let dryRun: Bool
  let integrations: [SetupIntegrationResult]

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    let mutation =
      integrations.contains(where: \.mutationAttempted)
      ? "Recorded integration mutation attempted." : "No changes made."
    var lines = [
      "Macarchy teardown\(dryRun ? " (dry run)" : ""):"
    ]
    lines.append(
      contentsOf: integrations.map {
        "- \($0.id) [\($0.status.rawValue)]: \($0.message)"
      }
    )
    lines.append(mutation)
    return lines.joined(separator: "\n")
  }
}
