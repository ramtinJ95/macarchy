import Darwin
import Foundation
import ThemeCore

struct GuidedSetupAnswers: Sendable {
  var desktop = true
  var topBar = true
  var focusRing = true
  var terminal = true
  var shell = true
  var prompt = true
  var history = true
  var editor = true
  var bat = true
  var eza = true
  var btop = true
  var yazi = true
  var codex = false
  var herdr = false
  var pi = false
  var slack = false
  var spicetify = false
  var tuicr = false
  var dockAutohide: Bool?
  var finderShowExtensions: Bool?
  var packageAdditions: [HomebrewPackageIdentity] = []
  var packageExclusions: [HomebrewPackageIdentity] = []

  var nativeStarterProviders: [EnvironmentNativeSeed.Provider] {
    [
      shell ? .zsh : nil,
      terminal ? .kitty : nil,
      shell && history ? .atuin : nil,
      shell && prompt ? .starship : nil,
      editor ? .neovim : nil,
    ].compactMap { $0 }
  }

  var profileTOML: String {
    profileTOML(addingBrewfile: nil)
  }

  func profileTOML(addingBrewfile: String?) -> String {
    var sections = [[String]]()
    func add(_ table: String, _ fields: [String]) {
      if !fields.isEmpty { sections.append(["[\(table)]"] + fields) }
    }
    func provider<Provider: PortableProfileProvider>(_: Provider.Type, enabled: Bool) {
      let key = Provider.key(\.self)
      add(Provider.table, enabled ? [] : ["\(key) = \"\(Provider.disabled.rawValue)\""])
    }

    provider(DesktopProviderSelection.self, enabled: desktop)
    provider(TopBarProviderSelection.self, enabled: topBar)
    provider(FocusRingProviderSelection.self, enabled: focusRing)
    provider(TerminalProviderSelection.self, enabled: terminal)
    provider(ShellProviderSelection.self, enabled: shell)
    if shell {
      provider(PromptProviderSelection.self, enabled: prompt)
      provider(HistoryProviderSelection.self, enabled: history)
    }
    provider(EditorProviderSelection.self, enabled: editor)
    add(
      DailyToolsProfile.table,
      [
        bat ? nil : DailyToolsProfile.key(\.bat) + " = false",
        eza ? nil : DailyToolsProfile.key(\.eza) + " = false",
        btop ? nil : DailyToolsProfile.key(\.btop) + " = false",
        yazi ? nil : DailyToolsProfile.key(\.yazi) + " = false",
      ].compactMap { $0 }
    )
    add(
      PresetsProfile.table,
      [
        codex ? PresetsProfile.key(\.codex) + " = true" : nil,
        herdr ? PresetsProfile.key(\.herdr) + " = true" : nil,
        pi ? PresetsProfile.key(\.pi) + " = true" : nil,
        slack ? PresetsProfile.key(\.slack) + " = true" : nil,
        spicetify ? PresetsProfile.key(\.spicetify) + " = true" : nil,
        tuicr ? PresetsProfile.key(\.tuicr) + " = true" : nil,
      ].compactMap { $0 }
    )

    let preferences = [
      dockAutohide.map { MacOSPreferencesProfile.key(\.dockAutohide) + " = \($0)" },
      finderShowExtensions.map {
        MacOSPreferencesProfile.key(\.finderShowExtensions) + " = \($0)"
      },
    ].compactMap { $0 }
    add(
      MacOSPreferencesProfile.table,
      preferences.isEmpty ? [] : [MacOSPreferencesProfile.key(\.enabled) + " = true"] + preferences)

    let formulae = packageExclusions.filter { $0.kind == .formula }.map { "\"\($0.name)\"" }
    let casks = packageExclusions.filter { $0.kind == .cask }.map { "\"\($0.name)\"" }
    add(
      PackageProfile.table,
      [
        addingBrewfile.map { "\(PackageProfile.brewfileKey) = \($0)" },
        formulae.isEmpty
          ? nil
          : "\(PackageProfile.excludedFormulaeKey) = [\(formulae.joined(separator: ", "))]",
        casks.isEmpty
          ? nil : "\(PackageProfile.excludedCasksKey) = [\(casks.joined(separator: ", "))]",
      ].compactMap { $0 }
    )

    return ([["schema_version = 1"]] + sections)
      .map { $0.joined(separator: "\n") }
      .joined(separator: "\n\n") + "\n"
  }
}

