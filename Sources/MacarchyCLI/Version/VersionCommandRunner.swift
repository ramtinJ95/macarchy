import Foundation
import ThemeCore

struct VersionCommandRunner: Sendable {
  let buildInformation: @Sendable () throws -> MacarchyBuildInformation

  static let live = VersionCommandRunner(
    buildInformation: { try RuntimeEnvironment.live.buildInformation() }
  )

  func executeConcise() throws -> String {
    try buildInformation().version
  }

  func execute(json: Bool) throws -> String {
    let information = try buildInformation()
    if json {
      return try renderJSON(
        VersionJSONReport(
          version: information.version,
          revision: information.revision,
          platform: information.platform,
          installation: information.installation
        )
      )
    }
    return "Macarchy \(information.version) (\(information.revision), "
      + "\(information.platform), \(information.installation.rawValue))"
  }
}
