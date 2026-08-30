import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SetupCommandTests {
  @Test
  func personalProfileClassifiesTheSupportedEnvironment() throws {
    let profile = try #require(
      DependencyProfile.named("personal", homeDirectory: URL(filePath: "/Users/test"))
    )

    #expect(
      ids(in: .platformRuntime, profile: profile)
        == ["macos-26", "arm64", "homebrew"]
    )
    #expect(
      ids(in: .desktopSubstrate, profile: profile)
        == ["kitty", "sketchybar", "skhd", "yabai"]
    )
    #expect(
      ids(in: .requiredAdapter, profile: profile)
        == [
          "atuin", "bat", "btop", "codex", "eza", "herdr", "neovim", "pi", "starship", "tuicr",
          "yazi",
        ]
    )
    #expect(ids(in: .optionalAdapter, profile: profile) == ["spicetify", "spotify"])
  }

  @Test
  func externalAtuinAndHerdrExecutablesRemainUnclaimedAndNeedNoFormula() throws {
    let home = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    try makeExecutable(home.appending(path: ".atuin/bin/atuin"))
    try makeExecutable(home.appending(path: ".local/bin/herdr"))

    let profile = DependencyProfile.personal(homeDirectory: home)
    let runner = SetupCommandRunner(
      resolveProfile: { _, _ in profile },
      capabilityIsAvailable: { capability in
        ["atuin", "herdr"].contains(capability.id) ? capability.isAvailable() : true
      },
      processRunner: unexpectedProcessRunner(),
      writePreMutationPlan: unexpectedPlanWriter(),
      setupIntegrations: externalIntegrations()
    )
    let execution = try runner.execute(
      profileName: "personal",
      homeDirectory: home,
      installDependencies: true,
      dryRun: true,
      json: true
    )
    let report = try decode(execution.output)

    #expect(execution.succeeded)
    #expect(report.dependencyInstallation.plan.formulae.isEmpty)
    #expect(
      preferredExternalOrHomebrewExecutableURL(
        homeDirectory: home,
        externalRelativePath: ".atuin/bin/atuin",
        homebrewExecutableName: "atuin"
      ) == home.appending(path: ".atuin/bin/atuin")
    )
    #expect(
      preferredExternalOrHomebrewExecutableURL(
        homeDirectory: home,
        externalRelativePath: ".local/bin/herdr",
        homebrewExecutableName: "herdr"
      ) == home.appending(path: ".local/bin/herdr")
    )
  }

  @Test
  func requiredAndOptionalMissingCapabilitiesHaveDistinctExitSemantics() throws {
    let requiredExecution = try runner(missing: ["bat", "spotify"]).execute(
      profileName: "personal",
      homeDirectory: URL(filePath: "/Users/test"),
      installDependencies: false,
      dryRun: false,
      json: true
    )
    let requiredReport = try decode(requiredExecution.output)

    #expect(!requiredExecution.succeeded)
    #expect(requiredReport.outcome == "missing_required_capabilities")
    #expect(requiredReport.summary?.missingRequiredCount == 1)
    #expect(requiredReport.summary?.missingOptionalCount == 1)
    #expect(!requiredReport.mutationAttempted)

    let optionalExecution = try runner(missing: ["spicetify", "spotify"]).execute(
      profileName: "personal",
      homeDirectory: URL(filePath: "/Users/test"),
      installDependencies: false,
      dryRun: true,
      json: true
    )
    let optionalReport = try decode(optionalExecution.output)

    #expect(optionalExecution.succeeded)
    #expect(optionalReport.outcome == "ready")
    #expect(optionalReport.summary?.missingRequiredCount == 0)
    #expect(optionalReport.summary?.missingOptionalCount == 2)
  }

  @Test
  func unknownProfileIsAnExplicitMachineReadableFailure() throws {
    let execution = try runner(missing: []).execute(
      profileName: "unknown",
      homeDirectory: URL(filePath: "/Users/test"),
      installDependencies: false,
      dryRun: false,
      json: true
    )
    let report = try decode(execution.output)
    #expect(!execution.succeeded)
    #expect(report.outcome == "unknown_profile")
    #expect(report.availableProfiles == ["personal"])
    #expect(report.capabilities == nil)
  }

  @Test
  func installDryRunShowsHomebrewPackagesAndExactExternalRemediation() throws {
    let runner = SetupCommandRunner(
      resolveProfile: DependencyProfile.named,
      capabilityIsAvailable: { _ in false },
      processRunner: unexpectedProcessRunner(),
      writePreMutationPlan: unexpectedPlanWriter(),
      setupIntegrations: externalIntegrations()
    )

    let execution = try runner.execute(
      profileName: "personal",
      homeDirectory: URL(filePath: "/Users/test"),
      installDependencies: true,
      dryRun: true,
      json: true
    )
    let report = try decode(execution.output)
    let plan = report.dependencyInstallation.plan

    #expect(!execution.succeeded)
    #expect(
      plan.formulae
        == [
          "atuin", "bat", "btop", "eza", "herdr", "neovim", "starship", "tuicr", "yazi",
          "spicetify-cli",
        ]
    )
    #expect(plan.casks == ["kitty", "codex", "spotify"])
    #expect(
      plan.external.map(\.capabilityId)
        == ["macos-26", "arm64", "homebrew", "sketchybar", "skhd", "yabai", "pi"]
    )
    #expect(
      plan.external.first { $0.capabilityId == "pi" }?.instruction
        == "Run: npm install --global @earendil-works/pi-coding-agent"
    )
    #expect(
      plan.external.first { $0.capabilityId == "skhd" }?.instruction
        == "Run: brew trust --formula asmvik/formulae/skhd && "
        + "HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "
        + "HOMEBREW_NO_INSTALL_UPGRADE=1 brew install --formula asmvik/formulae/skhd"
    )
  }

  @Test
  func installPrintsExactJSONPlanBeforeScopedHomebrewAndReinspects() throws {
    let missing = Mutex(Set(["bat", "codex"]))
    let events = Mutex([SetupTestEvent]())
    let runner = SetupCommandRunner(
      resolveProfile: DependencyProfile.named,
      capabilityIsAvailable: { capability in
        missing.withLock { !$0.contains(capability.id) }
      },
      processRunner: ProcessRunner { request in
        events.withLock { $0.append(.process(request)) }
        missing.withLock { state in
          if request.arguments.contains("bat") {
            state.remove("bat")
          }
          if request.arguments.contains("codex") {
            state.remove("codex")
          }
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      writePreMutationPlan: { output in
        events.withLock { $0.append(.plan(output)) }
      },
      setupIntegrations: externalIntegrations()
    )

    let execution = try runner.execute(
      profileName: "personal",
      homeDirectory: URL(filePath: "/Users/test"),
      installDependencies: true,
      dryRun: false,
      json: true
    )
    let report = try decode(execution.output)
    let observedEvents = events.withLock { $0 }
    let planOutput = try #require(observedEvents.first?.planOutput)
    let announcedPlan = try decodePreMutationPlan(planOutput)

    #expect(execution.succeeded)
    #expect(report.outcome == "ready")
    #expect(report.mutationAttempted)
    #expect(announcedPlan.operation == "setup_dependency_installation_plan")
    #expect(announcedPlan.plan.formulae == ["bat"])
    #expect(announcedPlan.plan.casks == ["codex"])
    #expect(
      observedEvents.dropFirst() == [
        .process(
          ProcessRequest(
            executableURL: URL(filePath: "/opt/homebrew/bin/brew"),
            arguments: ["install", "--formula", "--no-ask", "bat"],
            environmentOverrides: HomebrewInstallPlan.environment
          )
        ),
        .process(
          ProcessRequest(
            executableURL: URL(filePath: "/opt/homebrew/bin/brew"),
            arguments: ["install", "--cask", "--no-ask", "codex"],
            environmentOverrides: HomebrewInstallPlan.environment
          )
        ),
      ])
    #expect(
      report.capabilities?.filter { ["bat", "codex"].contains($0.id) }.map(\.status)
        == ["present", "present"]
    )
  }

  @Test
  func missingPlatformRuntimeBlocksAllHomebrewMutation() throws {
    let runner = SetupCommandRunner(
      resolveProfile: DependencyProfile.named,
      capabilityIsAvailable: { !["homebrew", "bat"].contains($0.id) },
      processRunner: unexpectedProcessRunner(),
      writePreMutationPlan: unexpectedPlanWriter(),
      setupIntegrations: externalIntegrations()
    )

    let execution = try runner.execute(
      profileName: "personal",
      homeDirectory: URL(filePath: "/Users/test"),
      installDependencies: true,
      dryRun: false,
      json: true
    )
    let report = try decode(execution.output)

    #expect(!execution.succeeded)
    #expect(report.outcome == "dependency_installation_blocked")
    #expect(!report.mutationAttempted)
    #expect(report.dependencyInstallation.failure?.kind == "blocked_prerequisites")
    #expect(report.dependencyInstallation.failure?.capabilityIds == ["homebrew"])
  }

  @Test
  func launchFailureRecordsTheExactAttemptedCommand() throws {
    let runner = SetupCommandRunner(
      resolveProfile: DependencyProfile.named,
      capabilityIsAvailable: { $0.id != "bat" },
      processRunner: ProcessRunner { _ in throw SetupTestError.launchFailed },
      writePreMutationPlan: { _ in },
      setupIntegrations: externalIntegrations()
    )

    let execution = try runner.execute(
      profileName: "personal",
      homeDirectory: URL(filePath: "/Users/test"),
      installDependencies: true,
      dryRun: false,
      json: true
    )
    let report = try decode(execution.output)
    let command = try #require(report.dependencyInstallation.commands.first)

    #expect(!execution.succeeded)
    #expect(report.outcome == "dependency_installation_failed")
    #expect(report.mutationAttempted)
    #expect(command.executable == "/opt/homebrew/bin/brew")
    #expect(command.arguments == ["install", "--formula", "--no-ask", "bat"])
    #expect(command.outcome == "launch_failed")
    #expect(command.error == "launch failed")
  }

  @Test
  func zeroExitStillFailsWhenAPlannedOptionalCapabilityRemainsMissing() throws {
    let runner = SetupCommandRunner(
      resolveProfile: DependencyProfile.named,
      capabilityIsAvailable: { $0.id != "spicetify" },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 0, output: "")
      },
      writePreMutationPlan: { _ in },
      setupIntegrations: externalIntegrations()
    )

    let execution = try runner.execute(
      profileName: "personal",
      homeDirectory: URL(filePath: "/Users/test"),
      installDependencies: true,
      dryRun: false,
      json: true
    )
    let report = try decode(execution.output)

    #expect(!execution.succeeded)
    #expect(report.outcome == "dependency_installation_verification_failed")
    #expect(report.dependencyInstallation.failure?.kind == "verification_failed")
    #expect(report.dependencyInstallation.failure?.capabilityIds == ["spicetify"])
  }

  @Test
  func setupDelegatesPreviewAndApplyToTheAuthoritativeKeybindingPath() throws {
    let home = temporaryDirectory()
    let portableProfile = home.appending(path: "portable/profile.toml")
    let calls = Mutex<[String]>([])
    let runner = SetupCommandRunner(
      resolveProfile: DependencyProfile.named,
      capabilityIsAvailable: { _ in true },
      processRunner: unexpectedProcessRunner(),
      writePreMutationPlan: unexpectedPlanWriter(),
      setupIntegrations: externalIntegrations(),
      setupKeybindings: { profile, required, selectedHome, dryRun, adopt in
        calls.withLock {
          $0.append(
            "\(profile.path)|\(required)|\(selectedHome.path)|\(dryRun)|\(adopt)"
          )
        }
        return SetupIntegrationResult(
          id: KeybindingProviderInspector.ownershipID,
          status: dryRun ? .planned : .owned,
          target: selectedHome.appending(path: ".config/skhd/skhdrc").path,
          message: dryRun ? "Would adopt keybindings" : "Adopted keybindings",
          mutationAttempted: !dryRun,
          lifecycle: .restart
        )
      }
    )

    let execution = try runner.execute(
      profileName: "personal",
      homeDirectory: home,
      installDependencies: false,
      dryRun: false,
      keybindingProfileURL: portableProfile,
      keybindingProfileRequired: true,
      adoptKeybindings: true,
      json: true
    )
    let report = try decode(execution.output)

    #expect(execution.succeeded)
    #expect(report.mutationAttempted)
    #expect(
      calls.withLock { $0 } == [
        "\(portableProfile.path)|true|\(home.path)|true|true",
        "\(portableProfile.path)|true|\(home.path)|false|true",
      ])
  }

  private func runner(missing: Set<String>) -> SetupCommandRunner {
    SetupCommandRunner(
      resolveProfile: DependencyProfile.named,
      capabilityIsAvailable: { !missing.contains($0.id) },
      processRunner: unexpectedProcessRunner(),
      writePreMutationPlan: unexpectedPlanWriter(),
      setupIntegrations: externalIntegrations()
    )
  }

  private func unexpectedProcessRunner() -> ProcessRunner {
    ProcessRunner { _ in
      Issue.record("Homebrew must not run")
      return ProcessResult(terminationStatus: 1, output: "unexpected")
    }
  }

  private func unexpectedPlanWriter() -> @Sendable (String) throws -> Void {
    { _ in Issue.record("A pre-mutation plan must not be emitted") }
  }

  private func externalIntegrations()
    -> @Sendable (URL, Bool) throws -> [SetupIntegrationResult]
  {
    { homeDirectory, _ in
      [
        SetupIntegrationResult(
          id: SetupOwnershipManager.integrationID,
          status: .external,
          target: homeDirectory.appending(path: ".config/kitty/kitty.conf").path,
          message: "Fixture integration is externally owned",
          mutationAttempted: false
        )
      ]
    }
  }

  private func ids(
    in category: DependencyCapabilityCategory,
    profile: DependencyProfile
  ) -> [String] {
    profile.capabilities.filter { $0.category == category }.map(\.id)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "macarchy-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func makeExecutable(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path
    )
  }

  private func decode(_ output: String) throws -> SetupTestReport {
    try decoder().decode(SetupTestReport.self, from: Data(output.utf8))
  }

  private func decodePreMutationPlan(_ output: String) throws -> SetupTestPreMutationPlan {
    try decoder().decode(SetupTestPreMutationPlan.self, from: Data(output.utf8))
  }

  private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}

