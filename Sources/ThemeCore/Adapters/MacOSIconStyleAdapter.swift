import Foundation

/// Original, last confirmed preset and write-ahead intent. Both applied and pending are owned
/// values: the helper can mutate the system before its reply or the confirmation write fails.
package struct MacOSIconStyleRecord: Codable, Equatable, Sendable {
  package let original: MacOSIconStyle
  package var applied: MacOSIconStyle
  package var pending: MacOSIconStyle? = nil
}

package struct MacOSIconStyleStore: Sendable {
  let url: URL

  package init(root: URL) { url = StateLayout(root: root).macOSIconStyleRecord }

  package func load() throws -> MacOSIconStyleRecord? {
    guard let file = try BoundedRegularFile.readIfPresent(at: url) else { return nil }
    let record = try JSONDecoder().decode(MacOSIconStyleRecord.self, from: file.data)
    guard record.original.isValidStoredValue, record.applied.isValidStoredValue,
      record.pending?.isValidStoredValue != false
    else {
      throw MacOSLookError.unavailable(
        "Invalid icon style restoration record")
    }
    return record
  }

  func persist(_ record: MacOSIconStyleRecord) throws {
    try StateFile.replaceByRename(
      at: url, temporaryName: ".icon-style-\(UUID().uuidString).json", temporaryWriteOptions: [],
      encode: { try prettyJSONDocument(record) },
      tooLargeError: MacOSLookError.unavailable("Icon style record exceeds the file limit"),
      renameError: { MacOSLookError.unavailable("Cannot replace icon style record (errno \($0))") })
  }

  package func remove() throws { try FileManager.default.removeItem(at: url) }
}

package struct MacOSIconStyleAdapter: Sendable {
  package static let id = "macos-icon-style"
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

  private func desired() throws -> MacOSIconStyle? {
    let theme = try ThemeGenerationReader(root: root).activeManifest().normalizedTheme(root: root)
    return theme.macos?.iconStyle.map {
      MacOSIconStyle.desired($0, appearance: theme.appearance, accent: theme.semantic.accent)
    }
  }

  func inspection() -> AdapterInspection {
    let target: MacOSIconStyle
    do {
      guard let desired = try desired() else {
        return AdapterInspection(
          .macOSIconStyle, status: .ready,
          message: "theme does not set an icon style")
      }
      target = desired
    } catch {
      return AdapterInspection(.macOSIconStyle, status: .failed, message: String(describing: error))
    }
    do { try helper.requireIconStyleSupport() } catch {
      return AdapterInspection(
        .macOSIconStyle, status: Self.isUnsupported(error) ? .unsupported : .failed,
        message: String(describing: error))
    }
    do {
      let current = try helper.iconStyle()
      let desired = target.keepingTint(from: current)
      return AdapterInspection(
        .macOSIconStyle, status: current == desired ? .ready : .drifted,
        message:
          "Supported macOS icon & widget style control; current \(current.name), desired \(desired.name)."
      )
    } catch {
      return AdapterInspection(.macOSIconStyle, status: .failed, message: String(describing: error))
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(.macOSIconStyle) {
      try ActivationLock(root: root).withLock {
        reconcileHoldingActivationLock(desired: try desired())
      }
    }
  }

  /// The caller holds the activation lock; exposed internally for fake-helper tests.
  func reconcileHoldingActivationLock(desired target: MacOSIconStyle?) -> AdapterOutcome {
    guard let target else {
      return AdapterOutcome(status: .applied, message: "theme does not set an icon style")
    }
    do { try helper.requireIconStyleSupport() } catch {
      return AdapterOutcome(
        status: Self.isUnsupported(error) ? .unsupported : .failed,
        message: String(describing: error))
    }
    do {
      let current = try helper.iconStyle()
      let desired = target.keepingTint(from: current)
      let store = MacOSIconStyleStore(root: root)
      let previous = try store.load()
      guard current != desired else {
        if var record = previous, record.pending == desired {
          record.applied = desired
          record.pending = nil
          try store.persist(record)
        }
        return AdapterOutcome(
          status: .applied, message: "Current and desired icon style: \(desired.name).")
      }
      var record = previous ?? MacOSIconStyleRecord(original: current, applied: current)
      // Resolve an earlier interrupted set even if the desired theme has since changed.
      if record.pending == current { record.applied = current }
      record.pending = desired
      try store.persist(record)
      let applied = try helper.setIconStyle(target)
      guard applied == desired else {
        throw MacOSLookError.helperFailed(
          "icon style read back \(applied.name), expected \(desired.name)")
      }
      record.applied = applied
      record.pending = nil
      try store.persist(record)
      return AdapterOutcome(
        status: .applied, message: "Current and desired icon style: \(desired.name).")
    } catch {
      return AdapterOutcome(status: .failed, message: String(describing: error))
    }
  }

  package func restorationPlan() throws -> MacOSLookRestore {
    try ActivationLock(root: root).withLock { try restoreHoldingActivationLock(dryRun: true) }
  }

  /// Three-way restoration. Throws on failure and retains the record for a retry. The caller
  /// removes it only after its enclosing teardown/disable operation succeeds.
  package func restoreHoldingActivationLock(dryRun: Bool = false) throws -> MacOSLookRestore {
    guard let record = try MacOSIconStyleStore(root: root).load() else {
      return MacOSLookRestore(message: nil, mutated: false, consumesRecord: false)
    }
    try helper.requireIconStyleSupport()
    let current = try helper.iconStyle()
    if current == record.original {
      return MacOSLookRestore(
        message: "The \(current.name) icon style is already the original.", mutated: false,
        consumesRecord: true)
    }
    guard current == record.applied || current == record.pending else {
      return MacOSLookRestore(
        message: "Kept the \(current.name) icon style, which was changed after setup.",
        mutated: false,
        consumesRecord: true)
    }
    // Hardware tint cannot be recreated: restore only the original style, keeping current tint.
    let target =
      record.original.tint == "Hardware"
      ? MacOSIconStyle(style: record.original.style, tint: "-", custom: nil) : record.original
    let expected = target.keepingTint(from: current)
    if !dryRun {
      let restored = try helper.setIconStyle(target)
      guard restored == expected else {
        throw MacOSLookError.helperFailed(
          "icon style restore read back \(restored.name), expected \(expected.name)")
      }
    }
    return MacOSLookRestore(
      message:
        "\(dryRun ? "Would restore" : "Restored") the original \(record.original.style) icon style."
        + (record.original.tint == "Hardware"
          ? " Original hardware tint cannot be restored; kept the current tint."
          : " Tint restoration uses eight-bit sRGB precision."),
      mutated: !dryRun, consumesRecord: true)
  }
}
