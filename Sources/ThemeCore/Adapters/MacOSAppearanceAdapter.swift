import Foundation

enum MacOSAppearanceAdapterError: Error, CustomStringConvertible, Sendable {
  case controlUnavailable
  case unreadablePreference(String)

  var description: String {
    switch self {
    case .controlUnavailable:
      "macOS appearance control is unavailable at /usr/bin/osascript"
    case .unreadablePreference(let value):
      "Cannot interpret the macOS AppleInterfaceStyle preference '\(value)'"
    }
  }
}

struct MacOSAppearanceAdapter: Sendable {
  static let id = "macos-appearance"
  private static let controlURL = URL(filePath: "/usr/bin/osascript")

  private let activationLock: ActivationLock
  let controlIsAvailable: @Sendable () -> Bool
  let currentAppearance: @Sendable () throws -> ThemeAppearance
  let processRunner: ProcessRunner

  init(
    root: URL,
    controlIsAvailable: @escaping @Sendable () -> Bool,
    currentAppearance: @escaping @Sendable () throws -> ThemeAppearance,
    processRunner: ProcessRunner
  ) {
    activationLock = ActivationLock(root: root)
    self.controlIsAvailable = controlIsAvailable
    self.currentAppearance = currentAppearance
    self.processRunner = processRunner
  }

  static func live(root: URL, processRunner: ProcessRunner = .live) -> Self {
    Self(
      root: root,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: controlURL.path)
      },
      currentAppearance: readCurrentAppearance,
      processRunner: processRunner
    )
  }

  func preflight() throws -> ThemeAppearance {
    guard controlIsAvailable() else {
      throw MacOSAppearanceAdapterError.controlUnavailable
    }
    return try currentAppearance()
  }

  func inspection(desiredAppearance: ThemeAppearance?) -> AdapterInspection {
    do {
      let observed = try preflight()
      if let desiredAppearance, observed != desiredAppearance {
        return AdapterInspection(
          adapterID: Self.id,
          requirement: .required,
          status: .drifted,
          message:
            "macOS appearance differs from the active theme; reconciliation will request a live System Events update"
        )
      }
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message:
          "Appearance state is readable and /usr/bin/osascript is executable; Apple Events authorization is untested until a change is required"
      )
    } catch {
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        status: .failed,
        message: String(describing: error)
      )
    }
  }

  func reconciliation(
    desiredAppearance: @escaping @Sendable () throws -> ThemeAppearance
  ) -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .required) {
      try activationLock.withLock {
        let observed: ThemeAppearance
        do {
          observed = try preflight()
        } catch {
          return AdapterOutcome(status: .failed, message: String(describing: error))
        }
        let desiredAppearance = try desiredAppearance()

        if observed == desiredAppearance {
          return AdapterOutcome(status: .applied)
        }

        let command = try processRunner.run(
          ProcessRequest(
            executableURL: Self.controlURL,
            arguments: ["-e", Self.setAppearanceScript(desiredAppearance)],
            timeout: 2
          )
        )
        guard command.terminationStatus == 0 else {
          return AdapterOutcome(
            status: .failed,
            message: command.output.isEmpty
              ? "System Events rejected the appearance change"
              : command.output
          )
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
    }
  }

  private static func setAppearanceScript(_ appearance: ThemeAppearance) -> String {
    let enabled = appearance == .dark ? "true" : "false"
    return
      "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)"
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
