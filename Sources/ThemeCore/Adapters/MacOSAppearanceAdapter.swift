import Foundation

package enum MacOSAppearanceAdapterError: Error, CustomStringConvertible, Sendable {
  case controlUnavailable
  case unreadablePreference(String)

  package var description: String {
    switch self {
    case .controlUnavailable:
      "macOS appearance control is supported on macOS 26 only"
    case .unreadablePreference(let value):
      "Cannot interpret the macOS AppleInterfaceStyle preference '\(value)'"
    }
  }
}

package struct MacOSAppearanceAdapter: Sendable {
  package static let id = "macos-appearance"

  private let activationLock: ActivationLock
  let controlIsAvailable: @Sendable () -> Bool
  let currentAppearance: @Sendable () throws -> ThemeAppearance
  let writeAppearance: @Sendable (ThemeAppearance) throws -> Void
  let verifyAutomation: @Sendable () throws -> Void
  let authorizeInteraction: (@Sendable () throws -> Void)?

  init(
    root: URL,
    controlIsAvailable: @escaping @Sendable () -> Bool,
    currentAppearance: @escaping @Sendable () throws -> ThemeAppearance,
    writeAppearance: @escaping @Sendable (ThemeAppearance) throws -> Void,
    verifyAutomation: @escaping @Sendable () throws -> Void = {},
    authorizeInteraction: (@Sendable () throws -> Void)? = nil
  ) {
    activationLock = ActivationLock(root: root)
    self.controlIsAvailable = controlIsAvailable
    self.currentAppearance = currentAppearance
    self.writeAppearance = writeAppearance
    self.verifyAutomation = verifyAutomation
    self.authorizeInteraction = authorizeInteraction
  }

  package static func live(root: URL, allowAutomationConsent: Bool = false) -> Self {
    Self(
      root: root,
      controlIsAvailable: {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
      },
      currentAppearance: readCurrentAppearance,
      writeAppearance: MacOSAppearanceEvents.write,
      verifyAutomation: MacOSAppearanceEvents.verify,
      authorizeInteraction: allowAutomationConsent
        ? MacOSAppearanceEvents.requestInteractiveConsent : nil
    )
  }

  package func preflight() throws -> ThemeAppearance {
    guard controlIsAvailable() else {
      throw MacOSAppearanceAdapterError.controlUnavailable
    }
    return try currentAppearance()
  }

  package func apply(_ desiredAppearance: ThemeAppearance) async throws -> AdapterResult {
    let pending = reconciliation { desiredAppearance }
    let outcome = try await pending.run()
    return AdapterResult(
      adapterID: pending.id,
      requirement: pending.requirement,
      status: outcome.status,
      message: outcome.message
    )
  }

  package func inspection(desiredAppearance: ThemeAppearance?) -> AdapterInspection {
    do {
      let observed = try preflight()
      try verifyAutomation()
      if let desiredAppearance, observed != desiredAppearance {
        return AdapterInspection(
          .macOSAppearance,
          status: .drifted,
          message:
            "macOS appearance differs from the active theme; reconciliation will request a live System Events update"
        )
      }
      return AdapterInspection(
        .macOSAppearance,
        message:
          "Appearance and System Events Automation are verified for this invocation only (\(MacOSAppearanceEvents.launchContext)); other launch contexts are not verified. Inspection may start Apple's System Events query helper; it never prompts."
      )
    } catch {
      return AdapterInspection(
        .macOSAppearance,
        status: .failed,
        message: String(describing: error)
      )
    }
  }

  func reconciliation(
    desiredAppearance: @escaping @Sendable () throws -> ThemeAppearance
  ) -> AdapterReconciliation {
    AdapterReconciliation(.macOSAppearance) {
      // A human's native consent dialog must not hold the canonical activation lock.
      // The candidate only decides whether consent is needed; current is re-read inside
      // the lock after consent, so an older interactive request cannot set a stale theme.
      if let authorizeInteraction, try preflight() != desiredAppearance() {
        try authorizeInteraction()
      }
      return try activationLock.withLock {
        try applyAppearanceHoldingActivationLock(desiredAppearance())
      }
    }
  }

  /// The caller holds the activation lock through restoration and canonical retirement.
  package func applyHoldingActivationLock(_ desiredAppearance: ThemeAppearance) throws
    -> AdapterResult
  {
    let outcome = try applyAppearanceHoldingActivationLock(desiredAppearance)
    return AdapterResult(
      adapterID: Self.id, requirement: .required, status: outcome.status, message: outcome.message)
  }

  private func applyAppearanceHoldingActivationLock(_ desiredAppearance: ThemeAppearance) throws
    -> AdapterOutcome
  {
    let observed: ThemeAppearance
    do {
      observed = try preflight()
    } catch {
      return AdapterOutcome(status: .failed, message: String(describing: error))
    }

    if observed == desiredAppearance {
      return AdapterOutcome(status: .applied)
    }

    do {
      try writeAppearance(desiredAppearance)
    } catch {
      return AdapterOutcome(status: .failed, message: String(describing: error))
    }

    let appliedAppearance = try currentAppearance()
    guard appliedAppearance == desiredAppearance else {
      return AdapterOutcome(
        status: .drifted,
        message:
          "System Events completed, but macOS remains \(appliedAppearance.rawValue); expected \(desiredAppearance.rawValue)"
      )
    }
    return AdapterOutcome(status: .applied)
  }

  private static func readCurrentAppearance() throws -> ThemeAppearance {
    let key = "AppleInterfaceStyle" as NSString
    guard
      let value = CFPreferencesCopyValue(
        key,
        kCFPreferencesAnyApplication,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
      )
    else {
      return .light
    }
    guard let style = value as? String else {
      throw MacOSAppearanceAdapterError.unreadablePreference(String(describing: value))
    }
    switch style.lowercased() {
    case "dark": return .dark
    case "light": return .light
    default: throw MacOSAppearanceAdapterError.unreadablePreference(style)
    }
  }
}
