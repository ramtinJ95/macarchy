import Foundation
import ThemeCore

/// yabai's native LaunchAgent ownership (ADR-0277).
enum YabaiServicePolicy: NativeUserServicePolicy {
  static let name = "yabai"
  static let label = "com.asmvik.yabai"
  static let supportedVersion = "7.1.25"
  static let receiptPath = "desktop/yabai/service.json"
  // Unlike skhd, yabai 7.1.25's native stop also disables the job (ADR-0278).
  static let nativeStopDisablesJob = true

  static func lifecycleError(_ message: String) -> any Error {
    YabaiDesktopError.lifecycle(message)
  }
}

typealias YabaiUserService = NativeUserService<YabaiServicePolicy>
typealias YabaiServiceOwnershipStore = NativeUserServiceOwnershipStore<YabaiServicePolicy>

extension NativeUserService where Policy == YabaiServicePolicy {
  static var live: Self {
    Self(runner: .live, process: YabaiLifecycleController.settledProcessEvidence)
  }

  init(
    runner: ProcessRunner,
    process: @escaping @Sendable () throws -> (processID: Int32, executablePath: String)?
  ) {
    self.init(runner: runner) {
      try process().map { .running(processID: $0.processID) } ?? .notRunning
    }
  }
}
