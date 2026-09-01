import Darwin
import Foundation
import ThemeCore

enum KeybindingEffectiveStatus: String, Encodable, Sendable {
  case clean
  case converged
  case drifted
  case externallyManaged = "externally_managed"
  case blocked
  case recoveryRequired = "recovery_required"
}

enum KeybindingTransactionStatus: String, Encodable, Sendable {
  case clear
  case pending
  case invalid
}

struct KeybindingTransactionInspection: Encodable, Sendable {
  let status: KeybindingTransactionStatus
  let operation: String?
  let phase: String?
  let generationID: String?
  let message: String
  let pendingTransaction: KeybindingApplyTransaction?

  enum CodingKeys: String, CodingKey {
    case status, operation, phase, message
    case generationID = "generation_id"
  }

  static let clear = KeybindingTransactionInspection(
    status: .clear,
    operation: nil,
    phase: nil,
    generationID: nil,
    message: "No interrupted keybinding transaction exists.",
    pendingTransaction: nil
  )
}

enum KeybindingProcessStatus: String, Encodable, Sendable {
  case running
  case notRunning = "not_running"
  case unsupported
  case unavailable
}

struct KeybindingProcessInspection: Encodable, Equatable, Sendable {
  let status: KeybindingProcessStatus
  let message: String
  let processID: Int32?
  let executablePath: String?
  let arguments: [String]

  static let notRunning = KeybindingProcessInspection(
    status: .notRunning,
    message: "No skhd process is running for the current user.",
    processID: nil,
    executablePath: nil,
    arguments: []
  )
}

struct KeybindingProcessSnapshot: Equatable, Sendable {
  let processID: Int32
  let executablePath: String
  let arguments: [String]
}

struct KeybindingProcessInspector: Sendable {
  let inspect: @Sendable () -> KeybindingProcessInspection

  static var supportedExecutablePath: String {
    URL(filePath: "/opt/homebrew/bin/skhd")
      .resolvingSymlinksInPath().standardizedFileURL.path
  }

  init(inspect: @escaping @Sendable () -> KeybindingProcessInspection) {
    self.inspect = inspect
  }

  static let live = KeybindingProcessInspector {
    do {
      let result = try ProcessRunner.live.run(
        ProcessRequest(
          executableURL: URL(filePath: "/usr/bin/pgrep"),
          arguments: ["-u", String(getuid()), "-x", "skhd"],
          timeout: 1
        )
      )
      switch result.terminationStatus {
      case 0:
        let processIDs = result.output.split(whereSeparator: \.isNewline).compactMap {
          Int32($0.trimmingCharacters(in: .whitespaces))
        }
        return validated(
          processIDs: processIDs,
          expectedExecutable: supportedExecutablePath,
          snapshot: processSnapshot
        )
      case 1:
        return .notRunning
      default:
        return KeybindingProcessInspection(
          status: .unavailable,
          message: "skhd process evidence is unavailable (pgrep status "
            + "\(result.terminationStatus)).",
          processID: nil,
          executablePath: nil,
          arguments: []
        )
      }
    } catch {
      return KeybindingProcessInspection(
        status: .unavailable,
        message: "skhd process evidence is unavailable: \(error)",
        processID: nil,
        executablePath: nil,
        arguments: []
      )
    }
  }

