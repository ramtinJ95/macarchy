import Foundation
import ThemeCore

struct EnvironmentPlanCommandRunner: Sendable {
  static let live = EnvironmentPlanCommandRunner()

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let profile: PortableProfile
    do {
      profile = try PortableProfileLoader().load(at: profileURL, required: profileRequired)
    } catch {
      let report = EnvironmentPlanReport.blocked(
        profile: profileURL,
        resourcesRoot: resourcesRoot,
        diagnostic: EnvironmentPlanDiagnostic(
          code: "profile_invalid",
          source: profileURL.path,
          message: String(describing: error)
        )
      )
      return (try report.render(json: json), false)
    }

    let composition: EnvironmentComposition
    do {
      composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot,
        profile: profile,
        stateRoot: stateRoot
      )
    } catch {
      let source = (error as? EnvironmentConfigurationError)?.sourceURL ?? resourcesRoot
      let report = EnvironmentPlanReport.blocked(
        profile: profileURL,
        profileStatus: profile.sourceURL == nil ? "absent_default" : "loaded",
        environment: profile.environment,
        resourcesRoot: resourcesRoot,
        diagnostic: EnvironmentPlanDiagnostic(
          code: "environment_configuration_invalid",
          source: source.path,
          message: String(describing: error)
        )
      )
      return (try report.render(json: json), false)
    }

    let report = EnvironmentPlanReport(
      outcome: "ready",
      profile: profileURL.path,
      profileStatus: profile.sourceURL == nil ? "absent_default" : "loaded",
      terminalProvider: composition.profile.terminal.rawValue,
      shellProvider: composition.profile.shell.rawValue,
      promptProvider: composition.profile.prompt.rawValue,
      historyProvider: composition.profile.history.rawValue,
      packagedDefaults: resourcesRoot.path,
      kittyOverride: composition.kittyOverrideURL?.path,
      zshHook: composition.zshHookURL?.path,
      zshHookDigest: composition.zshHookDigest,
      starshipBehavior: composition.starshipBehaviorURL?.path,
      atuinConfiguration: composition.atuinConfigurationURL?.path,
      renderedArtifacts: Dictionary(
        uniqueKeysWithValues: composition.artifacts.map { ($0.path, $0.contents) }
      ),
      renderedDigest: composition.renderedDigest,
      proposedInputDigest: composition.inputDigest,
      actions: Self.actions(for: composition.profile),
      diagnostics: []
    )
    return (try report.render(json: json), true)
  }

  private static func actions(for profile: EnvironmentProfile) -> [EnvironmentPlanAction] {
    var actions: [EnvironmentPlanAction] = []
    if profile.terminal == .kitty {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_kitty",
          message: "Configure Kitty through the managed environment generation."
        )
      )
    }
    if profile.shell == .zsh {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_zsh",
          message: "Configure zsh through the managed environment generation."
        )
      )
    }
    if profile.prompt == .starship {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_starship",
          message: "Configure Starship behavior while retaining Macarchy palette ownership."
        )
      )
    }
    if profile.history == .atuin {
      actions.append(
        EnvironmentPlanAction(
          id: "configure_atuin",
          message: "Configure Atuin behavior while retaining Macarchy theme ownership."
        )
      )
    }
    if !actions.isEmpty {
      actions.insert(
        EnvironmentPlanAction(
          id: "publish_environment_generation",
          message: "Publish the deterministic terminal-session generation."
        ),
        at: 0
      )
    }
    return actions
  }
}

private struct EnvironmentPlanReport: Encodable {
  let schemaVersion = 1
  let operation = "environment_plan"
  let outcome: String
  let mutated = false
  let profile: String
  let profileStatus: String
  let terminalProvider: String?
  let shellProvider: String?
  let promptProvider: String?
  let historyProvider: String?
  let packagedDefaults: String
  let kittyOverride: String?
  let zshHook: String?
  let zshHookDigest: String?
  let starshipBehavior: String?
  let atuinConfiguration: String?
  let renderedArtifacts: [String: String]
  let renderedDigest: String?
  let proposedInputDigest: String?
  let actions: [EnvironmentPlanAction]
  let diagnostics: [EnvironmentPlanDiagnostic]

  static func blocked(
    profile: URL,
    profileStatus: String = "invalid",
    environment: EnvironmentProfile? = nil,
    resourcesRoot: URL,
    diagnostic: EnvironmentPlanDiagnostic
  ) -> EnvironmentPlanReport {
    EnvironmentPlanReport(
      outcome: "blocked",
      profile: profile.path,
      profileStatus: profileStatus,
      terminalProvider: environment?.terminal.rawValue,
      shellProvider: environment?.shell.rawValue,
      promptProvider: environment?.prompt.rawValue,
      historyProvider: environment?.history.rawValue,
      packagedDefaults: resourcesRoot.path,
      kittyOverride: environment?.kitty.overrideDirectoryURL?.path,
      zshHook: environment?.zsh.hookURL?.path,
      zshHookDigest: nil,
      starshipBehavior: environment?.starship.behaviorURL?.path,
      atuinConfiguration: environment?.atuin.configurationURL?.path,
      renderedArtifacts: [:],
      renderedDigest: nil,
      proposedInputDigest: nil,
      actions: [],
      diagnostics: [diagnostic]
    )
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = [
      "Macarchy environment plan [\(outcome)]:",
      "- profile [\(profileStatus)]: \(profile)",
      "- terminal provider: " + (terminalProvider ?? "unavailable"),
      "- shell provider: " + (shellProvider ?? "unavailable"),
      "- prompt provider: " + (promptProvider ?? "unavailable"),
      "- history provider: " + (historyProvider ?? "unavailable"),
      "- packaged defaults: \(packagedDefaults)",
      "- Kitty override: " + (kittyOverride ?? "none"),
      "- trusted zsh hook: " + (zshHook ?? "none"),
      "- zsh hook digest: " + (zshHookDigest ?? "none"),
      "- Starship behavior: " + (starshipBehavior ?? "none"),
      "- Atuin configuration: " + (atuinConfiguration ?? "none"),
      "- proposed input digest: " + (proposedInputDigest ?? "unavailable"),
      "- rendered digest: " + (renderedDigest ?? "unavailable"),
      actions.isEmpty ? "Actions: none" : "Actions:",
    ]
    lines += actions.map { "- \($0.id): \($0.message)" }
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines += diagnostics.map { "- \($0.source): error [\($0.code)]: \($0.message)" }
    }
    for (path, contents) in renderedArtifacts.sorted(by: { $0.key < $1.key }) {
      lines.append(
        "Rendered \(path):\n" + "--- begin exact bytes ---\n" + contents
          + "--- end exact bytes ---"
      )
    }
    lines.append("No changes made.")
    return lines.joined(separator: "\n")
  }
}

private struct EnvironmentPlanAction: Encodable {
  let id: String
  let message: String
}

private struct EnvironmentPlanDiagnostic: Encodable {
  let severity = "error"
  let code: String
  let source: String
  let message: String
}