struct GuidedSetupIO: Sendable {
  let read: @Sendable () -> String?
  let write: @Sendable (String) -> Void

  static let live = Self(
    read: { readLine() },
    write: { FileHandle.standardOutput.write(Data($0.utf8)) }
  )

  func confirm(_ question: String) throws -> Bool {
    while true {
      write("\(question) [y/N] ")
      guard let answer = read() else { throw GuidedSetupError.inputClosed }
      switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "y", "yes": return true
      case "", "n", "no": return false
      default: write("Please answer yes or no.\n")
      }
    }
  }
}

enum GuidedSetupError: Error, CustomStringConvertible, Sendable {
  case inputClosed
  case terminalUnavailable
  case invalidProfileTarget(URL)
  case profileTargetExists(URL)

  var description: String {
    switch self {
    case .inputClosed:
      "guided setup cancelled or input closed"
    case .terminalUnavailable:
      "guided setup requires an interactive terminal; use setup plan/apply with a profile instead"
    case .invalidProfileTarget(let url):
      "guided setup profile target is invalid: \(url.path)"
    case .profileTargetExists(let url):
      "guided setup will not replace existing profile state at \(url.path)"
    }
  }
}

enum GuidedSetupProfileWriter {
  static func write(
    answers: GuidedSetupAnswers, nativeSources: String, to target: URL
  ) throws -> URL? {
    guard !answers.packageAdditions.isEmpty else {
      try write(answers.profileTOML + "\n" + nativeSources, to: target)
      return nil
    }
    // Reuse personal package intent, with create-only publication. A crash before
    // the profile leaves an unreferenced fragment, never a dangling live profile.
    let fragment = target.deletingLastPathComponent().appending(
      path: "guided-packages-\(UUID().uuidString.lowercased()).Brewfile")
    let brewfile = SetupBrewfile.installing(answers.packageAdditions)
    _ = try SetupBrewfile.parse(brewfile.text)
    let quoted = String(
      decoding: try JSONEncoder().encode(fragment.lastPathComponent), as: UTF8.self)
    try write(brewfile.text, to: fragment)
    do {
      try write(
        answers.profileTOML(addingBrewfile: quoted) + "\n" + nativeSources, to: target)
    } catch {
      throw SetupPackageAdoptionError(
        "Profile publication failed: \(error). Unreferenced package fragment retained at \(fragment.path); no installation ran."
      )
    }
    return fragment
  }

  static func write(_ profile: String, to target: URL) throws {
    let target = target.standardizedFileURL
    let parent = target.deletingLastPathComponent()
    let name = target.lastPathComponent
    guard !name.isEmpty, parent.path != target.path else {
      throw GuidedSetupError.invalidProfileTarget(target)
    }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let parentDescriptor = try PinnedFilesystem.openDirectory(at: parent)
    defer { Darwin.close(parentDescriptor) }
    do {
      try PinnedFilesystem.writeNewRegularFile(
        parentDescriptor: parentDescriptor,
        name: name,
        url: target,
        data: Data(profile.utf8),
        mode: 0o600
      )
    } catch let error as PinnedFilesystemError where error.code == EEXIST || error.code == ELOOP {
      throw GuidedSetupError.profileTargetExists(target)
    }
  }
}

struct GuidedSetupCommandRunner: Sendable {
  typealias Apply =
    @Sendable (
      UnifiedSetupPlanContext,
      ThemeConsumerPaths,
      String?,
      String?,
      UnifiedSetupAdoptionApprovals
    ) async throws -> CommandExecution

  let packageTrust: GuidedHomebrewTrust
  let planner: UnifiedSetupPlanCommandRunner
  let apply: Apply
  let io: GuidedSetupIO
  var select:
    @Sendable (
      [HomebrewPackageIdentity], @escaping GuidedSetupSelectionMenu.Requirements
    ) throws -> GuidedSetupAnswers =
      GuidedSetupTerminal.collect
  var requestAutomation: @Sendable (MacOSPreference) throws -> Void =
    NativePreferenceEvent.requestAutomation