  static func validated(
    processIDs: [Int32],
    expectedExecutable: String,
    snapshot: (Int32) throws -> KeybindingProcessSnapshot
  ) -> KeybindingProcessInspection {
    guard !processIDs.isEmpty else { return .notRunning }
    guard processIDs.allSatisfy({ $0 > 0 }) else {
      return KeybindingProcessInspection(
        status: .unavailable,
        message: "skhd process evidence contains an invalid process identity.",
        processID: nil,
        executablePath: nil,
        arguments: []
      )
    }
    do {
      let snapshots = try processIDs.sorted().map(snapshot)
      guard snapshots.count == 1, let observed = snapshots.first else {
        return KeybindingProcessInspection(
          status: .unsupported,
          message: "Expected exactly one UID-scoped skhd process; found \(snapshots.count).",
          processID: nil,
          executablePath: nil,
          arguments: []
        )
      }
      guard observed.processID == processIDs[0] else {
        return KeybindingProcessInspection(
          status: .unavailable,
          message: "UID-scoped skhd process identity changed during inspection.",
          processID: nil,
          executablePath: nil,
          arguments: []
        )
      }
      guard observed.executablePath == expectedExecutable else {
        return KeybindingProcessInspection(
          status: .unsupported,
          message: "UID-scoped skhd PID \(observed.processID) uses unsupported executable "
            + "\(observed.executablePath).",
          processID: observed.processID,
          executablePath: observed.executablePath,
          arguments: observed.arguments
        )
      }
      guard !observed.arguments.isEmpty else {
        return KeybindingProcessInspection(
          status: .unavailable,
          message: "UID-scoped skhd PID \(observed.processID) has no inspectable arguments.",
          processID: observed.processID,
          executablePath: observed.executablePath,
          arguments: []
        )
      }
      let explicitConfiguration = observed.arguments.dropFirst().contains {
        $0 == "-c" || $0.hasPrefix("-c") || $0 == "--config" || $0.hasPrefix("--config=")
      }
      guard !explicitConfiguration else {
        return KeybindingProcessInspection(
          status: .unsupported,
          message: "UID-scoped skhd PID \(observed.processID) selects an explicit config with -c; "
            + "Macarchy cannot prove the managed provider entry is authoritative.",
          processID: observed.processID,
          executablePath: observed.executablePath,
          arguments: observed.arguments
        )
      }
      return KeybindingProcessInspection(
        status: .running,
        message: "UID-scoped skhd PID \(observed.processID) uses the supported executable "
          + "without an explicit config argument.",
        processID: observed.processID,
        executablePath: observed.executablePath,
        arguments: observed.arguments
      )
    } catch {
      return KeybindingProcessInspection(
        status: .unavailable,
        message: "Cannot inspect UID-scoped skhd process identity and arguments: \(error)",
        processID: nil,
        executablePath: nil,
        arguments: []
      )
    }
  }

  private static func processSnapshot(_ processID: Int32) throws -> KeybindingProcessSnapshot {
    var pathBuffer = [CChar](repeating: 0, count: 4_096)
    let pathLength = proc_pidpath(processID, &pathBuffer, UInt32(pathBuffer.count))
    guard pathLength > 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ESRCH)
    }
    let executablePath = String(
      decoding: pathBuffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
      as: UTF8.self
    )

    var argumentsSize = 0
    var mib = [CTL_KERN, KERN_PROCARGS2, processID]
    guard sysctl(&mib, u_int(mib.count), nil, &argumentsSize, nil, 0) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    var bytes = [UInt8](repeating: 0, count: argumentsSize)
    guard
      sysctl(&mib, u_int(mib.count), &bytes, &argumentsSize, nil, 0) == 0,
      argumentsSize >= MemoryLayout<Int32>.size
    else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard count > 0 else { throw POSIXError(.EINVAL) }
    var cursor = MemoryLayout<Int32>.size
    while cursor < argumentsSize, bytes[cursor] != 0 { cursor += 1 }
    while cursor < argumentsSize, bytes[cursor] == 0 { cursor += 1 }
    var arguments: [String] = []
    while cursor < argumentsSize, arguments.count < Int(count) {
      let start = cursor
      while cursor < argumentsSize, bytes[cursor] != 0 { cursor += 1 }
      guard cursor > start,
        let argument = String(data: Data(bytes[start..<cursor]), encoding: .utf8)
      else { throw POSIXError(.EILSEQ) }
      arguments.append(argument)
      while cursor < argumentsSize, bytes[cursor] == 0 { cursor += 1 }
    }
    guard arguments.count == Int(count) else { throw POSIXError(.EINVAL) }
    return KeybindingProcessSnapshot(
      processID: processID,
      executablePath: executablePath,
      arguments: arguments
    )
  }
}

