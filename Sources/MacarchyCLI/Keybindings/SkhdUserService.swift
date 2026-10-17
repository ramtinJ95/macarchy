import Foundation
import ThemeCore

/// skhd's native LaunchAgent ownership (ADR-0276).
enum SkhdServicePolicy: NativeUserServicePolicy {
  static let name = "skhd"
  static let label = "com.koekeishiya.skhd"
  static let supportedVersion = "0.3.9"
  static let receiptPath = "keybindings/service.json"
  static let nativeStopDisablesJob = false

  static func lifecycleError(_ message: String) -> any Error {
    KeybindingsApplyError.lifecycle(message)
  }
}

typealias SkhdUserService = NativeUserService<SkhdServicePolicy>
typealias SkhdServiceOwnershipStore = NativeUserServiceOwnershipStore<SkhdServicePolicy>

extension NativeUserService where Policy == SkhdServicePolicy {
  static var live: Self { Self(runner: .live, process: .live) }

  init(runner: ProcessRunner, process: KeybindingProcessInspector) {
    self.init(runner: runner) {
      let observed = process.inspect()
      switch observed.status {
      case .running: return .running(processID: observed.processID)
      case .notRunning: return .notRunning
      case .unsupported, .unavailable: return .indeterminate(observed.message)
      }
    }
  }
}
