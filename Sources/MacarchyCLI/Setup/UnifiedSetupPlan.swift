import Foundation
import ThemeCore

struct UnifiedSetupPlanContext: Sendable {
  let themesRoot: URL
  let keybindingsResourcesRoot: URL
  let desktopResourcesRoot: URL
  let environmentResourcesRoot: URL
  let profileURL: URL
  let profileRequired: Bool
  let machineProfileURL: URL
  let machineProfileRequired: Bool
  let stateRoot: URL
  let homeDirectory: URL
}

struct UnifiedSetupDesiredModel: Sendable {
  let profile: PortableProfile
  let layers: [SetupProfileLayerReport]
  let fieldOrigins: [String: String]
  let themePackage: ThemePackage
  let theme: UnifiedSetupThemePlan
  let enabledThemeAdapterIDs: [String]
  let capabilities: [SetupCapability]
  let packages: HomebrewInstallPlan
}

enum UnifiedSetupPreparation {
  case ready(UnifiedSetupDesiredModel, UnifiedSetupPlanReport)
  case blocked(UnifiedSetupPlanReport)

  var report: UnifiedSetupPlanReport {
    switch self {
    case .ready(_, let report), .blocked(let report): report
    }
  }

  var succeeded: Bool {
    if case .ready = self { return true }
    return false
  }
}

struct UnifiedSetupPlanCommandRunner: Sendable {
  typealias ComponentPlanner =
    @Sendable (
      UnifiedSetupPlanContext, PortableProfile
    ) throws -> SetupComponentExecution

  let capabilityIsAvailable: @Sendable (DependencyCapability) -> Bool
  let desktopPlanner: ComponentPlanner
  let environmentPlanner: ComponentPlanner

  static let live = UnifiedSetupPlanCommandRunner(
    capabilityIsAvailable: { $0.isAvailable() },
    desktopPlanner: { context, profile in
      let execution = try DesktopPlanCommandRunner(
        keybindings: .live,
        prerequisites: .assumed
      ).execute(
        resourcesRoot: context.desktopResourcesRoot,
        keybindingsResourcesRoot: context.keybindingsResourcesRoot,
        profileURL: context.profileURL,
        profileRequired: context.profileRequired,
        stateRoot: context.stateRoot,
        homeDirectory: context.homeDirectory,
        json: true,
        profile: profile,
        requireRunningKeybindingProcess: false
      )
      return try SetupComponentExecution(execution)
    },
    environmentPlanner: { context, profile in
      let execution = try EnvironmentPlanCommandRunner(
        prerequisites: .assumed,
        requiresActiveTheme: false
      ).execute(
        resourcesRoot: context.environmentResourcesRoot,
        profileURL: context.profileURL,
        profileRequired: context.profileRequired,
        stateRoot: context.stateRoot,
        homeDirectory: context.homeDirectory,
        json: true,
        profile: profile
      )
      return try SetupComponentExecution(execution)
    }
  )

  func execute(
    context: UnifiedSetupPlanContext,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let preparation = try prepare(context: context)
    return (try preparation.report.render(json: json), preparation.succeeded)
  }