struct KeybindingEffectiveBehavior: Sendable {
  let desired: KeybindingEffectiveState
  let provider: KeybindingProviderInspection
  let transaction: KeybindingTransactionInspection
  let process: KeybindingProcessInspection
  let lifecycleEvidence: KeybindingLifecycleEvidenceInspection
  let status: KeybindingEffectiveStatus
  let statusMessage: String

  var configuration: KeybindingEffectiveConfiguration { desired.configuration }
  var generation: KeybindingGenerationInspection { desired.generation }
  var generationAgreement: KeybindingGenerationAgreement { desired.generationAgreement }
  var presentedBindings: [EffectiveKeybinding] { desired.presentedBindings }
  var presentedDisabledDefaults: [DisabledPackagedKeybinding] {
    desired.presentedDisabledDefaults
  }
}

struct KeybindingEffectiveBehaviorInspector: Sendable {
  let processInspector: KeybindingProcessInspector

  static let live = KeybindingEffectiveBehaviorInspector(processInspector: .live)

  func inspect(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    ignoreTransaction: Bool = false
  ) -> KeybindingEffectiveBehavior {
    var previous: InspectedState?
    for _ in 0..<3 {
      let observed = inspectOnce(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        ignoreTransaction: ignoreTransaction
      )
      if let previous, previous.identity == observed.identity { return observed.behavior }
      previous = observed
    }
    guard let previous else { preconditionFailure("inspection retry count must be positive") }
    let behavior = previous.behavior
    return KeybindingEffectiveBehavior(
      desired: behavior.desired,
      provider: behavior.provider,
      transaction: behavior.transaction,
      process: behavior.process,
      lifecycleEvidence: behavior.lifecycleEvidence,
      status: .blocked,
      statusMessage:
        "Canonical keybinding state changed during bounded inspection; retry after mutation stops."
    )
  }

  private func inspectOnce(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    ignoreTransaction: Bool
  ) -> InspectedState {
    let desired = KeybindingEffectiveStateInspector().inspect(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot
    )
    let provider = KeybindingProviderInspector().inspect(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      generation: desired.generation
    )
    let transaction = ignoreTransaction ? .clear : inspectTransaction(stateRoot: stateRoot)
    let process = processInspector.inspect()
    let lifecycleEvidence = KeybindingLifecycleEvidenceStore(stateRoot: stateRoot).inspect(
      generation: desired.generation,
      provider: provider,
      process: process
    )
    let classification = classify(
      desired: desired,
      provider: provider,
      transaction: transaction,
      process: process,
      lifecycleEvidence: lifecycleEvidence
    )
    let behavior = KeybindingEffectiveBehavior(
      desired: desired,
      provider: provider,
      transaction: transaction,
      process: process,
      lifecycleEvidence: lifecycleEvidence,
      status: classification.status,
      statusMessage: classification.message
    )
    return InspectedState(behavior: behavior, identity: InspectionIdentity(behavior))
  }

  private func inspectTransaction(stateRoot: URL) -> KeybindingTransactionInspection {
    do {
      guard let pending = try KeybindingApplyTransactionStore(stateRoot: stateRoot).read() else {
        return .clear
      }
      return KeybindingTransactionInspection(
        status: .pending,
        operation: pending.operation.rawValue,
        phase: pending.phase.rawValue,
        generationID: pending.generationID,
        message: "Interrupted \(pending.operation.rawValue) transaction is in "
          + "phase \(pending.phase.rawValue); recovery is required.",
        pendingTransaction: pending
      )
    } catch {
      return KeybindingTransactionInspection(
        status: .invalid,
        operation: nil,
        phase: nil,
        generationID: nil,
        message: String(describing: error),
        pendingTransaction: nil
      )
    }
  }

