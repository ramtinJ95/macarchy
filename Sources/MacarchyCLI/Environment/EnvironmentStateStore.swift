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
        && (![.apply, .herdrTheme].contains(value.operation)
          || value.proposedOwnership != nil)
        && (value.previousOwnership?.hasValidShape ?? true)
        && (value.proposedOwnership?.hasValidShape ?? true)
        && Self.currentDestinationIsValid(value.previousCurrentDestination)
        && EnvironmentThemeBridgeState.pathsAreValid(
          value.rollbackThemeBridges,
          stateRoot: stateRoot
        )
        && Self.btopReplacementIsValid(value)
        && Self.codexReplacementIsValid(value)
        && Self.herdrReplacementIsValid(value)
        && Self.herdrRuntimeIsValid(value)
        && Self.piReplacementIsValid(value)
        && Self.spicetifyReplacementIsValid(value)
        && Self.spicetifyRuntimeIsValid(value)
        && Self.tuicrReplacementIsValid(value)
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

  private static func btopReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.btop != nil
      || transaction.proposedOwnership?.btop != nil
    return replacementIsValid(
      transaction.btopReplacementName,
      required: required,
      prefix: ".macarchy-environment-btop-"
    )
  }

  private static func codexReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.codex != nil
      || transaction.proposedOwnership?.codex != nil
    return replacementIsValid(
      transaction.codexReplacementName,
      required: required,
      prefix: ".macarchy-environment-codex-"
    )
  }

  private static func tuicrReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.tuicr != nil
      || transaction.proposedOwnership?.tuicr != nil
    return replacementIsValid(
      transaction.tuicrReplacementName,
      required: required,
      prefix: ".macarchy-environment-tuicr-"
    )
  }

  private static func herdrReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.herdr != nil
      || transaction.proposedOwnership?.herdr != nil
    return replacementIsValid(
      transaction.herdrReplacementName,
      required: required,
      prefix: ".macarchy-environment-herdr-"
    )
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

  private static func piReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.pi != nil
      || transaction.proposedOwnership?.pi != nil
    return replacementIsValid(
      transaction.piReplacementName,
      required: required,
      prefix: ".macarchy-environment-pi-"
    )
  }

  private static func spicetifyReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.spicetify != nil
      || transaction.proposedOwnership?.spicetify != nil
    return replacementIsValid(
      transaction.spicetifyReplacementName,
      required: required,
      prefix: ".macarchy-environment-spicetify-"
    )
  }

  private static func spicetifyRuntimeIsValid(_ transaction: EnvironmentTransaction) -> Bool {
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
  }

  private static func replacementIsValid(
    _ name: String?,
    required: Bool,
    prefix: String
  ) -> Bool {
    guard required else { return name == nil }
    guard let name else { return false }
    return name.hasPrefix(prefix)
      && name.hasSuffix(".replacement")
      && !name.contains("/")
      && name.utf8.count <= 128
  }
}
