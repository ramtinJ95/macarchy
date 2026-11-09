import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct VSCodePresetLifecycleTests {
  static let originals: [String?] = [
    nil, "{}\n", "{\"workbench.colorTheme\":\"Old\"}",
    "// settings\n{\n  // keep\n  \"workbench.colorTheme\" /* key */ : \"Old\", // trailing\n  \"editor.fontSize\": 16,\n}\n",
    "{ /* empty */ }", "{\"window.autoDetectColorScheme\":true,}",
    "{\"window.autoDetectColorScheme\":true,\"workbench.preferredDarkColorTheme\":\"Old Dark\",\"workbench.preferredLightColorTheme\":\"Old Light\",}",
    "{\"window.autoDetectColorScheme\":true,\"workbench.preferredLightColorTheme\":\"Old Light\",\"workbench.colorTheme\":\"Leave Alone\"}",
  ]

  @Test(arguments: originals)
  func settingsRestoreByteForByte(original: String?) throws {
    let home = URL(filePath: "/selected/home")
    let installation = VSCodeEditor.vscode.installations[0]
    let url = installation.settings(home: home)
    let data = original.map { Data($0.utf8) }
    let owner = try EnvironmentVSCodeOwnership.adopting(
      data, editor: .vscode, installation: installation, home: home, initialVersion: "1.0.1")
    #expect(owner.hasValidShape)
    let managed = try owner.managed(from: data, at: url)
    #expect(try owner.matchesManaged(managed, at: url))
    #expect(try owner.restored(in: managed, at: url) == data)
    if owner.autoDetect {
      let parsed = try EnvironmentVSCodeOwnership.document(managed, at: url)
      #expect(
        parsed.memberBytes("workbench.colorTheme")
          == (try data.flatMap {
            try EnvironmentVSCodeOwnership.document($0, at: url).memberBytes("workbench.colorTheme")
          }))
    }
  }

  @Test(arguments: VSCodeEditor.allCases)
  func appliedInventoryAndTeardownUseTheSelectedEditor(editor: VSCodeEditor) async throws {
    let f = try Fixture(editor: editor)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let plan = try f.plan()
    #expect(plan.succeeded, "\(plan.output)")
    let digest = try jsonObject(plan.output)["adoption_evidence_digest"] as? String
    let applied = try await f.apply(adopt: digest)
    #expect(applied.succeeded, "\(applied.output)")
    let owner = try #require(try EnvironmentStateStore(stateRoot: f.state).readOwnership())
    #expect(owner.enabledThemeAdapterIDs == [editor.rawValue])
    #expect(owner.vscodeEditors?.count == 1)
    #expect(try await f.apply().succeeded)
    f.cli.withLock { $0.version = owner.vscodeEditors?[editor.rawValue]?.initialVersion }
    let restored = try await f.teardown()
    #expect(restored.succeeded, "\(restored.output)")
    #expect(try Data(contentsOf: f.settings) == f.original)
    #expect(f.cli.withLock { $0.version } == nil)
    #expect(try EnvironmentStateStore(stateRoot: f.state).readOwnership() == nil)
  }

  @Test(arguments: ["theme", "automatic"])
  func driftPreservesSettingsAndExtension(change: String) async throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await f.apply(adopt: digest).succeeded)
    let text =
      change == "theme"
      ? "{\"workbench.colorTheme\":\"User\"}"
      : "{\"workbench.colorTheme\":\"Macarchy\",\"window.autoDetectColorScheme\":true}"
    try Data(text.utf8).write(to: f.settings)
    #expect(try !f.plan().succeeded)
    #expect(try await !f.teardown().succeeded)
    #expect(try Data(contentsOf: f.settings) == Data(text.utf8))
    #expect(f.cli.withLock { $0.uninstalls } == 0)
  }

  @Test func foreignExtensionRefusesAdoptionEvenWithTheExpectedName() throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.cli.withLock { $0.version = "1.0.123" }
    let plan = try f.plan()
    #expect(!plan.succeeded)
    #expect(plan.output.contains("without Macarchy ownership"))
    #expect(try Data(contentsOf: f.settings) == f.original)
  }

  @Test func uninstallFailureKeepsRecoverableOwnership() async throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await f.apply(adopt: digest).succeeded)
    let initial = try #require(
      try EnvironmentStateStore(stateRoot: f.state).readOwnership()?.vscodeEditors?["vscode"]?
        .initialVersion)
    f.cli.withLock {
      $0.version = initial
      $0.failUninstall = true
    }
    let failed = try await f.teardown()
    #expect(!failed.succeeded)
    #expect(failed.output.contains("uninstall"))
    #expect(try Data(contentsOf: f.settings) == f.original)
    #expect(EnvironmentStateStore(stateRoot: f.state).transactionExists)
    #expect(
      try EnvironmentStateStore(stateRoot: f.state).readOwnership()?.vscodeEditors?["vscode"] != nil
    )
    f.cli.withLock { $0.failUninstall = false }
    let recovered = try await f.teardown()
    #expect(recovered.succeeded, "\(recovered.output)")
    #expect(try Data(contentsOf: f.settings) == f.original)
    #expect(f.cli.withLock { $0.version } == nil)
  }

  @Test func unrelatedEditsSurviveAndAutomaticModeDoesNotReown() throws {
    let home = URL(filePath: "/home/test")
    let installation = VSCodeEditor.cursor.installations[0]
    let url = installation.settings(home: home)
    let owner = try EnvironmentVSCodeOwnership.adopting(
      nil, editor: .cursor, installation: installation, home: home, initialVersion: "1.0.1")
    let updated = Data("{\"workbench.colorTheme\": \"Macarchy\", \"editor.fontSize\": 18}".utf8)
    #expect(try owner.restored(in: updated, at: url) == Data("{\"editor.fontSize\": 18}".utf8))
    let flip = Data("{\"window.autoDetectColorScheme\":true}".utf8)
    #expect(throws: VSCodeAdapter.Failure.self) { try owner.managed(from: flip, at: url) }
  }

  private final class Fixture: Sendable {
    struct CLIState {
      var version: String?
      var failUninstall = false
      var uninstalls = 0
    }
    let cli = Mutex(CLIState())
    let root: URL
    let home: URL
    let state: URL
    let profile: URL
    let editor: VSCodeEditor
    let original = Data(
      "// preserve me\n{\"workbench.colorTheme\": \"Default Dark Modern\", \"editor.fontSize\":16,}\n"
        .utf8)
    var settings: URL { editor.installations[0].settings(home: home) }
    var paths: ThemeConsumerPaths {
      var value = testConsumerPaths()
      value.piConfigurationDirectoryURL = home.appending(path: ".pi/agent")
      value.starshipConfigurationURL = home.appending(path: ".config/starship.toml")
      return value
    }
    init(editor: VSCodeEditor = .vscode) throws {
      self.editor = editor
      root = FileManager.default.temporaryDirectory.appending(
        path: "vscode-preset-\(UUID().uuidString)")
      home = root.appending(path: "home")
      state = home.appending(path: ".config/macarchy")
      profile = root.appending(path: "profile.toml")
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
      try original.write(to: settings)
      try (presetTestProfile(presets: [:]) + "\(editor.rawValue) = true\n").write(
        to: profile, atomically: true, encoding: .utf8)
      try activateCatppuccinMocha(stateRoot: state)
    }
    var runner: ProcessRunner {
      ProcessRunner { [self] request in
        cli.withLock { value in
          switch request.arguments[0] {
          case "--list-extensions":
            return .init(
              terminationStatus: 0,
              output: value.version.map { "macarchy.macarchy-theme@\($0)" } ?? "")
          case "--uninstall-extension":
            value.uninstalls += 1
            if value.failUninstall {
              return .init(terminationStatus: 1, output: "injected uninstall failure")
            }
            value.version = nil
          default: Issue.record("Unexpected CLI request \(request)")
          }
          return .init(terminationStatus: 0, output: "")
        }
      }
    }
    func plan() throws -> CommandExecution {
      try EnvironmentPlanCommandRunner(
        prerequisites: .assumed,
        vscodeDiscover: { $0.installations[0] }, vscodeRunner: runner
      ).execute(
        resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: profile,
        profileRequired: true, stateRoot: state, homeDirectory: home, json: true)
    }
    func apply(adopt: String? = nil) async throws -> CommandExecution {
      try await EnvironmentApplyCommandRunner(
        prerequisites: .assumed,
        theme: stubThemeController(
          reconciled: ("restart_required", "new extension"), inspected: ("ready", "ready")),
        verifier: .assumed, vscodeDiscover: { $0.installations[0] }, vscodeRunner: runner
      ).execute(
        resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: profile,
        profileRequired: true, stateRoot: state, homeDirectory: home, consumerPaths: paths,
        adopt: adopt, json: true)
    }
    func teardown() async throws -> CommandExecution {
      try await EnvironmentTeardownCommandRunner(vscodeRunner: runner).execute(
        stateRoot: state,
        homeDirectory: home, consumerPaths: paths, dryRun: false, json: true)
    }
  }
}
