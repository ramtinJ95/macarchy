import Foundation
import ThemeCore

/// Exit 77 distinguishes absent/denied consent from a failed native probe.
/// The bar records that exit independently of the AX helper's result.
struct SetupAppearanceCheck: Encodable {
  enum Status: String, Encodable {
    case verified
    case notGranted = "not_granted"
    case failed
  }
  let status: Status
  let code: Int32?
  let message: String

  var exitStatus: Int32 { status == .verified ? 0 : status == .notGranted ? 77 : 1 }

  static func inspect(verify: () throws -> Void = MacOSAppearanceEvents.verify) -> Self {
    do {
      try verify()
      return .init(
        status: .verified, code: nil,
        message:
          "System Events Automation verified for this invocation: \(MacOSAppearanceEvents.launchContext)"
      )
    } catch let error as MacOSAppearanceEvents.Failure {
      return .init(
        status: error.code == -1743 || error.code == -1744 ? .notGranted : .failed,
        code: error.code, message: error.description)
    } catch {
      return .init(status: .failed, code: nil, message: String(describing: error))
    }
  }
}