  static func live(io: GuidedSetupIO = .live) -> Self {
    Self(
      packageTrust: .live(homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
      planner: .live,
      apply: { context, consumerPaths, packageApproval, preferencesApproval, adoptions in
        try await UnifiedSetupApplyCommandRunner.guided.execute(
          context: context,
          consumerPaths: consumerPaths,
          packageApproval: packageApproval,
          preferencesApproval: preferencesApproval,
          adoptions: adoptions,
          json: false
        )
      },
      io: io
    )
  }

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    resume: Bool = false
  ) async throws -> CommandExecution {
    if resume {
      let profile = try PortableProfileLoader().load(
        portableAt: context.profileURL, portableRequired: true,
        machineAt: context.machineProfileURL, machineRequired: context.machineProfileRequired)
      var context = context
      context.nativeStarterProviders = UnifiedSetupNativeStarters.pendingProviders(
        context: context, profile: profile.profile)
      let portable = try PortableProfileLoader().load(at: context.profileURL, required: true)
      let exclusions = portable.packages.layers.flatMap { layer in
        layer.excludedFormulae.map { HomebrewPackageIdentity(kind: .formula, name: $0) }
          + layer.excludedCasks.map { HomebrewPackageIdentity(kind: .cask, name: $0) }
      }
      io.write("Reviewing retained profile without rewriting it: \(context.profileURL.path)\n")
      return try await reviewAndApply(
        context: context, consumerPaths: consumerPaths, packageExclusions: exclusions)
    }
    let packages = try planner.standardBrewfile(
      context.environmentResourcesRoot.appending(path: "Brewfile")
    ).packages
    let answers = try select(packages) { answers in
      let profile = try PortableProfileLoader().decode(
        answers.profileTOML, source: context.profileURL)
      return Set(
        try DependencyProfile.personal(homeDirectory: context.homeDirectory).selectedForSetup(
          profile,
          defaultsURL: DesktopDesiredState.sketchyBarDefaultsURL(
            resourcesRoot: context.desktopResourcesRoot)
        ).compactMap { $0.remediation.homebrewPackage })
    }
    return try await execute(context: context, consumerPaths: consumerPaths, answers: answers)
  }

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    answers: GuidedSetupAnswers
  ) async throws -> CommandExecution {
    var context = context
    context.nativeStarterProviders = answers.nativeStarterProviders
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let nativeSources = try answers.nativeStarterProviders.map { provider in
      let path = try encoder.encode(
        UnifiedSetupNativeStarters.profilePath(provider, context: context))
      return "[\(provider.profileTable)]\n\(provider.profileKey) = "
        + String(decoding: path, as: UTF8.self) + "\n"
    }.joined(separator: "\n")
    if let fragment = try GuidedSetupProfileWriter.write(
      answers: answers, nativeSources: nativeSources, to: context.profileURL)
    {
      io.write("Wrote personal package fragment: \(fragment.path)\n")
    }
    io.write("Wrote portable profile: \(context.profileURL.path)\n")

    return try await reviewAndApply(
      context: context, consumerPaths: consumerPaths, packageExclusions: answers.packageExclusions)
  }

  private func reviewAndApply(
    context: UnifiedSetupPlanContext, consumerPaths: ThemeConsumerPaths,
    packageExclusions: [HomebrewPackageIdentity], trustReviewed: Bool = false
  ) async throws -> CommandExecution {
    var context = context
    var preparation = try planner.prepare(context: context)
    var requested = Set<MacOSPreference>()
    while let key = preparation.report.preferencesAutomationPermission,
      requested.insert(key).inserted
    {
      io.write("\(try preparation.report.render(json: false))\n")
      let recipient = NativePreferenceEvent.application(for: key).url.deletingPathExtension()
        .lastPathComponent
      io.write(
        "Inspecting \(key.rawValue) needs Automation access to Apple's \(recipient). "
          + "macOS controls this permission; requesting it installs nothing and changes no preferences.\n"
      )
      guard try io.confirm("Show Apple's Automation consent dialog for \(recipient)?") else {
        return (
          "Automation consent was not requested. The profile was retained; continue with macarchy setup guided --resume and the same profile options.",
          false
        )
      }
      do {
        try requestAutomation(key)
      } catch {
        return (
          "\(error) The profile was retained; continue with macarchy setup guided --resume and the same profile options.",
          false
        )
      }
      preparation = try planner.prepare(context: context)
    }
    let plan = planner.inspectedReport(preparation.report, context: context)
    io.write("\(try plan.render(json: false))\n")
    guard case .ready(let model, _) = preparation else {
      return (
        "Guided setup stopped because the unified plan is blocked. The profile was retained; continue with macarchy setup guided --resume and the same profile options.",
        false
      )
    }
    guard let declarations = plan.packageDeclarations else {
      throw SetupPackageAdoptionError("The ready guided plan is missing package declarations.")
    }
    let effectiveExclusions = Set(declarations.exclusions.map(\.identity))
    let overridden = packageExclusions.filter { !effectiveExclusions.contains($0) }
    guard overridden.isEmpty else {
      return (
        "Machine package additions override these portable exclusions: "
          + overridden.map(\.key).joined(separator: ", ")
          + ". Review the machine profile before applying. The new portable profile was retained.",
        false
      )
    }
    io.write(
      "Setup installs the reviewed missing packages before configuring providers. Installed packages are not automatically adopted.\n"
    )
    guard model.packages.external.isEmpty else {
      return (
        "Complete these external prerequisites:\n"
          + model.packages.external.map { "- \($0.capabilityID): \($0.instruction)" }.joined(
            separator: "\n")
          + "\nThen run macarchy setup guided --resume with the same profile options.",
        false
      )
    }

    var grantedTrust = false
    do {
      let untrusted = try packageTrust.missing(model.packages.identities)
      if !untrusted.isEmpty {
        guard !trustReviewed else {
          throw SetupPackageAdoptionError(
            "Formula trust remains unresolved or the selected scope changed. Review and resume; no automatic retry."
          )
        }
        io.write(
          "Homebrew needs persistent trust for these exact formulae:\n"
            + untrusted.map { "- \($0.name)" }.joined(separator: "\n")
            + "\nThis permits loading their package code, not entire taps. Trust survives cancellation; it installs nothing.\n"
        )
        guard try io.confirm("Trust only these named Homebrew formulae?") else {
          return (
            "Formula trust declined. Profile retained; resume after resolving trust. No installation started.",
            false
          )
        }
        for package in untrusted { try packageTrust.grant(package) }
        grantedTrust = true
      }
    } catch {
      return (
        "\(error) Any completed trust grants remain. Profile retained; review and resume. No installation started.",
        false
      )
    }
    if grantedTrust {
      return try await reviewAndApply(
        context: context, consumerPaths: consumerPaths, packageExclusions: packageExclusions,
        trustReviewed: true)
    }

    let cancelled = (
      "Guided setup stopped before installation or configuration mutation. Prior permission/trust grants remain. The profile was retained; no native starters were created. Continue with macarchy setup guided --resume and the same profile options.",
      true
    )
    // The single consent covers only the digests in the visible reviewed plan.
    // Unified apply still revalidates them before mutation.
    var approved = [String: String]()
    for adoption in plan.adoption {
      io.write("Configuration adoption: \(adoption.id) — \(adoption.digest)\n")
      approved[adoption.id] = adoption.digest
    }
    let adoptions = UnifiedSetupAdoptionApprovals(digests: approved)
    let packageApproval = plan.packageInstallation?.approvalDigest
    let preferencesApproval = plan.preferencesApprovalDigest
    if let packageApproval {
      io.write("Homebrew installation approval: \(packageApproval)\n")
    }
    if let preferencesApproval {
      io.write("Native preference approval: \(preferencesApproval)\n")
    }
    context.nativeStarterApprovals = Dictionary(
      uniqueKeysWithValues: plan.nativeStarters.map {
        ($0.provider, $0.approval)
      })
    io.write(
      "Confirmation authorizes the reviewed package installation, configuration adoptions, "
        + "absent native starters, native preferences and provider/service changes, including desktop keybindings when selected.\n"
        + "Native starters become user-owned and are retained on failure or teardown; existing files are never replaced.\n"
        + "Homebrew effects are not rolled back with configuration. Permissions are never granted automatically.\n"
        + "Homebrew runs visibly in this terminal and may ask for your administrator password through sudo. Macarchy does not collect or store it.\n"
    )
    guard try io.confirm("Install & apply the reviewed setup now?") else {
      return cancelled
    }
    return try await apply(context, consumerPaths, packageApproval, preferencesApproval, adoptions)
  }
}
