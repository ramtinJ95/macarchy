/// Whether a journaled environment operation removes its own journal.
enum EnvironmentJournalCommit {
  /// Journal removal is the last forward step, so a failed removal still rolls back.
  case immediate
  /// The journal outlives the call. A later finish, recovery or caller-owned completion removes
  /// it, and failures there do not roll back.
  case deferred
}

/// How a journaled environment operation reports a rollback that itself fails.
enum EnvironmentRollbackFailure {
  /// The rollback error propagates unchanged and the forward failure is dropped.
  case propagate
  /// Throws `"<failed>: <forward error>; rollback requires recovery: <rollback error>"`.
  case requiresRecovery(failed: String)
  /// Like `requiresRecovery`, but a failure to persist the rolling-back journal throws
  /// `"<failed>: <forward error>; rollback direction could not be persisted: <error>"`.
  case requiresRecoveryNamingDirection(failed: String)
}

extension EnvironmentStateStore {
  /// Persists `transaction`, runs `forward`, then commits as `commit` says. When a step fails
  /// after the journal is written, persists the rolling-back journal, runs `reverse` with it,
  /// removes the journal and throws `rolledBack(failure)`.
  ///
  /// Record semantics, checkpoints and lock order stay with the caller (ADR-0297, ADR-0132).
  func runJournaled<Value>(
    _ transaction: EnvironmentTransaction,
    commit: EnvironmentJournalCommit,
    forward: () throws -> Value,
    reverse: (EnvironmentTransaction) throws -> Void,
    rollbackFailure: EnvironmentRollbackFailure,
    rolledBack: (any Error) -> any Error
  ) throws -> Value {
    try writeTransaction(transaction)
    do {
      let value = try forward()
      if case .immediate = commit { try removeTransaction() }
      return value
    } catch {
      let failure = error
      let rollback = transaction.rollingBack
      switch rollbackFailure {
      case .propagate:
        try writeTransaction(rollback)
        try reverse(rollback)
        try removeTransaction()
      case .requiresRecovery(let failed):
        do {
          try writeTransaction(rollback)
          try reverse(rollback)
          try removeTransaction()
        } catch {
          throw EnvironmentLifecycleError.blocked(
            "\(failed): \(failure); rollback requires recovery: \(error)")
        }
      case .requiresRecoveryNamingDirection(let failed):
        do {
          try writeTransaction(rollback)
        } catch {
          throw EnvironmentLifecycleError.blocked(
            "\(failed): \(failure); rollback direction could not be persisted: \(error)")
        }
        do {
          try reverse(rollback)
          try removeTransaction()
        } catch {
          throw EnvironmentLifecycleError.blocked(
            "\(failed): \(failure); rollback requires recovery: \(error)")
        }
      }
      throw rolledBack(failure)
    }
  }
}
