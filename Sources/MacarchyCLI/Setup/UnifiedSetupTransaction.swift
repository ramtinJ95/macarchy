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

enum UnifiedSetupTransactionStage: String, Codable, Hashable, Sendable {
  case theme
  case desktop
  case environment
}

struct UnifiedSetupTransaction: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let operation: UnifiedSetupTransactionOperation
  let phase: UnifiedSetupTransactionPhase
  let stages: [UnifiedSetupTransactionStage]
  let desiredAppearance: ThemeAppearance
  let contextDigest: String

  init(
    operation: UnifiedSetupTransactionOperation,
    phase: UnifiedSetupTransactionPhase = .mutating,
    stages: [UnifiedSetupTransactionStage],
    desiredAppearance: ThemeAppearance,
    contextDigest: String
  ) {
    schemaVersion = Self.schemaVersion
    self.operation = operation
    self.phase = phase
    self.stages = stages
    self.desiredAppearance = desiredAppearance
    self.contextDigest = contextDigest
  }

  func replacing(
    phase: UnifiedSetupTransactionPhase? = nil,
    stages: [UnifiedSetupTransactionStage]? = nil
  ) -> Self {
    Self(
      operation: operation,
      phase: phase ?? self.phase,
      stages: stages ?? self.stages,
      desiredAppearance: desiredAppearance,
      contextDigest: contextDigest
    )
  }

  var hasValidShape: Bool {
    guard
      schemaVersion == Self.schemaVersion,
      contextDigest.hasPrefix("sha256:"),
      contextDigest.count == 71,
      contextDigest.dropFirst(7).allSatisfy({
        $0.isASCII && $0.isHexDigit && !$0.isUppercase
      }),
      Set(stages).count == stages.count
    else { return false }
    let order: [UnifiedSetupTransactionStage] =
      operation == .apply
      ? [.theme, .desktop, .environment]
      : [.environment, .desktop, .theme]
    return stages == order.filter { stages.contains($0) }
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, phase, stages
    case desiredAppearance = "desired_appearance"
    case contextDigest = "context_digest"
  }
}

struct UnifiedSetupTransactionStore: Sendable {
  let stateRoot: URL

  var url: URL {
    stateRoot.appending(path: "state/setup/transaction.json")
  }

  func read() throws -> UnifiedSetupTransaction? {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: url).data
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT) {
      return nil
    } catch {
      throw UnifiedSetupTransactionError.invalid(String(describing: error))
    }
    do {
      _ = try StrictJSONObjectDocument(data: data, id: "setup_transaction", target: url)
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard
        let object,
        Set(object.keys)
          == [
            "schema_version", "operation", "phase", "stages", "desired_appearance",
            "context_digest",
          ]
      else {
        throw UnifiedSetupTransactionError.invalid("contains unknown or missing fields")
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
  case environmentTornDown
  case desktopTornDown
  case themeTornDown
}

enum UnifiedSetupInterruptionError: Error, Sendable {
  case injected
}

struct UnifiedSetupRecoveryResult: Sendable {
  var environment: UnifiedSetupTeardownStage?
  var desktop: UnifiedSetupTeardownStage?
  var theme: UnifiedSetupTeardownStage?

  var mutated: Bool {
    [environment, desktop, theme].compactMap { $0 }.contains { $0.mutated }
  }

  mutating func record(
    _ result: UnifiedSetupTeardownStage,
    for stage: UnifiedSetupTransactionStage
  ) {
    switch stage {
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