  func prepare(context: UnifiedSetupPlanContext) throws -> UnifiedSetupPreparation {
    do {
      if let transaction = try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read() {
        return .blocked(
          UnifiedSetupPlanReport.recoveryRequired(
            error:
              "Interrupted unified \(transaction.operation.rawValue) is in \(transaction.phase.rawValue) recovery."
          )
        )
      }
    } catch {
      return .blocked(
        UnifiedSetupPlanReport.recoveryRequired(error: String(describing: error))
      )
    }

    let layered: LayeredPortableProfile
    do {
      layered = try PortableProfileLoader().load(
        portableAt: context.profileURL,
        portableRequired: context.profileRequired,
        machineAt: context.machineProfileURL,
        machineRequired: context.machineProfileRequired
      )
    } catch {
      return .blocked(
        UnifiedSetupPlanReport.blocked(
          layers: profileFailureLayers(context: context, error: error),
          fieldOrigins: [:],
          error: String(describing: error)
        )
      )
    }

    let themeSelection: (package: ThemePackage, plan: UnifiedSetupThemePlan)
    do {
      themeSelection = try themePlan(context: context)
    } catch {
      return .blocked(
        UnifiedSetupPlanReport.blocked(
          layers: layered.layers.map(SetupProfileLayerReport.init),
          fieldOrigins: Dictionary(
            uniqueKeysWithValues: layered.fieldOrigins.map { ($0.key, $0.value.rawValue) }
          ),
          error: String(describing: error)
        )
      )
    }

    let profile = layered.profile
    let capabilities = DependencyProfile.personal(homeDirectory: context.homeDirectory)
      .selectedForSetup(profile)
      .map { capability in
        SetupCapability(
          id: capability.id,
          category: capability.category,
          status: capabilityIsAvailable(capability) ? .present : .missing,
          requirement: capability.requirement,
          remediation: capability.remediation
        )
      }
    let model = UnifiedSetupDesiredModel(
      profile: profile,
      layers: layered.layers.map(SetupProfileLayerReport.init),
      fieldOrigins: Dictionary(
        uniqueKeysWithValues: layered.fieldOrigins.map { ($0.key, $0.value.rawValue) }
      ),
      themePackage: themeSelection.package,
      theme: themeSelection.plan,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs(profile),
      capabilities: capabilities,
      packages: HomebrewInstallPlan(capabilities: capabilities)
    )
    let desktop = try desktopPlanner(context, profile)
    let environment = try environmentPlanner(context, profile)
    let components = SetupComponentPlans(
      desktop: desktop,
      environment: environment
    )
    var diagnostics = [UnifiedSetupPlanDiagnostic]()
    for (id, component) in components.all where !component.succeeded {
      diagnostics.append(
        UnifiedSetupPlanDiagnostic(
          code: "\(id)_plan_blocked",
          source: id,
          message: componentFailureMessage(id: id, component: component)
        )
      )
    }
    let actions = try plannedActions(
      installPlan: model.packages,
      theme: model.theme,
      components: components
    )
    let report = UnifiedSetupPlanReport(
      outcome: diagnostics.isEmpty ? (actions.isEmpty ? "no_change" : "ready") : "blocked",
      layers: model.layers,
      fieldOrigins: model.fieldOrigins,
      providers: providers(profile),
      theme: model.theme,
      capabilities: model.capabilities,
      packages: model.packages,
      files: try plannedFiles(
        profile: profile,
        components: components,
        homeDirectory: context.homeDirectory
      ),
      services: services(profile),
      permissions: permissions(profile),
      adoption: try adoptionEvidence(components),
      manualBoundaries: manualBoundaries(profile: profile, installPlan: model.packages),
      actions: diagnostics.isEmpty ? actions : [],
      components: components,
      diagnostics: diagnostics
    )
    guard diagnostics.isEmpty else { return .blocked(report) }
    return .ready(model, report)
  }

  private func componentFailureMessage(
    id: String,
    component: SetupComponentExecution
  ) -> String {
    let messages = (component.report["diagnostics"]?.array ?? []).compactMap {
      $0["message"]?.string
    }
    guard !messages.isEmpty else { return "The delegated \(id) plan is blocked." }
    return "The delegated \(id) plan is blocked: \(messages.joined(separator: "; "))"
  }

