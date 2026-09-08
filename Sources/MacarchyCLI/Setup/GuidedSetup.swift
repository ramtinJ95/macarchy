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

  func confirm(_ question: String, defaultYes: Bool) throws -> Bool {
    while true {
      write("\(question) \(defaultYes ? "[Y/n]" : "[y/N]") ")
      guard let answer = read() else { throw GuidedSetupError.inputClosed }
      switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "": return defaultYes
      case "y", "yes": return true
      case "n", "no": return false
      default: write("Please answer yes or no.\n")
      }
    }
  }
}

struct GuidedSetupQuestionnaire: Sendable {
  let io: GuidedSetupIO

  func collect() throws -> GuidedSetupAnswers {
    var answers = GuidedSetupAnswers()
    answers.desktop = try io.confirm("Manage the yabai and skhd desktop?", defaultYes: true)
    answers.topBar = try io.confirm("Manage the SketchyBar top bar?", defaultYes: true)
    answers.focusRing = try io.confirm(
      "Manage theme-coherent Borders focus highlighting?", defaultYes: true)
    answers.terminal = try io.confirm("Manage Kitty as the terminal?", defaultYes: true)
    answers.shell = try io.confirm("Manage zsh as the shell?", defaultYes: true)
    if answers.shell {
      answers.prompt = try io.confirm("Manage Starship as the prompt?", defaultYes: true)
      answers.history = try io.confirm("Manage Atuin history?", defaultYes: true)
    } else {
      answers.prompt = false
      answers.history = false
    }
    answers.editor = try io.confirm("Manage Neovim as the editor?", defaultYes: true)
    answers.bat = try io.confirm("Manage bat?", defaultYes: true)
    answers.eza = try io.confirm("Manage eza?", defaultYes: true)
    answers.btop = try io.confirm("Manage btop?", defaultYes: true)
    answers.yazi = try io.confirm("Manage Yazi?", defaultYes: true)
    answers.codex = try io.confirm("Enable the Codex preset?", defaultYes: false)
    answers.herdr = try io.confirm("Enable the Herdr preset?", defaultYes: false)
    answers.pi = try io.confirm("Enable the Pi preset?", defaultYes: false)
    answers.slack = try io.confirm("Enable the Slack preset?", defaultYes: false)
    answers.spicetify = try io.confirm("Enable the Spicetify preset?", defaultYes: false)
    answers.tuicr = try io.confirm("Enable the tuicr preset?", defaultYes: false)
    if try io.confirm("Manage Dock autohide?", defaultYes: false) {
      answers.dockAutohide = try io.confirm("Automatically hide the Dock?", defaultYes: true)
    }
    if try io.confirm("Manage Finder filename extensions?", defaultYes: false) {
      answers.finderShowExtensions = try io.confirm(
        "Show all filename extensions?", defaultYes: true)
    }
    io.write(
      "Package choices are separate from provider/preset choices. Exclusions never uninstall software.\n"
        + "Selected providers still require their packages; disable the provider to exclude one.\n")
    while true {
      io.write(
        "Optional package exclusions (space-separated, e.g. formula:jq cask:spotify; Enter for none): "
      )
      guard let input = io.read() else { throw GuidedSetupError.inputClosed }
      let targets = input.split(whereSeparator: \.isWhitespace).map(String.init)
      if targets.isEmpty { break }
      do {
        answers.packageExclusions = try SetupPackageAdoptionCommandRunner.parseTargets(targets)
        break
      } catch let error as SetupPackageAdoptionError {
        io.write("\(error)\n")
      }
    }
    return answers
  }
}

enum GuidedSetupError: Error, CustomStringConvertible, Sendable {
  case inputClosed
  case invalidProfileTarget(URL)
  case profileTargetExists(URL)

  var description: String {
    switch self {
    case .inputClosed:
      "guided setup input closed before the questionnaire completed"
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
    consumerPaths: ThemeConsumerPaths
  ) async throws -> (output: String, succeeded: Bool) {
    try await execute(
      context: context,
      consumerPaths: consumerPaths,
      answers: GuidedSetupQuestionnaire(io: io).collect()
    )
  }

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    answers: GuidedSetupAnswers
  ) async throws -> (output: String, succeeded: Bool) {
    try GuidedSetupProfileWriter.write(answers.profileTOML, to: context.profileURL)
    io.write("Wrote portable profile: \(context.profileURL.path)\n")

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
    let overridden = answers.packageExclusions.filter { !effectiveExclusions.contains($0) }
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
        "Complete the plan's external prerequisites, then run macarchy setup apply.",
        false
      )
    }

    let cancelled = ("Guided setup stopped before mutation. The profile was retained.", true)
    var approved = [String: String]()
    for adoption in plan.adoption {
      guard
        try io.confirm(
          "Approve \(adoption.id) adoption for \(adoption.digest)?",
          defaultYes: false
        )
      else {
        return cancelled
      }
      approved[adoption.id] = adoption.digest
    }
    let adoptions = UnifiedSetupAdoptionApprovals(
      yabai: approved["yabai"],
      keybindings: approved["keybindings"],
      sketchybar: approved["sketchybar"],
      environment: approved["environment"]
    )

    let packageApproval = plan.packageInstallation?.approvalDigest
    if let packageApproval {
      guard
        try io.confirm(
          "Install the reviewed missing-package Brewfile for \(packageApproval)?", defaultYes: false
        )
      else { return cancelled }
    }
    let preferencesApproval = try plan.preferencesApprovalDigest
    if let preferencesApproval {
      guard
        try io.confirm(
          "Approve the reviewed native preference changes for \(preferencesApproval)?",
          defaultYes: false
        )
      else { return cancelled }
    }
    guard try io.confirm("Apply the reviewed unified setup plan now?", defaultYes: false) else {
      return cancelled
    }
    return try await apply(context, consumerPaths, packageApproval, preferencesApproval, adoptions)
  }
}
