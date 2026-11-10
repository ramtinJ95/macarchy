import Darwin
import Foundation
import ThemeCore

enum UnifiedSetupTransactionOperation: String, Codable, Sendable {
  case apply
  case teardown
}

enum UnifiedSetupTransactionPhase: String, Codable, Sendable {
  case mutating
  case committing
}

/// The four unified setup stages, declared in apply order; teardown runs them in reverse.
/// A closed list, not a provider registry (ADR-0099).
enum SetupStage: String, Codable, CaseIterable, Hashable, Sendable {
  case theme
  case desktop
  case environment
  case preferences

  static let applyOrder = allCases
  static let teardownOrder = Array(allCases.reversed())

  var tornDownCheckpoint: UnifiedSetupTransactionCheckpoint {
    switch self {
    case .theme: .themeTornDown
    case .desktop: .desktopTornDown
    case .environment: .environmentTornDown
    case .preferences: .preferencesTornDown
    }
  }
}

struct UnifiedSetupThemeRetirement: Codable, Equatable, Sendable {
  let generationID: String
  let committed: Bool

  enum CodingKeys: String, CodingKey {
    case generationID = "generation_id"
    case committed
  }
}

struct UnifiedSetupTransaction: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let operation: UnifiedSetupTransactionOperation
  let phase: UnifiedSetupTransactionPhase
  let stages: [SetupStage]
  let desiredAppearance: ThemeAppearance
  let contextDigest: String
  /// Applied paths retained before environment teardown removes its ownership.
  let userScripts: [String]?
  /// Write-ahead retirement target, then a durable commit before lock release.
  let themeRetirement: UnifiedSetupThemeRetirement?

  init(
    operation: UnifiedSetupTransactionOperation,
    phase: UnifiedSetupTransactionPhase = .mutating,
    stages: [SetupStage],
    desiredAppearance: ThemeAppearance,
    contextDigest: String,
    userScripts: [String]? = nil,
    themeRetirement: UnifiedSetupThemeRetirement? = nil
  ) {
    schemaVersion = Self.schemaVersion
    self.operation = operation
    self.phase = phase
    self.stages = stages
    self.desiredAppearance = desiredAppearance
    self.contextDigest = contextDigest
    self.userScripts = userScripts
    self.themeRetirement = themeRetirement
  }

  func replacing(
    phase: UnifiedSetupTransactionPhase? = nil,
    stages: [SetupStage]? = nil,
    themeRetirement: UnifiedSetupThemeRetirement? = nil
  ) -> Self {
    Self(
      operation: operation,
      phase: phase ?? self.phase,
      stages: stages ?? self.stages,
      desiredAppearance: desiredAppearance,
      contextDigest: contextDigest,
      userScripts: userScripts,
      themeRetirement: themeRetirement ?? self.themeRetirement
    )
  }

  var hasValidShape: Bool {
    guard
      (userScripts ?? []).count <= 8,
      Set(userScripts ?? []).count == (userScripts ?? []).count,
      (userScripts ?? []).allSatisfy({ NSString(string: $0).isAbsolutePath && !$0.contains("\0") }),
      themeRetirement.map { operation == .teardown && isGenerationID($0.generationID) } ?? true,
      schemaVersion == Self.schemaVersion,
      isSHA256Digest(contextDigest),
      Set(stages).count == stages.count
    else { return false }
    let order = operation == .apply ? SetupStage.applyOrder : SetupStage.teardownOrder
    return stages == order.filter { stages.contains($0) }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case operation, phase, stages
    case desiredAppearance = "desired_appearance"
    case contextDigest = "context_digest"
    case userScripts = "user_scripts"
    case themeRetirement = "theme_retirement"
  }
}

struct UnifiedSetupTransactionStore: Sendable {
  let stateRoot: URL

  var url: URL {
    stateRoot.appending(path: "state/setup/transaction.json")
  }

  func read() throws -> UnifiedSetupTransaction? {
    let file: BoundedRegularFile?
    do {
      file = try BoundedRegularFile.readIfPresent(at: url)
    } catch {
      throw UnifiedSetupTransactionError.invalid(String(describing: error))
    }
    guard let data = file?.data else { return nil }
    do {
      _ = try StrictJSONObjectDocument(data: data, id: "setup_transaction", target: url)
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard
        let object,
        Set(object.keys).subtracting(["user_scripts", "theme_retirement"])
          == Set(UnifiedSetupTransaction.CodingKeys.allCases.map(\.rawValue)).subtracting([
            "user_scripts", "theme_retirement",
          ])
      else {
        throw UnifiedSetupTransactionError.invalid("contains unknown or missing fields")
      }
      if let retirement = object["theme_retirement"] {
        guard let fields = retirement as? [String: Any],
          Set(fields.keys) == ["generation_id", "committed"]
        else {
          throw UnifiedSetupTransactionError.invalid(
            "theme retirement contains unknown or missing fields")
        }
      }
      let transaction = try JSONDecoder().decode(UnifiedSetupTransaction.self, from: data)
      guard transaction.hasValidShape else {
        throw UnifiedSetupTransactionError.invalid("has an invalid shape")
      }
      return transaction
    } catch let error as UnifiedSetupTransactionError {
      throw error
    } catch {
      throw UnifiedSetupTransactionError.invalid(String(describing: error))
    }
  }