  private func profileFailureLayers(
    context: UnifiedSetupPlanContext,
    error: Error
  ) -> [SetupProfileLayerReport] {
    let source: URL?
    switch error as? KeybindingProfileError {
    case .cannotRead(let url, _), .invalid(let url, _): source = url.standardizedFileURL
    case nil: source = nil
    }
    let portableFailed = source?.path == context.profileURL.standardizedFileURL.path
    let machineFailed = source?.path == context.machineProfileURL.standardizedFileURL.path
    let portableStatus: String
    let machineStatus: String
    if portableFailed {
      portableStatus = "invalid"
      machineStatus = "not_inspected"
    } else if machineFailed {
      portableStatus =
        FileManager.default.fileExists(atPath: context.profileURL.path)
        ? "loaded" : "absent"
      machineStatus = "invalid"
    } else {
      portableStatus = "unresolved"
      machineStatus = "unresolved"
    }
    return [
      SetupProfileLayerReport(
        kind: "portable",
        path: context.profileURL.path,
        status: portableStatus,
        declaredFields: []
      ),
      SetupProfileLayerReport(
        kind: "machine",
        path: context.machineProfileURL.path,
        status: machineStatus,
        declaredFields: []
      ),
    ]
  }

  private func themePlan(
    context: UnifiedSetupPlanContext
  ) throws -> (package: ThemePackage, plan: UnifiedSetupThemePlan) {
    let themeID: String
    let source: String
    let currentGenerationID: String?
    do {
      let manifest = try ReconciliationStatusStore(root: context.stateRoot).activeManifest()
      themeID = manifest.themeID
      source = "active"
      currentGenerationID = manifest.generationID
    } catch ReconciliationStatusError.noActiveGeneration {
      themeID = "catppuccin-mocha"
      source = "curated_default"
      currentGenerationID = nil
    }
    let repository = ThemeRepository(
      builtInRoot: context.themesRoot,
      userRoot: context.stateRoot.appending(path: "themes", directoryHint: .isDirectory)
    )
    let package = try MacarchyConfigurationStore(root: context.stateRoot)
      .addingPersonalBackgrounds(to: repository.package(id: themeID))
    // Setup must not advertise a theme that cannot produce a complete generation.
    _ = try ThemeRenderer().render(
      package: package,
      generationID: "setup-plan"
    )
    return (
      package,
      UnifiedSetupThemePlan(
        id: package.id,
        displayName: package.displayName,
        source: source,
        status: source == "active" ? "preserve" : "activation_required",
        packagePath: package.packageURL.path,
        appearance: package.appearance.rawValue,
        backgroundCount: package.backgrounds.count,
        currentGenerationID: currentGenerationID
      )
    )
  }

  private func providers(_ profile: PortableProfile) -> [String: String] {
    let environment = profile.environment
    return [
      "desktop": profile.desktop.provider.rawValue,
      "editor": environment.editor.rawValue,
      "history": environment.history.rawValue,
      "prompt": environment.prompt.rawValue,
      "shell": environment.shell.rawValue,
      "terminal": environment.terminal.rawValue,
      "top_bar": profile.topBar.rawValue,
    ]
  }

  private func enabledThemeAdapterIDs(_ profile: PortableProfile) -> [String] {
    var result = Set(profile.environment.selectedThemeAdapterIDs)
    result.insert(MacOSAppearanceAdapter.id)
    if profile.desktop.provider == .yabaiSkhd { result.insert("wallpaper") }
    if profile.topBar == .sketchybar { result.insert("sketchybar") }
    return result.sorted()
  }

  private func services(_ profile: PortableProfile) -> [UnifiedSetupService] {
    var result = [UnifiedSetupService]()
    if profile.desktop.provider == .yabaiSkhd {
      result.append(
        UnifiedSetupService(id: "yabai", ownership: "managed", lifecycle: "restart_and_verify")
      )
      result.append(
        UnifiedSetupService(id: "skhd", ownership: "managed", lifecycle: "restart_or_reload")
      )
    }
    if profile.topBar == .sketchybar {
      result.append(
        UnifiedSetupService(
          id: "sketchybar",
          ownership: "homebrew_service",
          lifecycle: "start_or_reload_and_verify"
        )
      )
    }
    if profile.environment.presets.herdr {
      result.append(
        UnifiedSetupService(id: "herdr", ownership: "external", lifecycle: "reload_if_running")
      )
    }
    return result
  }

