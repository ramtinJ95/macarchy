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
  var nativeStarterProviders: [EnvironmentNativeSeed.Provider] = []
  var nativeStarterApprovals: [String: String] = [:]
  /// Prepared by this planner for its environment component, never persisted authority.
  var nativeStarters: [EnvironmentNativeSeed] = []

  /// Loads the portable and machine layers this context names. A proposed source stands in
  /// for that file's current text.
  func loadProfile(proposedSources: [URL: String] = [:]) throws -> LayeredPortableProfile {
    try PortableProfileLoader(proposedSources: proposedSources).load(
      portableAt: profileURL, portableRequired: profileRequired,
      machineAt: machineProfileURL, machineRequired: machineProfileRequired)
  }
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
  var nativeStarters: [EnvironmentNativeSeed] = []
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
  let capabilityIsAvailable: @Sendable (DependencyCapability) -> Bool
  let desktopPlanner:
    @Sendable (
      UnifiedSetupPlanContext, PortableProfile
    ) throws -> SetupComponentPlan<DesktopPlanReport>
  let environmentPlanner:
    @Sendable (
      UnifiedSetupPlanContext, PortableProfile, ThemePackage?
    ) throws -> SetupComponentPlan<EnvironmentPlanReport>
  var packageInventoryReader: @Sendable () -> HomebrewPackageObservation = {
    .unavailable("Package inventory reader is not configured.")
  }
  var standardBrewfile: @Sendable (URL) throws -> SetupBrewfile = { try SetupBrewfile.read(at: $0) }
  var personalBrewfile: @Sendable (URL) throws -> SetupBrewfile = { try SetupBrewfile.read(at: $0) }
  var proposedProfileSources: [URL: String] = [:]
  var preferences: PreferencesLifecycle = .live

  static let live = UnifiedSetupPlanCommandRunner(
    capabilityIsAvailable: { $0.isAvailable() },
    desktopPlanner: { context, profile in
      try SetupComponentPlan(
        DesktopPlanCommandRunner(
          keybindings: .live,
          prerequisites: .assumed
        ).report(
          resourcesRoot: context.desktopResourcesRoot,
          keybindingsResourcesRoot: context.keybindingsResourcesRoot,
          profileURL: context.profileURL,
          profileRequired: context.profileRequired,
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          profile: profile,
          requireRunningKeybindingProcess: false
        ))
    },
    environmentPlanner: { context, profile, bootstrapTheme in
      try SetupComponentPlan(
        EnvironmentPlanCommandRunner(
          prerequisites: EnvironmentPrerequisiteInspector { profile, home in
            profile.presets.spicetify
              ? EnvironmentPrerequisiteInspector.spicetifyPreparation(homeDirectory: home) : []
          },
          requiresActiveTheme: false
        ).report(
          resourcesRoot: context.environmentResourcesRoot,
          profileURL: context.profileURL,
          profileRequired: context.profileRequired,
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          profile: profile,
          bootstrapTheme: bootstrapTheme,
          nativeStarters: context.nativeStarters
        ))
    },
    packageInventoryReader: { HomebrewPackageInventoryReader.live.read() }
  )

  func execute(
    context: UnifiedSetupPlanContext,
    json: Bool
  ) throws -> CommandExecution {
    let preparation = try prepare(context: context)
    let report = inspectedReport(preparation.report, context: context)
    return (try report.render(json: json), preparation.succeeded)
  }

  func inspectedReport(
    _ report: UnifiedSetupPlanReport, context: UnifiedSetupPlanContext
  ) -> UnifiedSetupPlanReport {
    guard report.packageInventory != nil else { return report }
    var report = report
    do {
      report.packageInventory?.installation = try SetupPackageInstallationStore(context: context)
        .read()?.summary
    } catch {
      report.packageInventory?.installationIssue = String(describing: error)
    }
    return report
  }

  /// The same profile and package selection, without theme/provider planning or
  /// mutation. Package adoption must not require unrelated full setup to pass.
  func packageInventory(
    context: UnifiedSetupPlanContext, adoptionState: SetupPackageAdoptionState
  ) throws -> SetupPackageInventory {
    let layered = try context.loadProfile(proposedSources: proposedProfileSources)
    let capabilities = try setupCapabilities(
      profile: layered.profile, homeDirectory: context.homeDirectory,
      desktopResourcesRoot: context.desktopResourcesRoot)
    let declarations = try packageDeclarations(
      context: context, profile: layered.profile, capabilities: capabilities)
    return SetupPackageInventory(
      capabilities: capabilities,
      fieldOrigins: layered.fieldOrigins.mapValues(\.rawValue),
      layers: layered.layers.map(SetupProfileLayerReport.init),
      observation: packageInventoryReader(), adoptionState: adoptionState,
      declarations: declarations
    )
  }

  private func packageDeclarations(
    context: UnifiedSetupPlanContext, profile: PortableProfile, capabilities: [SetupCapability]
  ) throws -> SetupPackageDeclarations {
    // Personal mode must not load or fall back to release defaults.
    let standard =
      profile.packages.baseline == .standard
      ? try standardBrewfile(context.environmentResourcesRoot.appending(path: "Brewfile"))
      : SetupBrewfile(packages: [])
    return try SetupPackageDeclarations.compile(
      standard: standard, profile: profile.packages, requirements: capabilities,
      readBrewfile: personalBrewfile)
  }

  private func setupCapabilities(
    profile: PortableProfile, homeDirectory: URL, desktopResourcesRoot: URL
  ) throws -> [SetupCapability] {
    try DependencyProfile.personal(homeDirectory: homeDirectory).selectedForSetup(
      profile,
      defaultsURL: DesktopDesiredState.sketchyBarDefaultsURL(resourcesRoot: desktopResourcesRoot)
    ).map {
      SetupCapability(
        id: $0.id, category: $0.category,
        status: capabilityIsAvailable($0) ? .present : .missing,
        requirement: $0.requirement, remediation: $0.remediation
      )
    }
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
      layered = try context.loadProfile(proposedSources: proposedProfileSources)
    } catch {
      return .blocked(
        UnifiedSetupPlanReport.blocked(
          layers: profileFailureLayers(context: context, error: error),
          fieldOrigins: [:],
          error: String(describing: error)
        )
      )
    }

    let profile = layered.profile
    let layers = layered.layers.map(SetupProfileLayerReport.init)
    let fieldOrigins = layered.fieldOrigins.mapValues(\.rawValue)
    func inputBlocked(_ error: any Error) -> UnifiedSetupPreparation {
      .blocked(
        UnifiedSetupPlanReport.blocked(
          layers: layers, fieldOrigins: fieldOrigins, error: String(describing: error)))
    }
    let capabilities = try setupCapabilities(
      profile: profile, homeDirectory: context.homeDirectory,
      desktopResourcesRoot: context.desktopResourcesRoot)
    let declarations: SetupPackageDeclarations
    do {
      declarations = try packageDeclarations(
        context: context, profile: profile, capabilities: capabilities)
    } catch {
      return inputBlocked(error)
    }

    let inventory = SetupPackageInventory(
      capabilities: capabilities, fieldOrigins: fieldOrigins, layers: layers,
      observation: packageInventoryReader(),
      adoptionState: SetupPackageAdoptionStore(
        stateRoot: context.stateRoot, homeDirectory: context.homeDirectory
      ).inspect(),
      declarations: declarations)
    let packages: HomebrewInstallPlan
    do {
      packages = try HomebrewInstallPlan(inventory: inventory)
    } catch {
      var report = UnifiedSetupPlanReport.blocked(
        layers: layers, fieldOrigins: fieldOrigins, error: String(describing: error))
      report.packageDeclarations = declarations
      report.packageInventory = inventory
      return .blocked(report)
    }

    let themeSelection: (package: ThemePackage, plan: UnifiedSetupThemePlan)
    do {
      themeSelection = try themePlan(context: context)
    } catch {
      return inputBlocked(error)
    }

    let nativeStarters: [EnvironmentNativeSeed]
    let starterPlans: [EnvironmentNativeSeed.Plan]
    do {
      nativeStarters = try UnifiedSetupNativeStarters.prepare(
        context: context, profile: profile, theme: themeSelection.package)
      starterPlans = try nativeStarters.map { try $0.plan() }
    } catch {
      return inputBlocked(error)
    }
    let model = UnifiedSetupDesiredModel(
      profile: profile,
      layers: layers,
      fieldOrigins: fieldOrigins,
      themePackage: themeSelection.package,
      theme: themeSelection.plan,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs(profile),
      capabilities: capabilities,
      packages: packages,
      nativeStarters: nativeStarters
    )
    let desktop = try desktopPlanner(context, profile)
    var environmentContext = context
    environmentContext.nativeStarters = nativeStarters
    let environment = try environmentPlanner(
      environmentContext, profile,
      themeSelection.plan.currentGenerationID == nil ? themeSelection.package : nil
    )
    let components = SetupComponentPlans(
      desktop: desktop,
      environment: environment,
      preferences: SetupComponentPlan(
        try preferences.inspect(
          context: context.preferencesContext, desired: profile.macOSPreferences))
    )
    var diagnostics = [PlanDiagnostic]()
    for component in components.all where !component.succeeded {
      diagnostics.append(
        PlanDiagnostic(
          code: "\(component.stage.rawValue)_plan_blocked",
          source: component.stage.rawValue,
          message: componentFailureMessage(
            id: component.stage.rawValue, messages: component.diagnostics)
        )
      )
    }
    let actions = plannedActions(
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
      adoption: try adoptionEvidence(components, profile: profile),
      manualBoundaries: try manualBoundaries(
        profile: profile, installPlan: model.packages, stateRoot: context.stateRoot),
      actions: diagnostics.isEmpty ? actions : [],
      components: components,
      diagnostics: diagnostics,
      packageDeclarations: declarations,
      packageInventory: inventory,
      packageInstallation: packages.identities.isEmpty
        ? nil
        : try HomebrewBundleInstaller.Preview(
          packages: packages.identities, effectiveBrewfile: inventory.effectiveBrewfile,
          context: context),
      nativeStarters: starterPlans
    )
    guard diagnostics.isEmpty else { return .blocked(report) }
    return .ready(model, report)
  }

  private func componentFailureMessage(id: String, messages: [String]) -> String {
    guard !messages.isEmpty else { return "The delegated \(id) plan is blocked." }
    return "The delegated \(id) plan is blocked: \(messages.joined(separator: "; "))"
  }

  private func profileFailureLayers(
    context: UnifiedSetupPlanContext,
    error: Error
  ) -> [SetupProfileLayerReport] {
    let source: URL?
    switch error as? PortableProfileError {
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
    if let manifest = try ThemeGenerationReader(root: context.stateRoot)
      .activeManifestIfPresent()
    {
      themeID = manifest.themeID
      source = "active"
      currentGenerationID = manifest.generationID
    } else {
      themeID = "catppuccin-mocha"
      source = "curated_default"
      currentGenerationID = nil
    }
    let repository = ThemeRepository(
      builtInRoot: context.themesRoot,
      userRoot: StateLayout(root: context.stateRoot).userThemes
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
    var providers = profile.environment.roleProviders
    providers["desktop"] = profile.desktop.provider.rawValue
    providers["top_bar"] = profile.topBar.rawValue
    return providers
  }

  private func enabledThemeAdapterIDs(_ profile: PortableProfile) -> [String] {
    Set(profile.environment.selectedThemeAdapterIDs)
      .union(profile.nonEnvironmentThemeAdapterIDs).sorted()
  }

  private func enabledPresets(_ profile: PortableProfile) -> [EnvironmentPreset] {
    EnvironmentPreset.allCases.filter { $0.isEnabled(in: profile.environment.presets) }
  }

  private func services(_ profile: PortableProfile) -> [UnifiedSetupService] {
    profile.environment.focusRing.setupServices + profile.desktopSetupServices
      + enabledPresets(profile).compactMap(\.setupService)
  }

  private func permissions(_ profile: PortableProfile) -> [UnifiedSetupPermission] {
    [
      UnifiedSetupPermission(
        id: "system_events_automation",
        status: "manual_boundary",
        message: "macOS may request Automation access when applying system appearance."
      )
    ] + profile.desktopSetupPermissions
  }

  private func manualBoundaries(
    profile: PortableProfile,
    installPlan: HomebrewInstallPlan,
    stateRoot: URL
  ) throws -> [UnifiedSetupManualBoundary] {
    var result = installPlan.external.map {
      UnifiedSetupManualBoundary(
        id: $0.capabilityID,
        kind: "external_prerequisite",
        instruction: $0.instruction
      )
    }
    if try EnvironmentStateStore(stateRoot: stateRoot).hasUnverifiedSpicetifyRecovery() {
      result.append(
        UnifiedSetupManualBoundary(
          id: "spicetify_runtime_restoration", kind: "unverified",
          instruction: EnvironmentStateStore.spicetifyRecoveryMessage))
    }
    result += profile.desktopSetupManualBoundaries
    result += enabledPresets(profile).compactMap(\.setupManualBoundary)
    return result
  }

  private func plannedFiles(
    profile: PortableProfile,
    components: SetupComponentPlans,
    homeDirectory: URL
  ) throws -> [UnifiedSetupFile] {
    var result = [UnifiedSetupFile]()
    let desktop = components.desktop.report
    if profile.desktop.provider == .yabaiSkhd {
      let keybindings = try components.desktop.keybindings
      result.append(
        UnifiedSetupFile(
          id: "skhd_entry",
          path: homeDirectory.appending(path: ConsumerHomePath.skhdConfiguration).path,
          status: keybindings.providerStatus,
          ownership: keybindings.ownership
        )
      )
    }
    result.append(UnifiedSetupFile(id: "yabai_entry", provider: desktop.provider))
    if let provider = desktop.sketchyBar?.provider {
      result.append(UnifiedSetupFile(id: "sketchybar_entry", provider: provider))
    }
    result += components.environment.report.entries.map {
      UnifiedSetupFile(
        id: $0.id, path: $0.path, status: $0.status.rawValue, ownership: $0.ownership)
    }
    return result.sorted { lhs, rhs in
      lhs.path == rhs.path ? lhs.id < rhs.id : lhs.path < rhs.path
    }
  }

  private func adoptionEvidence(
    _ components: SetupComponentPlans, profile: PortableProfile
  ) throws -> [UnifiedSetupAdoptionEvidence] {
    var result = [UnifiedSetupAdoptionEvidence]()
    func append(_ target: UnifiedSetupAdoptionTarget, status: String, digest: String?) {
      guard status == "adoption_required", let digest else { return }
      result.append(UnifiedSetupAdoptionEvidence(id: target.rawValue, digest: digest))
    }
    let keybindings = try components.desktop.keybindings
    if profile.desktop.provider == .yabaiSkhd {
      append(
        .keybindings,
        status: keybindings.providerStatus,
        digest: keybindings.adoptionEvidenceDigest
      )
    }
    let desktop = components.desktop.report
    append(
      .yabai,
      status: desktop.provider.status.rawValue,
      digest: desktop.provider.adoptionEvidenceDigest
    )
    if let provider = desktop.sketchyBar?.provider {
      append(
        .sketchybar,
        status: provider.status.rawValue,
        digest: provider.adoptionEvidenceDigest
      )
    }
    if let digest = components.environment.report.adoptionEvidenceDigest {
      result.append(
        UnifiedSetupAdoptionEvidence(
          id: UnifiedSetupAdoptionTarget.environment.rawValue, digest: digest))
    }
    return result
  }

  private func plannedActions(
    installPlan: HomebrewInstallPlan,
    theme: UnifiedSetupThemePlan,
    components: SetupComponentPlans
  ) -> [UnifiedSetupAction] {
    var result = [UnifiedSetupAction]()
    if !installPlan.formulae.isEmpty || !installPlan.casks.isEmpty {
      result.append(
        UnifiedSetupAction(
          stage: "packages",
          id: "install_homebrew_packages",
          message:
            "Install the effective setup's missing Homebrew packages without adopting installed packages."
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
          stage: SetupStage.theme.rawValue,
          id: "activate_curated_theme",
          message: "Activate the curated default theme '\(theme.id)'."
        )
      )
    }
    for component in components.all {
      result += component.actions.map {
        UnifiedSetupAction(stage: component.stage.rawValue, id: $0.id, message: $0.message)
      }
    }
    return result
  }
}

/// A component stage's plan: the component's own report, embedded verbatim in the setup plan.
struct SetupComponentPlan<Report: Encodable & Sendable>: Encodable, Sendable {
  let succeeded: Bool
  let report: Report

  private init(succeeded: Bool, report: Report) {
    self.succeeded = succeeded
    self.report = report
  }
}

extension SetupComponentPlan where Report == DesktopPlanReport {
  init(_ report: DesktopPlanReport) { self.init(succeeded: report.succeeded, report: report) }

  /// Absent when the desktop planner could not plan keybindings; its diagnostics say why.
  var keybindings: DesktopKeybindingPlan {
    get throws {
      guard let keybindings = report.keybindings else {
        throw SetupComponentReportError(
          description: "Delegated plan is missing desktop.keybindings")
      }
      return keybindings
    }
  }
}

extension SetupComponentPlan where Report == EnvironmentPlanReport {
  init(_ report: EnvironmentPlanReport) { self.init(succeeded: report.succeeded, report: report) }
}

extension SetupComponentPlan where Report == PreferencesReport {
  init(_ report: PreferencesReport) { self.init(succeeded: report.succeeded, report: report) }
}

struct SetupComponentPlans: Encodable, Sendable {
  let desktop: SetupComponentPlan<DesktopPlanReport>
  let environment: SetupComponentPlan<EnvironmentPlanReport>
  let preferences: SetupComponentPlan<PreferencesReport>

  /// The planned component stages, in apply order; the theme stage is planned by setup itself.
  var all: [(stage: SetupStage, succeeded: Bool, actions: [PlanAction], diagnostics: [String])] {
    [
      (
        .desktop, desktop.succeeded, desktop.report.actions,
        desktop.report.diagnostics.map(\.message)
      ),
      (
        .environment, environment.succeeded, environment.report.actions,
        environment.report.diagnostics.map(\.message)
      ),
      (
        .preferences, preferences.succeeded, preferences.report.actions,
        preferences.report.diagnostics.map(\.message)
      ),
    ]
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

extension UnifiedSetupFile {
  init(id: String, provider: DesktopProviderPlanInspection) {
    self.init(
      id: id, path: provider.entryPoint, status: provider.status.rawValue,
      ownership: provider.ownership.rawValue)
  }
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

struct UnifiedSetupPlanReport: CommandReport {
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
  let diagnostics: [PlanDiagnostic]
  var packageDeclarations: SetupPackageDeclarations? = nil
  var packageInventory: SetupPackageInventory? = nil
  var packageInstallation: HomebrewBundleInstaller.Preview? = nil
  var nativeStarters: [EnvironmentNativeSeed.Plan] = []

  func approvalText() throws -> String {
    // Unrelated observed receipts and adoption history are not install authority.
    var inputs = self
    inputs.packageInventory = nil
    return try inputs.render(json: true)
  }

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
      packages: HomebrewInstallPlan(),
      files: [],
      services: [],
      permissions: [],
      adoption: [],
      manualBoundaries: [],
      actions: [],
      components: nil,
      diagnostics: [
        PlanDiagnostic(
          code: code,
          source: "setup",
          message: error
        )
      ]
    )
  }

  func renderText() throws -> String {
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
    if !nativeStarters.isEmpty {
      lines.append("Writable native starters (absent-only; retained on failure and teardown):")
      for starter in nativeStarters {
        if let parent = starter.parentDirectory {
          lines.append("- Ensure ordinary user directory: \(parent) (0700 when created)")
        }
        lines.append("- \(starter.provider): \(starter.destination) — \(starter.approval)")
        lines.append(starter.contents)
      }
    }
    lines.append(capabilities.isEmpty ? "Core capabilities: none" : "Core capabilities:")
    lines += capabilities.map {
      "- \($0.id) [\($0.status.rawValue)]: \($0.requirement)"
    }
    lines.append(packages.humanOutput)
    if let packageInventory { lines.append(packageInventory.humanOutput) }
    if let packageInstallation {
      lines.append("Missing-package Brewfile:\n" + packageInstallation.brewfile)
      lines.append("Native command: " + packageInstallation.command.joined(separator: " "))
      lines += packageInstallation.nativeEffects
      lines.append(
        "Homebrew owns dependency and related-package effects; no package rollback or automatic adoption."
      )
      lines.append(
        "Approve installation with --approve-packages \(packageInstallation.approvalDigest).")
    }
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
    if let preferences = components?.preferences.report, preferences.outcome != "disabled" {
      lines.append(preferences.target)
      lines.append(preferences.runtime)
      if let digest = preferences.approvalDigest {
        lines.append("Approve native preference changes with --approve-preferences \(digest).")
      }
    }
    lines += PlanDiagnostic.renderLines(diagnostics)
    lines.append("No changes made.")
    return lines.joined(separator: "\n")
  }

  var preferencesApprovalDigest: String? { components?.preferences.report.approvalDigest }

  var preferencesAutomationPermission: MacOSPreference? {
    components?.preferences.report.automationPermission
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

/// A delegated command's rendered `--json` result, embedded verbatim by setup apply,
/// teardown, inspection and package addition.
struct SetupComponentExecution: Encodable, Sendable {
  let succeeded: Bool
  let report: JSONValue
  let outcome: String

  init(_ execution: CommandExecution) throws {
    succeeded = execution.succeeded
    report = try JSONDecoder().decode(JSONValue.self, from: Data(execution.output.utf8))
    guard let object = report.object else {
      throw SetupComponentReportError(
        description: "Delegated plan field component is not an object")
    }
    guard let value = object["outcome"] else {
      throw SetupComponentReportError(description: "Delegated plan is missing component.outcome")
    }
    guard let outcome = value.string else {
      throw SetupComponentReportError(
        description: "Delegated plan field component.outcome is not a string")
    }
    self.outcome = outcome
  }

  enum CodingKeys: CodingKey {
    case succeeded, report
  }
}