private enum SetupTestError: Error, CustomStringConvertible {
  case launchFailed

  var description: String {
    "launch failed"
  }
}

private enum SetupTestEvent: Equatable {
  case plan(String)
  case process(ProcessRequest)

  var planOutput: String? {
    guard case .plan(let output) = self else { return nil }
    return output
  }
}

private struct SetupTestReport: Decodable {
  let outcome: String
  let mutationAttempted: Bool
  let capabilities: [SetupTestCapability]?
  let summary: SetupTestSummary?
  let availableProfiles: [String]?
  let dependencyInstallation: SetupTestInstallation
}

private struct SetupTestCapability: Decodable {
  let id: String
  let status: String
}

private struct SetupTestSummary: Decodable {
  let missingRequiredCount: Int
  let missingOptionalCount: Int
}

private struct SetupTestInstallation: Decodable {
  let plan: SetupTestInstallPlan
  let commands: [SetupTestCommand]
  let failure: SetupTestFailure?
}

private struct SetupTestInstallPlan: Decodable {
  let formulae: [String]
  let casks: [String]
  let external: [SetupTestExternalRemediation]
}

private struct SetupTestExternalRemediation: Decodable {
  let capabilityId: String
  let instruction: String
}

private struct SetupTestCommand: Decodable {
  let executable: String
  let arguments: [String]
  let outcome: String
  let error: String?
}

private struct SetupTestFailure: Decodable {
  let kind: String
  let capabilityIds: [String]?
}

private struct SetupTestPreMutationPlan: Decodable {
  let operation: String
  let plan: SetupTestInstallPlan
}
