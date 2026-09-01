import Darwin
import Foundation
import ThemeCore

enum YabaiProviderPlanStatus: String, Encodable, Sendable {
  case disabled
  case externallyManaged = "externally_managed"
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
  case blocked
}

struct YabaiProviderPlanInspection: Encodable, Sendable {
  let status: YabaiProviderPlanStatus
  let ownership: String
  let entryPoint: String
  let originalTarget: String?
  let source: String?
  let message: String
}

struct YabaiProviderPlanInspector: Sendable {
  func inspect(homeDirectory: URL, enabled: Bool) -> YabaiProviderPlanInspection {
    let configurationDirectory = homeDirectory.appending(
      path: ".config/yabai",
      directoryHint: .isDirectory
    )
    let entry = configurationDirectory.appending(path: "yabairc")
    if !enabled {
      return inspectDisabled(configurationDirectory, entry: entry)
    }

    var directoryMetadata = stat()
    guard lstat(configurationDirectory.path, &directoryMetadata) == 0 else {
      if errno == ENOENT {
        return inspection(
          .installRequired,
          ownership: "absent",
          entry: entry,
          message: "no yabai configuration entry exists"
        )
      }
      return inspection(
        .blocked,
        ownership: "uninspectable",
        entry: entry,
        message: systemError("cannot inspect yabai configuration directory")
      )
    }

    let directoryType = directoryMetadata.st_mode & S_IFMT
    if directoryType == S_IFLNK {
      return inspectDirectorySymlink(
        configurationDirectory,
        entry: entry
      )
    }
    guard directoryType == S_IFDIR else {
      return inspection(
        .blocked,
        ownership: fileType(directoryType),
        entry: entry,
        message: "yabai configuration path is not a directory or directory symlink"
      )
    }

    var entryMetadata = stat()
    guard lstat(entry.path, &entryMetadata) == 0 else {
      if errno == ENOENT {
        return inspection(
          .installRequired,
          ownership: "absent_entry",
          entry: entry,
          message: "the yabai directory exists without yabairc"
        )
      }
      return inspection(
        .blocked,
        ownership: "uninspectable",
        entry: entry,
        message: systemError("cannot inspect yabairc")
      )
    }
    let entryType = entryMetadata.st_mode & S_IFMT
    guard entryType == S_IFREG || entryType == S_IFLNK else {
      return inspection(
        .blocked,
        ownership: fileType(entryType),
        entry: entry,
        message: "yabairc is not a regular file or symbolic link"
      )
    }

    let ownership = entryType == S_IFLNK ? "entry_symlink" : "regular_file"
    let target = entryType == S_IFLNK ? readLink(entry) : nil
    let source = target.map { resolveLink($0, at: entry).path } ?? entry.path
    return inspection(
      .adoptionRequired,
      ownership: ownership,
      entry: entry,
      originalTarget: target,
      source: source,
      message: "existing yabairc requires explicit adoption"
    )
  }

  private func inspectDisabled(
    _ configurationDirectory: URL,
    entry: URL
  ) -> YabaiProviderPlanInspection {
    var metadata = stat()
    guard lstat(configurationDirectory.path, &metadata) == 0 else {
      return inspection(
        errno == ENOENT ? .disabled : .externallyManaged,
        ownership: errno == ENOENT ? "absent" : "uninspectable",
        entry: entry,
        message: errno == ENOENT
          ? "desktop role is disabled and no yabai configuration exists"
          : "desktop role is disabled; uninspectable yabai state remains externally managed"
      )
    }
    return inspection(
      .externallyManaged,
      ownership: fileType(metadata.st_mode & S_IFMT),
      entry: entry,
      message: "desktop role is disabled; existing yabai state remains externally managed"
    )
  }

