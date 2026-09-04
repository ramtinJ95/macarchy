import Foundation
import ThemeCore

struct EnvironmentSlackPreset: Sendable {
  static let manualEntryID = "slack_manual_import"
  static let bundleURL = URL(filePath: "/Applications/Slack.app")

  let bundleURL: URL

  init(bundleURL: URL = Self.bundleURL) {
    self.bundleURL = bundleURL.standardizedFileURL
  }

  func supportedVersion() throws -> String {
    let plistURL = bundleURL.appending(path: "Contents/Info.plist")
    let data = try BoundedRegularFile.read(at: plistURL, maximumSize: 1_048_576).data
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let dictionary = plist as? [String: Any],
      let value = dictionary["CFBundleShortVersionString"] as? String,
      let version = Version(value), let minimum = Version(SlackAdapter.minimumVersion)
    else {
      throw EnvironmentLifecycleError.blocked(
        "Slack must have a parseable CFBundleShortVersionString"
      )
    }
    guard version >= minimum else {
      throw EnvironmentLifecycleError.blocked(
        "Slack \(value) is unsupported; version \(SlackAdapter.minimumVersion) or newer is required"
      )
    }
    return value
  }

  func payload(stateRoot: URL) throws -> String {
    let manifest = try ReconciliationStatusStore(root: stateRoot).activeManifest()
    guard manifest.rendererVersions[SlackAdapter.id] == SlackAdapter.rendererVersion else {
      throw EnvironmentLifecycleError.blocked(
        "the active canonical generation does not contain a renderer-v2 Slack payload"
      )
    }
    let payload = try ManualThemePayloadStore(root: stateRoot).payload(targetID: SlackAdapter.id)
    guard SlackAdapter.isValidRendererV2Payload(payload) else {
      throw EnvironmentLifecycleError.blocked(
        "the active canonical Slack payload is not a valid four-color renderer-v2 value"
      )
    }
    return payload
  }

  func entry(stateRoot: URL, applied: Bool) -> EnvironmentEntryInspection {
    do {
      let version = try supportedVersion()
      let payload = try payload(stateRoot: stateRoot).trimmingCharacters(in: .newlines)
      return EnvironmentEntryInspection(
        id: Self.manualEntryID,
        path: bundleURL.path,
        status: applied ? "external" : "authority_required",
        ownership: "external",
        message: applied
          ? "Slack \(version) is compatible. Manual import is required for each workspace: \(SlackAdapter.importInstructions) Payload: \(payload)"
          : "Slack package and payload are ready; environment apply must publish manual-import authority. \(SlackAdapter.importInstructions) Payload: \(payload)",
        evidence: nil
      )
    } catch {
      return EnvironmentEntryInspection(
        id: Self.manualEntryID,
        path: bundleURL.path,
        status: "unsupported",
        ownership: "external",
        message: String(describing: error),
        evidence: nil
      )
    }
  }

  private struct Version: Comparable {
    let components: [Int]

    init?(_ value: String) {
      let parts = value.split(separator: ".", omittingEmptySubsequences: false)
      let parsed = parts.compactMap { Int($0) }
      guard parts.count == 3,
        parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
        parsed.count == parts.count
      else { return nil }
      components = parsed
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
      for index in lhs.components.indices {
        if lhs.components[index] != rhs.components[index] {
          return lhs.components[index] < rhs.components[index]
        }
      }
      return false
    }
  }
}
