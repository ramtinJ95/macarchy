import Foundation
import ThemeCore

struct VersionJSONReport: Encodable {
  let schemaVersion = 1
  let version: String
  let revision: String
  let platform: String
  let installation: InstallationOwnership
}
