import Foundation
import ThemeCore

struct PreferencesPlan: Sendable {
  let state: PreferencesState
  let after: [PreferenceOwnership]
  let changes: [PreferenceChange]
  let report: PreferencesReport
}

struct PreferencesLifecycle: Sendable {
  let native: NativeMacOSPreferences
  var checkpoint: @Sendable (Int) throws -> Void = { _ in }

  static let live = Self(native: .live)
  private static let lock = ProcessScopedFileLock<PreferencesError>(
    filename: "preferences.lock",
    cannotCreateRunDirectory: { _, reason in .invalid(reason) },
    operationError: { operation, code in
      .invalid("Cannot \(operation) preferences lock (errno \(code)).")
    })

  func plan(context: PreferencesContext, desired: MacOSPreferencesProfile) throws -> PreferencesPlan
  {
    let store = PreferencesStore(context: context)
    let state = try store.read()
    guard state.pending == nil else {
      throw PreferencesError.recoveryRequired(
        "An interrupted apply must be recovered before replanning.")
    }
    let selected = desired.selected
    let owned = Dictionary(uniqueKeysWithValues: state.owned.map { ($0.key, $0) })
    let keys = Set(selected.keys).union(owned.keys).sorted { $0.rawValue < $1.rawValue }
    var after = [PreferenceOwnership]()
    var changes = [PreferenceChange]()
    var rows = [PreferencesReport.Row]()
    for key in keys {
      let current = try native.read(key)
      let old = owned[key]
      guard old == nil || old?.applied == current else {
        throw PreferencesError.drift(
          "\(key.rawValue) is \(current), not the last managed value \(old!.applied). "
            + "Preserved it. Restore the last managed value manually before apply or teardown.")
      }
      let target: Bool
      let action: String
      if let value = selected[key] {
        target = value
        after.append(.init(key: key, original: old?.original ?? current, applied: value))
        action = old == nil ? "claim" : current == value ? "none" : "update"
      } else {
        // This branch exists only for a key with retained ownership.
        target = old!.original
        action = "restore"
      }
      rows.append(
        .init(
          key: key, title: key.title, current: current, desired: selected[key],
          original: old?.original ?? current, target: target, action: action))
      if action != "none" { changes.append(.init(key: key, before: current, after: target)) }
    }
    struct Approval: Encodable {
      let target: String
      let stateRoot: String
      let before: [PreferenceOwnership]
      let after: [PreferenceOwnership]
      let changes: [PreferenceChange]
    }
    let digest =
      changes.isEmpty
      ? nil
      : try sha256Digest(
        Data(
          renderJSON(
            Approval(
              target: context.targetIdentity, stateRoot: context.stateRoot.standardizedFileURL.path,
              before: state.owned, after: after, changes: changes)
          ).utf8))
    return PreferencesPlan(
      state: state, after: after, changes: changes,
      report: PreferencesReport(
        outcome: changes.isEmpty ? (keys.isEmpty ? "disabled" : "no_change") : "ready",
        receiptPath: store.url.path, approvalDigest: digest, preferences: rows,
        actions: rows.filter { $0.action != "none" }.map {
          .init(
            id: "\($0.action)_\($0.key.rawValue)",
            message: "\($0.action) \($0.key.rawValue): \($0.current) → \($0.target)")
        },
        message: rows.isEmpty
          ? "No native preferences are managed."
          : rows.map {
            "\($0.key.rawValue): \($0.current) → \($0.target) [\($0.action)]"
          }.joined(separator: "; ")))
  }

  func inspect(
    context: PreferencesContext, desired: MacOSPreferencesProfile, status: Bool = false
  ) -> PreferencesReport {
    do {
      var report = try plan(context: context, desired: desired).report
      if status, report.outcome == "ready" { report.outcome = "changes_required" }
      return report
    } catch { return .failure(error, context: context) }
  }

  func apply(
    context: PreferencesContext, desired: MacOSPreferencesProfile, approval: String?,
    deferFinalization: Bool = false
  ) throws -> PreferencesReport {
    let reviewed = try plan(context: context, desired: desired)
    guard reviewed.report.approvalDigest == approval else {
      throw PreferencesError.invalid(
        "Supply exactly --approve from the current preferences plan; stale or extra approval refused."
      )
    }
    guard !reviewed.changes.isEmpty else { return reviewed.report }
    return try Self.lock.withLock(root: context.stateRoot) {
      let fresh = try plan(context: context, desired: desired)
      guard fresh.report.approvalDigest == approval else {
        throw PreferencesError.drift(
          "The reviewed preferences changed before mutation. Review a fresh plan.")
      }
      return try applyLocked(context: context, plan: fresh, deferFinalization: deferFinalization)
    }
  }

