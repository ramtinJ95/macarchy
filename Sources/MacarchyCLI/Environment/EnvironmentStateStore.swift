import Darwin
import Foundation
import ThemeCore

struct EnvironmentStateStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "environment", directoryHint: .isDirectory)
  }
  private var ownershipURL: URL { directory.appending(path: "ownership.json") }
  private var transactionURL: URL { directory.appending(path: "transaction.json") }
  private var spicetifyRecoveryURL: URL {
    directory.appending(path: "spicetify-recovery.json")
  }

  static let spicetifyRecoveryMessage =
    "Spotify runtime restoration remains UNVERIFIED after an explicitly acknowledged rollback. Macarchy restored configuration ownership only; repair Spicetify manually before enabling the preset."

  func hasUnverifiedSpicetifyRecovery() throws -> Bool {
    try read(String.self, at: spicetifyRecoveryURL) { $0 == "original_runtime_unverified" } != nil
  }

  func recordUnverifiedSpicetifyRecovery() throws {
    try write("original_runtime_unverified", to: spicetifyRecoveryURL)
  }

  func clearUnverifiedSpicetifyRecovery() throws { try remove(spicetifyRecoveryURL) }

  func readOwnership() throws -> EnvironmentOwnership? {
    try read(EnvironmentOwnership.self, at: ownershipURL) { value in
      value.hasValidShape
    }
  }

  func writeOwnership(_ ownership: EnvironmentOwnership?) throws {
    if let ownership {
      try write(ownership, to: ownershipURL)
    } else {
      try remove(ownershipURL)
    }
  }

  func readTransaction() throws -> EnvironmentTransaction? {
    try read(EnvironmentTransaction.self, at: transactionURL) { value in
      value.schemaVersion == EnvironmentTransaction.currentSchemaVersion
        && (![.apply, .herdrTheme, .neovimMigration, .atuinMigration, .starshipMigration].contains(
          value.operation)
          || value.proposedOwnership != nil)
        && (value.previousOwnership?.hasValidShape ?? true)
        && (value.proposedOwnership?.hasValidShape ?? true)
        && Self.currentDestinationIsValid(value.previousCurrentDestination)
        && EnvironmentThemeBridgeState.pathsAreValid(
          value.rollbackThemeBridges,
          stateRoot: stateRoot
        )
        && Self.providerReplacementsAreValid(value, stateRoot: stateRoot)
        && Self.herdrRuntimeIsValid(value)
        && Self.spicetifyRuntimeIsValid(value)
        && value.bordersRuntimeIsValid
    }
  }

  func writeTransaction(_ transaction: EnvironmentTransaction) throws {
    try write(transaction, to: transactionURL)
  }

  func removeTransaction() throws { try remove(transactionURL) }

  var transactionExists: Bool {
    var metadata = stat()
    return lstat(transactionURL.path, &metadata) == 0
  }

  private func read<T: Decodable>(
    _ type: T.Type,
    at url: URL,
    validate: (T) -> Bool
  ) throws -> T? {
    let stateDescriptor: Int32
    let directoryDescriptor: Int32
    do {
      (stateDescriptor, directoryDescriptor) = try openDirectory(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    defer {
      Darwin.close(directoryDescriptor)
      Darwin.close(stateDescriptor)
    }
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: directoryDescriptor,
        name: url.lastPathComponent,
        url: url
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw EnvironmentLifecycleError.blocked("\(url.path) is not a regular file")
    }
    let value = try JSONDecoder().decode(
      type,
      from: PinnedFilesystem.readRegularFile(
        parentDescriptor: directoryDescriptor,
        name: url.lastPathComponent,
        url: url,
        maximumSize: 131_072
      ).data
    )
    guard validate(value) else {
      throw EnvironmentLifecycleError.blocked("\(url.path) is invalid")
    }
    return value
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let (stateDescriptor, directoryDescriptor) = try openDirectory(create: true)
    defer {
      Darwin.close(directoryDescriptor)
      Darwin.close(stateDescriptor)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: directoryDescriptor,
      name: url.lastPathComponent,
      url: url,
      data: encoder.encode(value),
      mode: 0o600
    )
  }

  private func remove(_ url: URL) throws {
    let stateDescriptor: Int32
    let directoryDescriptor: Int32
    do {
      (stateDescriptor, directoryDescriptor) = try openDirectory(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer {
      Darwin.close(directoryDescriptor)
      Darwin.close(stateDescriptor)
    }
    let removed = url.lastPathComponent.withCString {
      Darwin.unlinkat(directoryDescriptor, $0, 0)
    }
    guard removed == 0 || errno == ENOENT else {
      throw EnvironmentLifecycleError.system("remove state", url, errno)
    }
    if removed == 0, fsync(directoryDescriptor) != 0 {
      throw EnvironmentLifecycleError.system("sync removed state", url, errno)
    }
  }

  private func openDirectory(create: Bool) throws -> (Int32, Int32) {
    let stateDescriptor = try PinnedFilesystem.openDirectory(at: stateRoot)
    do {
      let directoryDescriptor =
        try create
        ? PinnedFilesystem.openOrCreateChildDirectory(
          parentDescriptor: stateDescriptor,
          name: "environment",
          url: directory,
          mode: 0o700
        )
        : PinnedFilesystem.openDirectory(
          parentDescriptor: stateDescriptor,
          name: "environment",
          url: directory
        )
      return (stateDescriptor, directoryDescriptor)
    } catch {
      Darwin.close(stateDescriptor)
      throw error
    }
  }

  private static func currentDestinationIsValid(_ destination: String?) -> Bool {
    guard let destination else { return true }
    let prefix = "generations/"
    guard destination.hasPrefix(prefix), !destination.dropFirst(prefix.count).contains("/") else {
      return false
    }
    return EnvironmentGenerationStore.isGenerationID(String(destination.dropFirst(prefix.count)))
  }

  private static func providerReplacementsAreValid(
    _ transaction: EnvironmentTransaction, stateRoot: URL
  ) -> Bool {
    guard (transaction.operation == .standardMigration) == (transaction.standardMigration != nil)
    else { return false }
    if transaction.operation.isScopedConnection {
      let valid =
        transaction.operation == .neovimConnection
        ? EnvironmentNeovimConnection.ownershipChangeIsValid(transaction)
        : EnvironmentNativeFileConnection.ownershipChangeIsValid(transaction, stateRoot: stateRoot)
      return valid
        && transaction.previousCurrentDestination
          == transaction.previousOwnership.map({ "generations/\($0.generationID)" })
        && transaction.previousThemeGenerationID == nil && transaction.rollbackThemeBridges.isEmpty
        && transaction.replacementNames.isEmpty
        && transaction.herdrRuntimeTarget == nil && transaction.herdrRuntimeVerified == nil
        && transaction.herdrLegacyMigration == nil
    }
    if transaction.operation.isNativeMigration {
      let id: EnvironmentEntryID =
        transaction.standardMigration?.provider.entryID
        ?? transaction.operation.nativeFileProvider?.entryID ?? .neovim
      guard let previous = transaction.previousOwnership,
        let proposed = transaction.proposedOwnership,
        let old = previous.records.first(where: { $0.id == id })
      else { return false }
      let changeIsValid: Bool
      if transaction.operation == .standardMigration {
        changeIsValid = previous.releasingStandardEntry(id) == proposed
      } else if let new = proposed.records.first(where: { $0.id == id }) {
        changeIsValid =
          old.managedTarget != new.managedTarget
          && previous.replacingTarget(for: id, with: new.managedTarget) == proposed
      } else {
        return false
      }
      return changeIsValid
        && transaction.previousCurrentDestination == "generations/\(previous.generationID)"
        && transaction.previousThemeGenerationID == nil
        && transaction.rollbackThemeBridges.isEmpty
        && transaction.replacementNames.isEmpty
        && transaction.herdrRuntimeVerified == nil && transaction.herdrLegacyMigration == nil
        && transaction.spicetifyRuntimeVerified == nil
        && transaction.spicetifyRuntimeDeferred == nil
    }
    if transaction.operation == .herdrTheme {
      guard let previous = transaction.previousOwnership,
        let proposed = transaction.proposedOwnership,
        previous.herdrEnabled, proposed.herdrEnabled,
        let oldHerdr = previous.herdr, let newHerdr = proposed.herdr
      else { return false }
      return previous.replacingHerdr(oldHerdr.replacingManagedTheme(newHerdr.managedTheme))
        == proposed
        && transaction.previousCurrentDestination == "generations/\(previous.generationID)"
        && transaction.previousThemeGenerationID == nil
        && transaction.rollbackThemeBridges.isEmpty
        // A theme transaction reserves only Herdr's replacement.
        && transaction.replacementNames
          == EnvironmentReplacementNames(herdr: transaction.herdrReplacementName)
        && EnvironmentReplacementNames.isValid(
          transaction.herdrReplacementName, preset: "herdr", required: true)
    }
    return transaction.replacementNames.areValid(
      from: transaction.previousOwnership, to: transaction.proposedOwnership)
  }

  private static func herdrRuntimeIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let expected =
      transaction.direction == .rollback && transaction.herdrLegacyMigration == true
      ? .managed
      : transaction.direction == .forward
        ? EnvironmentHerdrRuntimeTarget.required(
          from: transaction.previousOwnership,
          to: transaction.proposedOwnership
        )
        : EnvironmentHerdrRuntimeTarget.required(
          from: transaction.proposedOwnership,
          to: transaction.previousOwnership
        )
    return transaction.herdrRuntimeTarget == expected
      && (transaction.herdrRuntimeVerified == nil || transaction.herdrRuntimeVerified == true)
      && herdrLegacyMigrationIsValid(transaction)
  }

  private static func herdrLegacyMigrationIsValid(
    _ transaction: EnvironmentTransaction
  ) -> Bool {
    guard transaction.herdrLegacyMigration != false else { return false }
    guard transaction.herdrLegacyMigration == true else { return true }
    return transaction.operation == .apply
      && transaction.previousOwnership?.herdr == nil
      && transaction.proposedOwnership?.herdrEnabled == true
      && transaction.proposedOwnership?.herdr?.migratedLegacy == true
  }

  private static func spicetifyRuntimeIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    if transaction.operation.isScopedConnection {
      return transaction.spicetifyRuntimeTarget == nil
        && transaction.spicetifyRuntimeVerified == nil
        && transaction.spicetifyRuntimeDeferred == nil
    }
    let expected =
      transaction.direction == .forward
      ? EnvironmentSpicetifyRuntimeTarget.required(
        from: transaction.previousOwnership,
        to: transaction.proposedOwnership
      )
      : EnvironmentSpicetifyRuntimeTarget.required(
        from: transaction.proposedOwnership,
        to: transaction.previousOwnership
      )
    return transaction.spicetifyRuntimeTarget == expected
      && (transaction.spicetifyRuntimeVerified == nil
        || transaction.spicetifyRuntimeVerified == true)
      && (transaction.spicetifyRuntimeDeferred == nil
        || (transaction.spicetifyRuntimeDeferred == true
          && transaction.operation == .apply && transaction.direction == .rollback
          && expected == .original && transaction.spicetifyRuntimeVerified == nil))
  }
}