  func write(_ transaction: UnifiedSetupTransaction) throws {
    guard transaction.hasValidShape else {
      throw UnifiedSetupTransactionError.invalid("has an invalid shape")
    }
    try writeBoundedEvidenceJSON(
      transaction,
      to: url,
      temporaryPrefix: ".transaction-",
      tooLargeError: UnifiedSetupTransactionError.invalid("exceeds the 1 MiB file limit"),
      replaceError: { UnifiedSetupTransactionError.system("replace transaction", $0) }
    )
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      throw UnifiedSetupTransactionError.invalid(String(describing: error))
    }
  }
}

struct UnifiedSetupLifecycleLock: Sendable {
  private static let lock = ProcessScopedFileLock<UnifiedSetupTransactionError>(
    filename: "setup.lock",
    cannotCreateRunDirectory: { url, reason in
      .invalid("cannot create \(url.path): \(reason)")
    },
    operationError: { operation, code in
      .system("\(operation) setup lock", code)
    }
  )

  let stateRoot: URL

  func withLock<Output: Sendable>(
    _ operation: @Sendable () async throws -> Output
  ) async throws -> Output {
    try await Self.lock.withLock(root: stateRoot, operation)
  }
}

enum UnifiedSetupTransactionCheckpoint: Sendable {
  case themeApplied
  case desktopApplied
  case environmentApplied
  case preferencesApplied
  case preferencesTornDown
  case environmentTornDown
  case desktopTornDown
  case themeTornDown
}

enum UnifiedSetupInterruptionError: Error, Sendable {
  case injected
}

struct UnifiedSetupRecoveryResult: Sendable {
  var preferences: UnifiedSetupTeardownStage?
  var environment: UnifiedSetupTeardownStage?
  var desktop: UnifiedSetupTeardownStage?
  var theme: UnifiedSetupTeardownStage?

  var mutated: Bool {
    [preferences, environment, desktop, theme].compactMap { $0 }.contains { $0.mutated }
  }

  mutating func record(
    _ result: UnifiedSetupTeardownStage,
    for stage: SetupStage
  ) {
    switch stage {
    case .preferences: preferences = result
    case .environment: environment = result
    case .desktop: desktop = result
    case .theme: theme = result
    }
  }
}

enum UnifiedSetupTransactionError: Error, CustomStringConvertible, Sendable {
  case invalid(String)
  case recoveryRequired(String)
  case system(String, Int32)

  var description: String {
    switch self {
    case .invalid(let reason):
      "Invalid unified setup transaction: \(reason)"
    case .recoveryRequired(let reason):
      "Unified setup recovery is required: \(reason)"
    case .system(let operation, let code):
      "Cannot \(operation) (errno \(code)): \(String(cString: strerror(code)))"
    }
  }
}

func unifiedSetupContextDigest(
  context: UnifiedSetupPlanContext,
  consumerPaths: ThemeConsumerPaths
) -> String {
  let paths = [
    context.homeDirectory,
    consumerPaths.kittyConfigurationURL,
    consumerPaths.sketchyBarConfigurationURL,
    consumerPaths.shellConfigurationURL,
    consumerPaths.ezaConfigurationDirectoryURL,
    consumerPaths.batConfigurationDirectoryURL,
    consumerPaths.batCacheDirectoryURL,
    consumerPaths.btopConfigurationDirectoryURL,
    consumerPaths.yaziConfigurationDirectoryURL,
    consumerPaths.atuinConfigurationDirectoryURL,
    consumerPaths.neovimConfigurationDirectoryURL,
    consumerPaths.starshipConfigurationURL,
    consumerPaths.starshipBehaviorURL,
    consumerPaths.piConfigurationDirectoryURL,
    consumerPaths.herdrConfigurationURL,
    consumerPaths.tuicrConfigurationDirectoryURL,
    consumerPaths.codexConfigurationDirectoryURL,
    consumerPaths.spicetifyConfigurationDirectoryURL,
  ].map(\.standardizedFileURL.path)
  return sha256Digest(Data(paths.joined(separator: "\0").utf8))
}