  private func permissions(_ profile: PortableProfile) -> [UnifiedSetupPermission] {
    var result = [
      UnifiedSetupPermission(
        id: "system_events_automation",
        status: "manual_boundary",
        message: "macOS may request Automation access when applying system appearance."
      )
    ]
    if profile.desktop.provider == .yabaiSkhd {
      result.append(
        UnifiedSetupPermission(
          id: "yabai_accessibility",
          status: "manual_required",
          message:
            "yabai requires user-granted Accessibility access before apply can verify Spaces."
        )
      )
    }
    return result
  }

  private func manualBoundaries(
    profile: PortableProfile,
    installPlan: HomebrewInstallPlan
  ) -> [UnifiedSetupManualBoundary] {
    var result = installPlan.external.map {
      UnifiedSetupManualBoundary(
        id: $0.capabilityID,
        kind: "external_prerequisite",
        instruction: $0.instruction
      )
    }
    if profile.desktop.provider == .yabaiSkhd {
      result.append(
        UnifiedSetupManualBoundary(
          id: "yabai_accessibility",
          kind: "permission",
          instruction: "Grant yabai Accessibility access in System Settings before apply."
        )
      )
    }
    if profile.environment.presets.slack {
      result.append(
        UnifiedSetupManualBoundary(
          id: "slack_theme_import",
          kind: "application_ui",
          instruction: "Import the generated four-color theme in each Slack workspace."
        )
      )
    }
    return result
  }

  private func plannedFiles(
    profile: PortableProfile,
    components: SetupComponentPlans,
    homeDirectory: URL
  ) throws -> [UnifiedSetupFile] {
    var result = [UnifiedSetupFile]()
    if profile.desktop.provider == .yabaiSkhd {
      let keybindings = try components.desktop.report.required("keybindings", at: "desktop")
      result.append(
        UnifiedSetupFile(
          id: "skhd_entry",
          path: homeDirectory.appending(path: ".config/skhd/skhdrc").path,
          status: try keybindings.requiredString("provider_status", at: "desktop.keybindings"),
          ownership: try keybindings.requiredString("ownership", at: "desktop.keybindings")
        )
      )
    }
    let yabaiProvider = try components.desktop.report.requiredObject(
      "provider",
      at: "desktop"
    )
    result.append(
      UnifiedSetupFile(
        id: "yabai_entry",
        path: try yabaiProvider.requiredString("entry_point", at: "desktop.provider"),
        status: try yabaiProvider.requiredString("status", at: "desktop.provider"),
        ownership: try yabaiProvider.requiredString("ownership", at: "desktop.provider")
      )
    )
    if let sketchyBar = components.desktop.report["sketchybar"] {
      let provider = try sketchyBar.requiredObject("provider", at: "desktop.sketchybar")
      result.append(
        UnifiedSetupFile(
          id: "sketchybar_entry",
          path: try provider.requiredString("entry_point", at: "desktop.sketchybar.provider"),
          status: try provider.requiredString("status", at: "desktop.sketchybar.provider"),
          ownership: try provider.requiredString("ownership", at: "desktop.sketchybar.provider")
        )
      )
    }
    let entries = try components.environment.report.requiredArray("entries", at: "environment")
    for (index, entry) in entries.enumerated() {
      let path = "environment.entries[\(index)]"
      let object = try entry.requiredObject(at: path)
      result.append(
        UnifiedSetupFile(
          id: try object.requiredString("id", at: path),
          path: try object.requiredString("path", at: path),
          status: try object.requiredString("status", at: path),
          ownership: try object.requiredString("ownership", at: path)
        )
      )
    }
    return result.sorted { lhs, rhs in
      lhs.path == rhs.path ? lhs.id < rhs.id : lhs.path < rhs.path
    }
  }

