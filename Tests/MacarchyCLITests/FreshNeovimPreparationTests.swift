import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct FreshNeovimPreparationTests {
  @Test
  func firstConnectionPreparesACopyAndOrdinaryReapplyNeverRestoresPlugins() async throws {
    let fixture = try seededFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = fixture.home.appending(path: ".config/nvim")
    let lock = native.appending(path: "lazy-lock.json")
    let original = try Data(contentsOf: lock)
    let calls = Mutex(0)
    let temporary = Mutex<URL?>(nil)
    let preparer = EnvironmentNeovimPreparer.live(
      processRunner: ProcessRunner { request in
        calls.withLock { $0 += 1 }
        #expect(request.timeout == 180)
        #expect(request.arguments.contains("+Lazy! restore"))
        #expect(request.arguments.contains { $0.contains("verify_plugins") })
        #expect(request.environmentOverrides["HOME"] == fixture.home.path)
        let root = URL(filePath: try #require(request.environmentOverrides["XDG_CONFIG_HOME"]))
        temporary.withLock { $0 = root }
        let copied = root.appending(path: "nvim/lazy-lock.json")
        #expect(try Data(contentsOf: copied) == original)
        for path in EnvironmentNeovimMigration.themePaths {
          let target = root.appending(path: "nvim/\(path)").resolvingSymlinksInPath()
          let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
          #expect((try #require(attributes[.posixPermissions] as? NSNumber)).intValue & 0o222 == 0)
        }
        try Data("{}\n".utf8).write(to: copied)
        return ProcessResult(terminationStatus: 0, output: "plugins verified")
      })
    let plan = try fixture.plan()
    #expect(plan.output.contains("prepare_fresh_neovim_plugins"))
    #expect(plan.output.contains("180-second"))
    let applied = try await fixture.apply(
      adopt: try adoption(plan.output), neovim: preparer)
    #expect(applied.succeeded, "\(applied.output)")
    #expect(calls.withLock { $0 } == 1)
    #expect(try Data(contentsOf: lock) == original)
    #expect(!FileManager.default.fileExists(atPath: try #require(temporary.withLock { $0 }).path))
    #expect(try !fixture.plan().output.contains("prepare_fresh_neovim_plugins"))
    let repeated = try await fixture.apply(adopt: nil, neovim: preparer)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(calls.withLock { $0 } == 1)
  }

  @Test(arguments: ["behavior", "extra", "lock", "symlink", "external"])
  func personalNativeConfigurationNeverGrantsBootstrapAuthority(change: String) async throws {
    let fixture = try seededFixture(external: change == "external")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = fixture.home.appending(path: ".config/nvim")
    switch change {
    case "behavior":
      let file = native.appending(path: "init.lua")
      try (String(contentsOf: file, encoding: .utf8) + "\n-- personal\n")
        .write(to: file, atomically: true, encoding: .utf8)
    case "extra": try Data("-- personal\n".utf8).write(to: native.appending(path: "extra.lua"))
    case "lock": try Data("{}\n".utf8).write(to: native.appending(path: "lazy-lock.json"))
    case "symlink":
      try FileManager.default.createSymbolicLink(
        at: native.appending(path: "personal.lua"), withDestinationURL: fixture.profile)
    default: break
    }
    let plan = try fixture.plan()
    #expect(plan.succeeded, "\(plan.output)")
    #expect(!plan.output.contains("prepare_fresh_neovim_plugins"))
    let applied = try await fixture.apply(
      adopt: try adoption(plan.output),
      neovim: EnvironmentNeovimPreparer { _, _ in
        Issue.record("personal native configuration must not prepare plugins")
        return nil
      })
    #expect(applied.succeeded, "\(applied.output)")
  }

  @Test
  func preparationFailureRollsBackOwnershipButRetainsTheStarterAndCanBeRetried() async throws {
    let fixture = try seededFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lock = fixture.home.appending(path: ".config/nvim/lazy-lock.json")
    let original = try Data(contentsOf: lock)
    let plan = try fixture.plan()
    let failed = try await fixture.apply(
      adopt: try adoption(plan.output),
      neovim: EnvironmentNeovimPreparer.live(
        processRunner: ProcessRunner { request in
          throw ProcessRunnerError.timedOut(request.executableURL, 180)
        }))
    #expect(!failed.succeeded)
    #expect(failed.output.contains("180.0-second timeout"))
    #expect(failed.output.contains("plugin/cache changes may remain"))
    #expect(try Data(contentsOf: lock) == original)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(try fixture.plan().output.contains("prepare_fresh_neovim_plugins"))
  }

  @Test
  func proposedAbsentStarterDisclosesPreparationBeforeCreatingFiles() throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let destination = fixture.home.appending(path: ".config/nvim")
    let seed = seed(fixture, destination: destination)
    let proposed = try seed.plan()
    try selectNeovim(fixture, destination: destination)
    let profile = try PortableProfileLoader().load(at: fixture.profile, required: true)
    #expect(
      try EnvironmentNeovimPreparer.requiresFreshNativePreparation(
        profile: profile.environment, ownership: nil, homeDirectory: fixture.home,
        stateRoot: fixture.state, resourcesRoot: repositoryRoot.appending(path: "Environment"),
        proposedStarters: [proposed]))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  private func seededFixture(external: Bool = false) throws -> EnvironmentLifecycleFixture {
    let fixture = try EnvironmentLifecycleFixture()
    let destination =
      external
      ? fixture.root.appending(path: "personal-neovim")
      : fixture.home.appending(path: ".config/nvim")
    let seed = seed(fixture, destination: destination)
    _ = try seed.seed(approval: seed.plan().approval)
    try selectNeovim(fixture, destination: destination)
    return fixture
  }

  private func seed(_ fixture: EnvironmentLifecycleFixture, destination: URL)
    -> EnvironmentNativeSeed
  {
    EnvironmentNativeSeed(
      provider: .neovim, destination: destination, homeDirectory: fixture.home,
      stateRoot: fixture.state, resourcesRoot: repositoryRoot.appending(path: "Environment"))
  }

  private func selectNeovim(_ fixture: EnvironmentLifecycleFixture, destination: URL) throws {
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
      .replacingOccurrences(
        of: "[editor]\nprovider = \"disabled\"", with: "[editor]\nprovider = \"neovim\"")
    try (original + "\n[neovim]\nnative_configuration = \"\(destination.path)\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
  }

  private func adoption(_ output: String) throws -> String? {
    try jsonObject(output)["adoption_evidence_digest"] as? String
  }
}
