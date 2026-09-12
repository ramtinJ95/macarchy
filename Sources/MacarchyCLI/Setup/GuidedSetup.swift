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
    var sections = [[String]]()
    func add(_ table: String, _ fields: [String]) {
      if !fields.isEmpty { sections.append(["[\(table)]"] + fields) }
    }

    add("desktop", desktop ? [] : ["provider = \"disabled\""])
    add("top_bar", topBar ? [] : ["provider = \"disabled\""])
    add("focus_ring", focusRing ? [] : ["provider = \"disabled\""])
    add("terminal", terminal ? [] : ["provider = \"disabled\""])
    add("shell", shell ? [] : ["provider = \"disabled\""])
    if shell {
      add("prompt", prompt ? [] : ["provider = \"disabled\""])
      add("history", history ? [] : ["provider = \"disabled\""])
    }
    add("editor", editor ? [] : ["provider = \"disabled\""])
    add(
      "tools",
      [
        bat ? nil : "bat = false",
        eza ? nil : "eza = false",
        btop ? nil : "btop = false",
        yazi ? nil : "yazi = false",
      ].compactMap { $0 }
    )
    add(
      "presets",
      [
        codex ? "codex = true" : nil,
        herdr ? "herdr = true" : nil,
        pi ? "pi = true" : nil,
        slack ? "slack = true" : nil,
        spicetify ? "spicetify = true" : nil,
        tuicr ? "tuicr = true" : nil,
      ].compactMap { $0 }
    )

    let preferences = [
      dockAutohide.map { "dock_autohide = \($0)" },
      finderShowExtensions.map { "finder_show_extensions = \($0)" },
    ].compactMap { $0 }
    add("macos_preferences", preferences.isEmpty ? [] : ["enabled = true"] + preferences)

    let formulae = packageExclusions.filter { $0.kind == .formula }.map { "\"\($0.name)\"" }
    let casks = packageExclusions.filter { $0.kind == .cask }.map { "\"\($0.name)\"" }
    add(
      "packages",
      [
        formulae.isEmpty ? nil : "exclude_formulae = [\(formulae.joined(separator: ", "))]",
        casks.isEmpty ? nil : "exclude_casks = [\(casks.joined(separator: ", "))]",
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
    ) async throws -> (output: String, succeeded: Bool)

  let planner: UnifiedSetupPlanCommandRunner
  let apply: Apply
  let io: GuidedSetupIO
  var select: @Sendable ([HomebrewPackageIdentity]) throws -> GuidedSetupAnswers =
    GuidedSetupTerminal.collect

  static func live(io: GuidedSetupIO = .live) -> Self {
    Self(
      planner: .live,
      apply: { context, consumerPaths, packageApproval, preferencesApproval, adoptions in
        try await UnifiedSetupApplyCommandRunner.live.execute(
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
  ) async throws -> (output: String, succeeded: Bool) {
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
    let answers = try select(packages)
    return try await execute(context: context, consumerPaths: consumerPaths, answers: answers)
  }

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    answers: GuidedSetupAnswers
  ) async throws -> (output: String, succeeded: Bool) {
    var context = context
    context.nativeStarterProviders = answers.nativeStarterProviders
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let nativeSources = try answers.nativeStarterProviders.map { provider in
      let path = try encoder.encode(
        UnifiedSetupNativeStarters.profilePath(provider, context: context))
      return "[\(provider.rawValue)]\n\(provider.profileKey) = "
        + String(decoding: path, as: UTF8.self) + "\n"
    }.joined(separator: "\n")
    try GuidedSetupProfileWriter.write(
      answers.profileTOML + "\n" + nativeSources, to: context.profileURL)
    io.write("Wrote portable profile: \(context.profileURL.path)\n")

    return try await reviewAndApply(
      context: context, consumerPaths: consumerPaths, packageExclusions: answers.packageExclusions)
  }

  private func reviewAndApply(
    context: UnifiedSetupPlanContext, consumerPaths: ThemeConsumerPaths,
    packageExclusions: [HomebrewPackageIdentity]
  ) async throws -> (output: String, succeeded: Bool) {
    var context = context
    let preparation = try planner.prepare(context: context)
    let plan = planner.inspectedReport(preparation.report, context: context)
    io.write("\(try plan.render(json: false))\n")
    guard case .ready(let model, _) = preparation else {
      return (
        "Guided setup stopped because the unified plan is blocked. The profile was retained.",
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
        "Complete the plan's external prerequisites, then run macarchy setup guided --resume with the same profile options.",
        false
      )
    }

    let cancelled = (
      "Guided setup stopped before mutation. The profile was retained; no native starters were created. Continue with macarchy setup guided --resume and the same profile options.",
      true
    )
    // The single consent covers only the digests in the visible reviewed plan.
    // Unified apply still revalidates them before mutation.
    var approved = [String: String]()
    for adoption in plan.adoption {
      io.write("Configuration adoption: \(adoption.id) — \(adoption.digest)\n")
      approved[adoption.id] = adoption.digest
    }
    let adoptions = UnifiedSetupAdoptionApprovals(
      yabai: approved["yabai"],
      keybindings: approved["keybindings"],
      sketchybar: approved["sketchybar"],
      environment: approved["environment"]
    )
    let packageApproval = plan.packageInstallation?.approvalDigest
    let preferencesApproval = try plan.preferencesApprovalDigest
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
    )
    guard try io.confirm("Install & apply the reviewed setup now?") else {
      return cancelled
    }
    return try await apply(context, consumerPaths, packageApproval, preferencesApproval, adoptions)
  }
}
