import Foundation

/// Original, last confirmed preset and write-ahead intent. Both applied and pending are owned
/// values: the helper can mutate the system before its reply or the confirmation write fails.
package struct MacOSAccentRecord: Codable, Equatable, Sendable {
  package let original: MacOSAccent
  package var applied: MacOSAccent
  package var pending: MacOSAccent? = nil
}

package struct MacOSAccentStore: Sendable {
  let url: URL

  package init(root: URL) { url = StateLayout(root: root).macOSAccentRecord }

  package func load() throws -> MacOSAccentRecord? {
    guard let file = try BoundedRegularFile.readIfPresent(at: url) else { return nil }
    let record = try JSONDecoder().decode(MacOSAccentRecord.self, from: file.data)
    guard record.original.isSettable, record.applied.isSettable,
      record.pending?.isSettable != false
    else {
      throw MacOSLookError.unavailable(
        "Invalid accent restoration record: hardware-matched accents cannot be restored")
    }
    return record
  }

  func persist(_ record: MacOSAccentRecord) throws {
    try StateFile.replaceByRename(
      at: url, temporaryName: ".accent-\(UUID().uuidString).json", temporaryWriteOptions: [],
      encode: { try prettyJSONDocument(record) },
      tooLargeError: MacOSLookError.unavailable("Accent record exceeds the file limit"),
      renameError: { MacOSLookError.unavailable("Cannot replace accent record (errno \($0))") })
  }

  package func remove() throws { try FileManager.default.removeItem(at: url) }
}

package struct MacOSAccentRestore: Sendable {
  package let message: String?
  package let mutated: Bool
  package let consumesRecord: Bool
}

package struct MacOSAccentAdapter: Sendable {
  package static let id = "macos-accent"
  let root: URL
  let helper: MacOSLookHelper

  package init(root: URL, helper: MacOSLookHelper = .sibling()) {
    self.root = root
    self.helper = helper
  }

  private static func isUnsupported(_ error: any Error) -> Bool {
    guard let error = error as? MacOSLookError else { return false }
    switch error {
    case .helperMissing, .untestedBuild, .unavailable: return true
    case .helperFailed, .unreadableReply: return false
    }
  }

  // This optional system integration never blocks canonical activation.
  func preflight() {}

  private func desired() throws -> MacOSAccent {
    let theme = try ThemeGenerationReader(root: root).activeManifest().normalizedTheme(root: root)
    return MacOSAccent.nearest(to: theme.semantic.accent)
  }

  func inspection() -> AdapterInspection {
    do { try helper.requireAccentSupport() } catch {
      return AdapterInspection(
        .macOSAccent, status: Self.isUnsupported(error) ? .unsupported : .failed,
        message: String(describing: error))
    }
    do {
      let current = try helper.accent()
      let desired = try desired()
      return AdapterInspection(
        .macOSAccent, status: current == desired ? .ready : .drifted,
        message: "Supported macOS accent control; current \(current.name), desired \(desired.name)."
      )
    } catch {
      return AdapterInspection(.macOSAccent, status: .failed, message: String(describing: error))
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(.macOSAccent) {
      try ActivationLock(root: root).withLock {
        reconcileHoldingActivationLock(desired: try desired())
      }
    }
  }

  /// The caller holds the activation lock; exposed internally for fake-helper tests.
  func reconcileHoldingActivationLock(desired: MacOSAccent) -> AdapterOutcome {
    do { try helper.requireAccentSupport() } catch {
      return AdapterOutcome(
        status: Self.isUnsupported(error) ? .unsupported : .failed,
        message: String(describing: error))
    }
    do {
      let current = try helper.accent()
      let store = MacOSAccentStore(root: root)
      let previous = try store.load()
      guard current != desired else {
        if var record = previous, record.pending == desired {
          record.applied = desired
          record.pending = nil
          try store.persist(record)
        }
        return AdapterOutcome(
          status: .applied, message: "Current and desired accent: \(desired.name).")
      }
      guard current != .hardware else {
        throw MacOSLookError.unavailable(
          "the hardware-matched accent cannot be restored once changed, so it is left unchanged")
      }
      var record = previous ?? MacOSAccentRecord(original: current, applied: current)
      // Resolve an earlier interrupted set even if the desired theme has since changed.
      if record.pending == current { record.applied = current }
      record.pending = desired
      try store.persist(record)
      let applied = try helper.setAccent(desired)
      guard applied == desired else {
        throw MacOSLookError.helperFailed(
          "accent read back \(applied.name), expected \(desired.name)")
      }
      record.applied = applied
      record.pending = nil
      try store.persist(record)
      return AdapterOutcome(
        status: .applied, message: "Current and desired accent: \(desired.name).")
    } catch {
      return AdapterOutcome(status: .failed, message: String(describing: error))
    }
  }

  package func restorationPlan() throws -> MacOSAccentRestore {
    try ActivationLock(root: root).withLock { try restoreHoldingActivationLock(dryRun: true) }
  }

  /// Three-way restoration. Throws on failure and retains the record for a retry. The caller
  /// removes it only after its enclosing teardown/disable operation succeeds.
  package func restoreHoldingActivationLock(dryRun: Bool = false) throws -> MacOSAccentRestore {
    guard let record = try MacOSAccentStore(root: root).load() else {
      return MacOSAccentRestore(message: nil, mutated: false, consumesRecord: false)
    }
    try helper.requireAccentSupport()
    let current = try helper.accent()
    if current == record.original {
      return MacOSAccentRestore(
        message: "The \(current.name) accent is already the original.", mutated: false,
        consumesRecord: true)
    }
    guard current == record.applied || current == record.pending else {
      return MacOSAccentRestore(
        message: "Kept the \(current.name) accent, which was changed after setup.", mutated: false,
        consumesRecord: true)
    }
    if !dryRun {
      let restored = try helper.setAccent(record.original)
      guard restored == record.original else {
        throw MacOSLookError.helperFailed(
          "accent restore read back \(restored.name), expected \(record.original.name)")
      }
    }
    return MacOSAccentRestore(
      message:
        "\(dryRun ? "Would restore" : "Restored") the original \(record.original.name) accent.",
      mutated: !dryRun, consumesRecord: true)
  }
}