  private func classify(
    desired: KeybindingEffectiveState,
    provider: KeybindingProviderInspection,
    transaction: KeybindingTransactionInspection,
    process: KeybindingProcessInspection,
    lifecycleEvidence: KeybindingLifecycleEvidenceInspection
  ) -> (status: KeybindingEffectiveStatus, message: String) {
    switch transaction.status {
    case .pending:
      return (.recoveryRequired, transaction.message)
    case .invalid:
      return (.blocked, "Transaction evidence is corrupt: \(transaction.message)")
    case .clear:
      break
    }

    if desired.configuration.isBlocked {
      return (.blocked, "Portable keybinding inputs are invalid or contradictory.")
    }
    if desired.generation.status == .invalid {
      return (
        .blocked,
        desired.generation.message ?? "The current generated keybinding state is corrupt."
      )
    }
    if provider.status == .blocked {
      if provider.ownership == "recovery_required" {
        return (.recoveryRequired, provider.message)
      }
      if provider.ownership == "ownership_drift" {
        return (.drifted, provider.message)
      }
      return (.blocked, provider.message)
    }

    switch provider.status {
    case .adoptionRequired:
      return (
        .externallyManaged,
        "The authoritative skhd entry is externally managed and requires reviewed adoption."
      )
    case .installRequired:
      if desired.generation.status == .missing {
        return (.clean, "No managed keybinding generation or provider entry exists.")
      }
      return (.drifted, "A generated configuration exists without a managed provider entry.")
    case .managed:
      guard desired.generationAgreement == .matches else {
        return (.drifted, "Managed provider state does not agree with the effective inputs.")
      }
      switch process.status {
      case .running:
        break
      case .notRunning:
        return (.drifted, process.message)
      case .unsupported:
        return (.blocked, process.message)
      case .unavailable:
        return (.blocked, process.message)
      }
      switch lifecycleEvidence.status {
      case .matched:
        return (
          .converged,
          "Effective inputs, generated bytes, provider ownership, lifecycle command evidence, "
            + "and process evidence agree. Runtime binding equivalence remains unobservable."
        )
      case .missing, .stale:
        return (.drifted, lifecycleEvidence.message)
      case .invalid:
        return (.blocked, lifecycleEvidence.message)
      }
    case .blocked:
      preconditionFailure("blocked providers are classified before the provider switch")
    }
  }
}

private struct InspectedState {
  let behavior: KeybindingEffectiveBehavior
  let identity: InspectionIdentity
}

private struct InspectionIdentity: Equatable {
  let configurationDigest: String?
  let generationStatus: KeybindingGenerationStatus
  let generationID: String?
  let generationInputDigest: String?
  let generationRenderedDigest: String?
  let providerStatus: KeybindingProviderStatus
  let providerOwnership: String
  let providerEvidenceDigest: String?
  let transactionStatus: KeybindingTransactionStatus
  let transactionOperation: String?
  let transactionPhase: String?
  let transactionGenerationID: String?
  let process: KeybindingProcessInspection
  let lifecycleEvidence: KeybindingLifecycleEvidenceInspection

  init(_ behavior: KeybindingEffectiveBehavior) {
    configurationDigest = behavior.configuration.composition?.inputDigest
    generationStatus = behavior.generation.status
    generationID = behavior.generation.generationID
    generationInputDigest = behavior.generation.inputDigest
    generationRenderedDigest = behavior.generation.renderedDigest
    providerStatus = behavior.provider.status
    providerOwnership = behavior.provider.ownership
    providerEvidenceDigest = behavior.provider.adoptionEvidenceDigest
    transactionStatus = behavior.transaction.status
    transactionOperation = behavior.transaction.operation
    transactionPhase = behavior.transaction.phase
    transactionGenerationID = behavior.transaction.generationID
    process = behavior.process
    lifecycleEvidence = behavior.lifecycleEvidence
  }
}
