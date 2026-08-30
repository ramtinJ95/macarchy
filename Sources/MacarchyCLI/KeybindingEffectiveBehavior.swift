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
  case unavailable
}

struct KeybindingProcessInspection: Encodable, Equatable, Sendable {
  let status: KeybindingProcessStatus
  let message: String

  static let running = KeybindingProcessInspection(
    status: .running,
    message: "The current user's skhd process is running."
  )

  static let notRunning = KeybindingProcessInspection(
    status: .notRunning,
    message: "No skhd process is running for the current user."
  )
}

struct KeybindingProcessInspector: Sendable {
  let inspect: @Sendable () -> KeybindingProcessInspection

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
        return .running
      case 1:
        return .notRunning
      default:
        return KeybindingProcessInspection(
          status: .unavailable,
          message: "skhd process evidence is unavailable (pgrep status "
            + "\(result.terminationStatus))."
        )
      }
    } catch {
      return KeybindingProcessInspection(
        status: .unavailable,
        message: "skhd process evidence is unavailable: \(error)"
      )
    }
  }
}

struct KeybindingEffectiveBehavior: Sendable {
  let desired: KeybindingEffectiveState
  let provider: KeybindingProviderInspection
  let transaction: KeybindingTransactionInspection
  let process: KeybindingProcessInspection
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
    homeDirectory: URL
  ) -> KeybindingEffectiveBehavior {
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
    let transaction = inspectTransaction(stateRoot: stateRoot)
    let process = processInspector.inspect()
    let classification = classify(
      desired: desired,
      provider: provider,
      transaction: transaction,
      process: process
    )
    return KeybindingEffectiveBehavior(
      desired: desired,
      provider: provider,
      transaction: transaction,
      process: process,
      status: classification.status,
      statusMessage: classification.message
    )
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
    process: KeybindingProcessInspection
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
        return (
          .converged,
          "Effective inputs, generated bytes, provider ownership, and process evidence agree."
        )
      case .notRunning:
        return (.drifted, process.message)
      case .unavailable:
        return (.blocked, process.message)
      }
    case .blocked:
      preconditionFailure("blocked providers are classified before the provider switch")
    }
  }
}