  private func adoptionEvidence(
    _ components: SetupComponentPlans
  ) throws -> [UnifiedSetupAdoptionEvidence] {
    var result = [UnifiedSetupAdoptionEvidence]()
    func append(_ id: String, status: String, digest: String?) {
      guard status == "adoption_required", let digest else { return }
      result.append(UnifiedSetupAdoptionEvidence(id: id, digest: digest))
    }
    let keybindings = try components.desktop.report.required("keybindings", at: "desktop")
    append(
      "keybindings",
      status: try keybindings.requiredString("provider_status", at: "desktop.keybindings"),
      digest: try keybindings.optionalString(
        "adoption_evidence_digest",
        at: "desktop.keybindings"
      )
    )
    let yabaiProvider = try components.desktop.report.requiredObject("provider", at: "desktop")
    append(
      "yabai",
      status: try yabaiProvider.requiredString("status", at: "desktop.provider"),
      digest: try yabaiProvider.optionalString("adoption_evidence_digest", at: "desktop.provider")
    )
    if let sketchyBar = components.desktop.report["sketchybar"] {
      let provider = try sketchyBar.requiredObject("provider", at: "desktop.sketchybar")
      append(
        "sketchybar",
        status: try provider.requiredString("status", at: "desktop.sketchybar.provider"),
        digest: try provider.optionalString(
          "adoption_evidence_digest",
          at: "desktop.sketchybar.provider"
        )
      )
    }
    if let digest = try components.environment.report.optionalString(
      "adoption_evidence_digest",
      at: "environment"
    ) {
      result.append(UnifiedSetupAdoptionEvidence(id: "environment", digest: digest))
    }
    return result
  }

  private func plannedActions(
    installPlan: HomebrewInstallPlan,
    theme: UnifiedSetupThemePlan,
    components: SetupComponentPlans
  ) throws -> [UnifiedSetupAction] {
    var result = [UnifiedSetupAction]()
    if !installPlan.formulae.isEmpty || !installPlan.casks.isEmpty {
      result.append(
        UnifiedSetupAction(
          stage: "packages",
          id: "install_homebrew_dependencies",
          message: "Install only the selected missing Homebrew formulae and casks."
        )
      )
    }
    for remediation in installPlan.external {
      result.append(
        UnifiedSetupAction(
          stage: "prerequisites",
          id: "resolve_\(remediation.capabilityID)",
          message: remediation.instruction
        )
      )
    }
    if theme.status == "activation_required" {
      result.append(
        UnifiedSetupAction(
          stage: "theme",
          id: "activate_curated_theme",
          message: "Activate the curated default theme '\(theme.id)'."
        )
      )
    }
    for (componentID, component) in components.all {
      let actions = try component.report.requiredArray("actions", at: componentID)
      for (index, action) in actions.enumerated() {
        let path = "\(componentID).actions[\(index)]"
        let object = try action.requiredObject(at: path)
        result.append(
          UnifiedSetupAction(
            stage: componentID,
            id: try object.requiredString("id", at: path),
            message: try object.requiredString("message", at: path)
          )
        )
      }
    }
    return result
  }
}

struct SetupComponentExecution: Encodable, Sendable {
  let succeeded: Bool
  let report: JSONValue
  let outcome: String

  init(_ execution: (output: String, succeeded: Bool)) throws {
    succeeded = execution.succeeded
    report = try JSONDecoder().decode(JSONValue.self, from: Data(execution.output.utf8))
    _ = try report.requiredObject(at: "component")
    outcome = try report.requiredString("outcome", at: "component")
  }

  enum CodingKeys: CodingKey {
    case succeeded, report
  }
}

struct SetupComponentPlans: Encodable, Sendable {
  let desktop: SetupComponentExecution
  let environment: SetupComponentExecution

  var all: [(String, SetupComponentExecution)] {
    [("desktop", desktop), ("environment", environment)]
  }
}

struct SetupProfileLayerReport: Encodable, Sendable {
  let kind: String
  let path: String
  let status: String
  let declaredFields: [String]
}

extension SetupProfileLayerReport {
  init(_ layer: PortableProfileLayer) {
    kind = layer.kind.rawValue
    path = layer.sourceURL.path
    status = layer.present ? "loaded" : "absent"
    declaredFields = layer.declaredFields
  }
}