  private func applyLocked(
    context: PreferencesContext, plan: PreferencesPlan, deferFinalization: Bool
  ) throws -> PreferencesReport {
    let store = PreferencesStore(context: context)
    var state = plan.state
    var transaction = PreferencesTransaction(after: plan.after, changes: plan.changes)
    state.pending = transaction
    try store.write(state)
    do {
      for (index, change) in transaction.writes.enumerated() {
        guard try native.read(change.key) == change.before else {
          throw PreferencesError.drift(
            "\(change.key.rawValue) changed immediately before its setter.")
        }
        transaction.attemptedWrites = index + 1
        // A crash while waiting for the OS is indistinguishable from a late setter.
        transaction.uncertainWrite = true
        state.pending = transaction
        try store.write(state)
        try native.write(change.key, change.after)
        transaction.uncertainWrite = false
        state.pending = transaction
        try store.write(state)
        try checkpoint(index + 1)
        guard try native.read(change.key) == change.after else {
          throw PreferencesError.drift("\(change.key.rawValue) did not retain its requested value.")
        }
      }
      try verify(plan.changes, owned: plan.after)
      transaction.phase = .ready
      state.pending = transaction
      try store.write(state)
    } catch let error as PreferencesInterruption {
      throw error
    } catch {
      if case PreferencesError.uncertain = error {
        // The pre-setter journal already records uncertainty. A second write
        // could mask this outcome with an unrelated persistence failure.
        throw error
      }
      // A confirmed rejection is not an in-flight setter. A failed receipt write,
      // however, leaves its persisted uncertain marker for explicit recovery.
      if case PreferencesError.unavailable = error {
        transaction.uncertainWrite = false
        state.pending = transaction
        try store.write(state)
      }
      do { try rollbackLocked(context: context, acknowledgeUncertainWrite: false) } catch let
        rollbackError
      {
        throw PreferencesError.recoveryRequired("\(error); rollback stopped: \(rollbackError)")
      }
      throw PreferencesError.rolledBack(String(describing: error))
    }
    if !deferFinalization {
      do { try commitLocked(context: context) } catch {
        throw PreferencesError.recoveryRequired(
          "Preference changes are staged but finalization stopped: \(error)")
      }
    }
    var report = plan.report
    report.outcome = deferFinalization ? "pending_commit" : "applied"
    report.mutated = true
    report.approvalDigest = nil
    return report
  }

  /// Undo this apply, not ordinary teardown to the originally adopted values.
  func rollback(context: PreferencesContext, acknowledgeUncertainWrite: Bool = false) throws {
    try Self.lock.withLock(root: context.stateRoot) {
      try rollbackLocked(context: context, acknowledgeUncertainWrite: acknowledgeUncertainWrite)
    }
  }

  private func rollbackLocked(context: PreferencesContext, acknowledgeUncertainWrite: Bool) throws {
    let store = PreferencesStore(context: context)
    var state = try store.read()
    guard var transaction = state.pending else { return }
    guard !transaction.uncertainWrite || acknowledgeUncertainWrite else {
      throw PreferencesError.recoveryRequired(
        "A setter may still be running. Inspect the OS, wait for it to settle, then use preferences recover --acknowledge-uncertain-write."
      )
    }
    transaction.uncertainWrite = false
    transaction.phase = .rollingBack
    state.pending = transaction
    try store.write(state)
    while transaction.attemptedWrites > 0 {
      let change = transaction.writes[transaction.attemptedWrites - 1]
      let current = try native.read(change.key)
      if current != change.before {
        // Boolean settings have no CAS or writer identity. A matching transaction
        // value cannot distinguish a concurrent external edit; do not claim it can.
        transaction.uncertainWrite = true
        state.pending = transaction
        try store.write(state)
        do {
          try native.write(change.key, change.before)
          transaction.uncertainWrite = false
          state.pending = transaction
          try store.write(state)
        } catch {
          if case PreferencesError.unavailable = error {
            transaction.uncertainWrite = false
            state.pending = transaction
            try store.write(state)
          }
          throw error
        }
      }
      guard try native.read(change.key) == change.before else {
        throw PreferencesError.recoveryRequired(
          "Cannot verify restoration of \(change.key.rawValue).")
      }
      transaction.attemptedWrites -= 1
      state.pending = transaction
      try store.write(state)
    }
    state.pending = nil
    try store.write(state)
  }

  func commit(context: PreferencesContext) throws {
    try Self.lock.withLock(root: context.stateRoot) { try commitLocked(context: context) }
  }

  private func commitLocked(context: PreferencesContext) throws {
    let store = PreferencesStore(context: context)
    var state = try store.read()
    guard let transaction = state.pending else { return }
    guard transaction.phase == .ready, !transaction.uncertainWrite else {
      throw PreferencesError.recoveryRequired("The preferences transaction is not ready to commit.")
    }
    try verify(transaction.changes, owned: transaction.after)
    state.owned = transaction.after
    state.pending = nil
    try store.write(state)
  }

  func teardown(context: PreferencesContext, dryRun: Bool) throws -> PreferencesReport {
    let preview = try plan(context: context, desired: .init())
    if dryRun || preview.changes.isEmpty { return preview.report }
    // The explicit teardown command authorizes only guarded restoration of our receipts.
    return try apply(context: context, desired: .init(), approval: preview.report.approvalDigest)
  }

  private func verify(_ changes: [PreferenceChange], owned: [PreferenceOwnership]) throws {
    var targets = Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.after) })
    for record in owned { targets[record.key] = record.applied }
    for (key, value) in targets.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      guard try native.read(key) == value else {
        throw PreferencesError.drift("\(key.rawValue) changed before transaction finalization.")
      }
    }
  }
}

enum PreferencesInterruption: Error { case injected }