  private func inspectDirectorySymlink(
    _ directory: URL,
    entry: URL
  ) -> YabaiProviderPlanInspection {
    guard let target = readLink(directory) else {
      return inspection(
        .blocked,
        ownership: "directory_symlink",
        entry: entry,
        message: "cannot read the yabai directory symlink"
      )
    }
    let resolved = resolveLink(target, at: directory)
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: resolved.path).sorted()
    } catch {
      return inspection(
        .blocked,
        ownership: "directory_symlink",
        entry: entry,
        originalTarget: target,
        message: "cannot inspect the yabai directory symlink target"
      )
    }
    guard names == ["yabairc"] else {
      return inspection(
        .blocked,
        ownership: "directory_symlink",
        entry: entry,
        originalTarget: target,
        source: resolved.appending(path: "yabairc").path,
        message: "directory-symlink adoption requires an inventory containing only yabairc; found "
          + (names.isEmpty ? "no entries" : names.joined(separator: ", "))
      )
    }

    return inspection(
      .adoptionRequired,
      ownership: "directory_symlink",
      entry: entry,
      originalTarget: target,
      source: resolved.appending(path: "yabairc").path,
      message: "the bounded yabai directory symlink requires explicit adoption"
    )
  }

  private func inspection(
    _ status: YabaiProviderPlanStatus,
    ownership: String,
    entry: URL,
    originalTarget: String? = nil,
    source: String? = nil,
    message: String
  ) -> YabaiProviderPlanInspection {
    YabaiProviderPlanInspection(
      status: status,
      ownership: ownership,
      entryPoint: entry.path,
      originalTarget: originalTarget,
      source: source,
      message: message
    )
  }

  private func readLink(_ url: URL) -> String? {
    let capacity = Int(PATH_MAX) + 1
    var buffer = [CChar](repeating: 0, count: capacity)
    let count = readlink(url.path, &buffer, capacity - 1)
    guard count >= 0 else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  private func resolveLink(_ target: String, at link: URL) -> URL {
    if target.hasPrefix("/") {
      return URL(filePath: target).standardizedFileURL
    }
    return link.deletingLastPathComponent().appending(path: target).standardizedFileURL
  }

  private func fileType(_ type: mode_t) -> String {
    switch type {
    case S_IFREG: "regular_file"
    case S_IFDIR: "directory"
    case S_IFLNK: "symlink"
    default: "unsupported"
    }
  }

  private func systemError(_ prefix: String) -> String {
    "\(prefix): \(String(cString: strerror(errno))) (errno \(errno))"
  }
}

struct DesktopPlanCommandRunner: Sendable {
  static let live = DesktopPlanCommandRunner()

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    homeDirectory: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    var diagnostics: [DesktopPlanDiagnostic] = []
    let profile: PortableProfile?
    do {
      profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
    } catch {
      profile = nil
      diagnostics.append(
        DesktopPlanDiagnostic(
          code: "profile_invalid",
          source: profileURL.path,
          message: String(describing: error)
        )
      )
    }

    let enabled = profile?.desktop.provider == .yabaiSkhd
    var composition: YabaiComposition?
    if let profile, enabled {
      do {
        composition = try YabaiConfigurationComposer().compose(
          defaultsURL: resourcesRoot.appending(path: "yabai/defaults.toml"),
          profile: profile
        )
      } catch {
        let source =
          (error as? YabaiConfigurationError)?.sourceURL
          ?? resourcesRoot.appending(path: "yabai/defaults.toml")
        diagnostics.append(
          DesktopPlanDiagnostic(
            code: "yabai_configuration_invalid",
            source: source.path,
            message: String(describing: error)
          )
        )
      }
    }