struct UnifiedSetupThemePlan: Encodable, Sendable {
  let id: String
  let displayName: String
  let source: String
  let status: String
  let packagePath: String
  let appearance: String
  let backgroundCount: Int
  let currentGenerationID: String?
}

struct UnifiedSetupFile: Encodable, Sendable {
  let id: String
  let path: String
  let status: String
  let ownership: String
}

struct UnifiedSetupService: Encodable, Sendable {
  let id: String
  let ownership: String
  let lifecycle: String
}

struct UnifiedSetupPermission: Encodable, Sendable {
  let id: String
  let status: String
  let message: String
}

struct UnifiedSetupManualBoundary: Encodable, Sendable {
  let id: String
  let kind: String
  let instruction: String
}

struct UnifiedSetupAdoptionEvidence: Encodable, Sendable {
  let id: String
  let digest: String
}

struct UnifiedSetupAction: Encodable, Sendable {
  let stage: String
  let id: String
  let message: String
}

struct UnifiedSetupPlanDiagnostic: Encodable, Sendable {
  let severity = "error"
  let code: String
  let source: String
  let message: String
}

struct UnifiedSetupPlanReport: Encodable {
  let schemaVersion = 1
  let operation = "setup_plan"
  let outcome: String
  let mutated = false
  let layers: [SetupProfileLayerReport]
  let fieldOrigins: [String: String]
  let providers: [String: String]
  let theme: UnifiedSetupThemePlan?
  let capabilities: [SetupCapability]
  let packages: HomebrewInstallPlan
  let files: [UnifiedSetupFile]
  let services: [UnifiedSetupService]
  let permissions: [UnifiedSetupPermission]
  let adoption: [UnifiedSetupAdoptionEvidence]
  let manualBoundaries: [UnifiedSetupManualBoundary]
  let actions: [UnifiedSetupAction]
  let components: SetupComponentPlans?
  let diagnostics: [UnifiedSetupPlanDiagnostic]

  static func blocked(
    layers: [SetupProfileLayerReport],
    fieldOrigins: [String: String],
    error: String
  ) -> Self {
    unavailable(
      outcome: "blocked",
      layers: layers,
      fieldOrigins: fieldOrigins,
      code: "setup_input_invalid",
      error: error
    )
  }

  static func recoveryRequired(error: String) -> Self {
    unavailable(
      outcome: "recovery_required",
      layers: [],
      fieldOrigins: [:],
      code: "setup_recovery_required",
      error: error
    )
  }

  private static func unavailable(
    outcome: String,
    layers: [SetupProfileLayerReport],
    fieldOrigins: [String: String],
    code: String,
    error: String
  ) -> Self {
    Self(
      outcome: outcome,
      layers: layers,
      fieldOrigins: fieldOrigins,
      providers: [:],
      theme: nil,
      capabilities: [],
      packages: HomebrewInstallPlan(capabilities: []),
      files: [],
      services: [],
      permissions: [],
      adoption: [],
      manualBoundaries: [],
      actions: [],
      components: nil,
      diagnostics: [
        UnifiedSetupPlanDiagnostic(
          code: code,
          source: "setup",
          message: error
        )
      ]
    )
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    var lines = ["Macarchy setup plan [\(outcome)]:", "Profiles:"]
    lines += layers.map {
      "- \($0.kind) [\($0.status)]: \($0.path)"
        + ($0.declaredFields.isEmpty ? "" : " (\($0.declaredFields.joined(separator: ", ")))")
    }
    if !providers.isEmpty {
      lines.append("Selected providers:")
      lines += providers.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }
    }
    if let theme {
      lines.append(
        "Theme [\(theme.status), \(theme.source)]: \(theme.id) (\(theme.appearance), "
          + "\(theme.backgroundCount) backgrounds)"
      )
    }
    if !fieldOrigins.isEmpty {
      lines.append("Effective field origins:")
      lines += fieldOrigins.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }
    }
    lines.append(capabilities.isEmpty ? "Core capabilities: none" : "Core capabilities:")
    lines += capabilities.map {
      "- \($0.id) [\($0.status.rawValue)]: \($0.requirement)"
    }
    lines.append(packages.humanOutput)
    lines.append(files.isEmpty ? "Files: none" : "Files:")
    lines += files.map { "- \($0.id) [\($0.status), \($0.ownership)]: \($0.path)" }
    lines.append(services.isEmpty ? "Services: none" : "Services:")
    lines += services.map { "- \($0.id) [\($0.ownership)]: \($0.lifecycle)" }
    lines.append(permissions.isEmpty ? "Permissions: none" : "Permissions:")
    lines += permissions.map { "- \($0.id) [\($0.status)]: \($0.message)" }
    lines.append(adoption.isEmpty ? "Adoption evidence: none" : "Adoption evidence:")
    lines += adoption.map { "- \($0.id): \($0.digest)" }
    lines.append(manualBoundaries.isEmpty ? "Manual boundaries: none" : "Manual boundaries:")
    lines += manualBoundaries.map { "- \($0.id) [\($0.kind)]: \($0.instruction)" }
    lines.append(actions.isEmpty ? "Actions: none" : "Actions:")
    lines += actions.map { "- \($0.stage)/\($0.id): \($0.message)" }
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines += diagnostics.map { "- \($0.source): error [\($0.code)]: \($0.message)" }
    }
    lines.append("No changes made.")
    return lines.joined(separator: "\n")
  }
}

enum JSONValue: Codable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case integer(Int64)
  case unsignedInteger(UInt64)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(UInt64.self) {
      self = .unsignedInteger(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      self = .array(try container.decode([JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .unsignedInteger(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  var object: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var array: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  subscript(_ key: String) -> JSONValue? {
    object?[key]
  }
}

struct SetupComponentReportError: Error, CustomStringConvertible {
  let description: String
}

extension JSONValue {
  fileprivate func required(_ key: String, at path: String) throws -> JSONValue {
    guard let object, let value = object[key] else {
      throw SetupComponentReportError(description: "Delegated plan is missing \(path).\(key)")
    }
    return value
  }

  fileprivate func requiredObject(at path: String) throws -> [String: JSONValue] {
    guard let object else {
      throw SetupComponentReportError(description: "Delegated plan field \(path) is not an object")
    }
    return object
  }

  fileprivate func requiredObject(_ key: String, at path: String) throws -> [String: JSONValue] {
    try required(key, at: path).requiredObject(at: "\(path).\(key)")
  }

  fileprivate func requiredArray(_ key: String, at path: String) throws -> [JSONValue] {
    let value = try required(key, at: path)
    guard let array = value.array else {
      throw SetupComponentReportError(
        description: "Delegated plan field \(path).\(key) is not an array"
      )
    }
    return array
  }

  fileprivate func requiredString(_ key: String, at path: String) throws -> String {
    try required(key, at: path).requiredString(at: "\(path).\(key)")
  }

  fileprivate func requiredString(at path: String) throws -> String {
    guard let string else {
      throw SetupComponentReportError(description: "Delegated plan field \(path) is not a string")
    }
    return string
  }

  fileprivate func optionalString(_ key: String, at path: String) throws -> String? {
    guard let value = object?[key] else { return nil }
    if case .null = value { return nil }
    return try value.requiredString(at: "\(path).\(key)")
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func requiredString(_ key: String, at path: String) throws -> String {
    guard let value = self[key] else {
      throw SetupComponentReportError(description: "Delegated plan is missing \(path).\(key)")
    }
    return try value.requiredString(at: "\(path).\(key)")
  }

  fileprivate func optionalString(_ key: String, at path: String) throws -> String? {
    guard let value = self[key] else { return nil }
    if case .null = value { return nil }
    return try value.requiredString(at: "\(path).\(key)")
  }
}