    let provider = YabaiProviderPlanInspector().inspect(
      homeDirectory: homeDirectory,
      enabled: enabled
    )
    if enabled, provider.status == .blocked {
      diagnostics.append(
        DesktopPlanDiagnostic(
          code: "yabai_provider_blocked",
          source: provider.entryPoint,
          message: provider.message
        )
      )
    }
    let blocked = !diagnostics.isEmpty
    let actions = plannedActions(
      enabled: enabled,
      provider: provider,
      composition: composition,
      blocked: blocked
    )
    let outcome =
      blocked
      ? "blocked"
      : enabled
        ? "ready"
        : "no_change"
    let report = DesktopPlanReport(
      outcome: outcome,
      profile: profileURL.path,
      profileStatus: profile == nil
        ? "invalid" : profile?.sourceURL == nil ? "absent_default" : "loaded",
      desktopProvider: profile?.desktop.provider.rawValue,
      topBarProvider: profile?.topBar.rawValue,
      packagedDefaults: resourcesRoot.appending(path: "yabai/defaults.toml").path,
      hook: composition?.hookURL?.path,
      hookDigest: composition?.hookDigest,
      settings: composition?.settings,
      renderedYabairc: composition?.renderedConfiguration,
      renderedDigest: composition?.renderedDigest,
      proposedInputDigest: composition?.inputDigest,
      provider: provider,
      actions: actions,
      diagnostics: diagnostics
    )
    return (try report.render(json: json), !blocked)
  }

  private func plannedActions(
    enabled: Bool,
    provider: YabaiProviderPlanInspection,
    composition: YabaiComposition?,
    blocked: Bool
  ) -> [DesktopPlanAction] {
    guard enabled, composition != nil, !blocked else { return [] }
    var actions = [
      DesktopPlanAction(
        id: "publish_yabai_generation",
        message: "Publish deterministic managed yabai configuration."
      )
    ]
    switch provider.status {
    case .installRequired:
      actions.append(
        DesktopPlanAction(
          id: "install_yabai_entry",
          message: "Install the managed yabairc provider entry."
        )
      )
    case .adoptionRequired:
      actions.append(
        DesktopPlanAction(
          id: provider.ownership == "directory_symlink"
            ? "adopt_yabai_directory_symlink"
            : "adopt_yabairc_entry",
          message: "Adopt the existing \(provider.ownership) after explicit approval."
        )
      )
    case .disabled, .externallyManaged, .blocked:
      break
    }
    return actions
  }
}

private struct DesktopPlanReport: Encodable {
  let schemaVersion = 1
  let operation = "desktop_plan"
  let outcome: String
  let mutated = false
  let profile: String
  let profileStatus: String
  let desktopProvider: String?
  let topBarProvider: String?
  let packagedDefaults: String
  let hook: String?
  let hookDigest: String?
  let settings: YabaiSettings?
  let renderedYabairc: String?
  let renderedDigest: String?
  let proposedInputDigest: String?
  let provider: YabaiProviderPlanInspection
  let actions: [DesktopPlanAction]
  let diagnostics: [DesktopPlanDiagnostic]

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy desktop plan [\(outcome)]:",
      "- profile [\(profileStatus)]: \(profile)",
      "- desktop provider: \(desktopProvider ?? "unavailable")",
      "- top-bar provider: \(topBarProvider ?? "unavailable")",
      "- packaged yabai defaults: \(packagedDefaults)",
      "- trusted yabai hook: \(hook ?? "none")",
      "- hook digest: \(hookDigest ?? "none")",
      "- effective layout: \(settings?.layout ?? "unavailable")",
      "- effective window gap: \(settings.map { String($0.windowGap) } ?? "unavailable")",
      "- proposed input digest: \(proposedInputDigest ?? "unavailable")",
      "- rendered digest: \(renderedDigest ?? "unavailable")",
      "- yabai provider [\(provider.status.rawValue), \(provider.ownership)]: "
        + provider.message,
      "- provider entry point: \(provider.entryPoint)",
      "- provider original target: \(provider.originalTarget ?? "none")",
      "- provider source: \(provider.source ?? "none")",
    ]
    lines.append(actions.isEmpty ? "Actions: none" : "Actions:")
    lines += actions.map { "- \($0.id): \($0.message)" }
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines += diagnostics.map { "- \($0.source): error [\($0.code)]: \($0.message)" }
    }
    if let renderedYabairc {
      lines.append(
        "Rendered yabairc:\n--- begin exact bytes ---\n\(renderedYabairc)"
          + "--- end exact bytes ---"
      )
    }
    lines.append("No changes made.")
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation
    case outcome
    case mutated
    case profile
    case profileStatus = "profile_status"
    case desktopProvider = "desktop_provider"
    case topBarProvider = "top_bar_provider"
    case packagedDefaults = "packaged_defaults"
    case hook
    case hookDigest = "hook_digest"
    case settings
    case renderedYabairc = "rendered_yabairc"
    case renderedDigest = "rendered_digest"
    case proposedInputDigest = "proposed_input_digest"
    case provider
    case actions
    case diagnostics
  }
}

private struct DesktopPlanAction: Encodable {
  let id: String
  let message: String
}

private struct DesktopPlanDiagnostic: Encodable {
  let severity = "error"
  let code: String
  let source: String
  let message: String
}
