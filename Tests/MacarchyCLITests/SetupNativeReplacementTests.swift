import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SetupNativeReplacementTests {
  @Test(arguments: ["file", "directory", "link", "kitty-directory-link"])
  func replacementRestoresOriginalAndRetainsStarterEdits(kind: String) async throws {
    let fixture = try Fixture(kind: kind)
    defer { fixture.cleanup() }
    let store = fixture.store
    let proposal = try #require(try store.propose(fixture.provider))
    var seed = fixture.seed
    seed.replacement = proposal
    let plan = try seed.plan()
    #expect(plan.replacement == proposal)
    #expect(proposal.summary.contains(proposal.backup))
    try fixture.journal(proposal)
    _ = try seed.seed(approval: plan.approval)
    #expect(
      try SetupNativeReplacement.digest(URL(filePath: proposal.backup)) == proposal.originalDigest)
    #expect(try SetupNativeReplacement.kind(fixture.original) != S_IFLNK)
    #expect(try Data(contentsOf: fixture.targetFile) == fixture.targetBytes)
    let edited =
      fixture.provider == .neovim
      ? fixture.original.appending(path: "personal.lua") : fixture.seed.destination
    try "# personal edits\n".write(to: edited, atomically: true, encoding: .utf8)
    let receipt = try #require(try store.read().records.first)
    #expect(receipt.phase == .installed)
    // Provider rollback is empty here: this crosses the public recovery runner,
    // never internal manual restoration or deletion of the aggregate journal.
    let result = try await UnifiedSetupRecoveryCommandRunner.live.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(),
      acknowledgeUnverifiedSpicetify: false, json: true)
    #expect(result.succeeded, "\(result.output)")
    #expect(result.output.contains(proposal.backup))
    let restored = try #require(try store.read().records.first)
    #expect(restored.phase == .restored)
    #expect(try SetupNativeReplacement.digest(fixture.original) == proposal.originalDigest)
    #expect(
      try SetupNativeReplacement.digest(URL(filePath: proposal.backup)) == proposal.originalDigest)
    let retained = URL(filePath: try #require(restored.displacedStarter))
    let retainedEdits =
      fixture.provider == .neovim
      ? retained.appending(path: "personal.lua")
      : proposal.enclosesKittyFile ? retained.appending(path: "kitty.conf") : retained
    #expect(try String(contentsOf: retainedEdits, encoding: .utf8) == "# personal edits\n")
    #expect(try Data(contentsOf: fixture.targetFile) == fixture.targetBytes)
    if let target = proposal.linkTarget {
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: fixture.original.path) == target)
    }
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.context.stateRoot).read() == nil)
    #expect(try store.status().contains { $0.contains(proposal.backup) })
  }

  @Test(arguments: SetupNativeReplacement.Checkpoint.allCases)
  func everyJournalBoundaryRecoversWithoutLosingOriginal(
    _ boundary: SetupNativeReplacement.Checkpoint
  ) async throws {
    let fixture = try Fixture(kind: "file")
    defer { fixture.cleanup() }
    var store = fixture.store
    let proposal = try #require(try store.propose(.zsh))
    var seed = fixture.seed
    seed.replacement = proposal
    let plan = try seed.plan()
    try fixture.journal(proposal)
    let installing: [SetupNativeReplacement.Checkpoint] = [
      .journaled, .staged, .originalMoved, .installed,
    ]
    store.checkpoint = { checkpoint in if checkpoint == boundary { throw Interrupted() } }
    if installing.contains(boundary) {
      #expect(throws: Interrupted.self) { try store.install(seed, approval: plan.approval) }
    } else {
      _ = try fixture.store.install(seed, approval: plan.approval)
      #expect(throws: Interrupted.self) { try store.restore([proposal]) }
    }
    let result = try await UnifiedSetupRecoveryCommandRunner.live.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(),
      acknowledgeUnverifiedSpicetify: false, json: true)
    #expect(result.succeeded, "\(boundary): \(result.output)")
    #expect(try SetupNativeReplacement.digest(fixture.original) == proposal.originalDigest)
    if boundary != .journaled && boundary != .staged {
      #expect(
        try SetupNativeReplacement.digest(URL(filePath: proposal.backup)) == proposal.originalDigest
      )
    }
  }

  @Test(arguments: ["backup", "stale-original", "approval", "loop", "missing-target"])
  func refusesUnexpectedEntriesWithoutMovingTheOriginal(change: String) throws {
    let fixture = try Fixture(kind: "file")
    defer { fixture.cleanup() }
    if change == "loop" || change == "missing-target" {
      try FileManager.default.removeItem(at: fixture.original)
      try FileManager.default.createSymbolicLink(
        atPath: fixture.original.path,
        withDestinationPath: change == "loop" ? ".zshrc" : "missing-target")
      #expect(throws: (any Error).self) { try fixture.store.propose(.zsh) }
      return
    }
    let proposal = try #require(try fixture.store.propose(.zsh))
    var seed = fixture.seed
    seed.replacement = proposal
    let plan = try seed.plan()
    if change == "backup" {
      try "collision".write(toFile: proposal.backup, atomically: true, encoding: .utf8)
    } else if change == "stale-original" {
      try "new personal config".write(to: fixture.original, atomically: true, encoding: .utf8)
    }
    #expect(throws: (any Error).self) {
      try seed.seed(approval: change == "approval" ? "stale" : plan.approval)
    }
    #expect(try fixture.store.read().records.isEmpty)
    #expect(
      try String(contentsOf: fixture.original, encoding: .utf8)
        == (change == "stale-original" ? "new personal config" : "export ORIGINAL=1\n"))
    if change == "backup" {
      #expect(try String(contentsOfFile: proposal.backup, encoding: .utf8) == "collision")
    }
  }

  @Test func replacementReviewDefaultsOnAndCanKeepAnItemWithoutMutation() throws {
    let fixture = try Fixture(kind: "file")
    defer { fixture.cleanup() }
    let proposal = try #require(try fixture.store.propose(.zsh))
    let transcript = Mutex("")
    let defaults = try GuidedSetupTerminal.replacementChoices(
      [proposal],
      io: .init(
        read: { "enter" }, write: { text in transcript.withLock { $0 += text } }))
    #expect(defaults == ["zsh"])
    let keys = Mutex([" ", "enter"])
    let declined = try GuidedSetupTerminal.replacementChoices(
      [proposal],
      io: .init(
        read: { keys.withLock { $0.removeFirst() } }, write: { _ in }))
    #expect(declined.isEmpty)
    #expect(transcript.withLock { $0 }.contains(proposal.backup))
    #expect(try fixture.store.read().records.isEmpty)
    #expect(try SetupNativeReplacement.digest(fixture.original) == proposal.originalDigest)
    #expect(throws: GuidedSetupError.self) {
      try GuidedSetupTerminal.replacementChoices(
        [proposal], io: .init(read: { "cancel" }, write: { _ in }))
    }
  }

  @Test func restoredBackupsRemainVisibleWhenInspectionIsBlocked() async throws {
    let fixture = try Fixture(kind: "link")
    defer { fixture.cleanup() }
    let proposal = try #require(try fixture.store.propose(.zsh))
    var seed = fixture.seed
    seed.replacement = proposal
    try fixture.journal(proposal)
    _ = try seed.seed(approval: seed.plan().approval)
    _ = try await UnifiedSetupRecoveryCommandRunner.live.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(),
      acknowledgeUnverifiedSpicetify: false, json: true)
    let result = try UnifiedSetupInspectionCommandRunner.live.execute(
      operation: .status, context: fixture.context, consumerPaths: testConsumerPaths(), json: true)
    #expect(result.output.contains("configuration_backups"))
    #expect(result.output.contains(proposal.backup))
  }

  @Test(arguments: [false, true])
  func missingEntryReceiptIsSafeOnlyBeforeOriginalMutation(moved: Bool) async throws {
    let fixture = try Fixture(kind: "file")
    defer { fixture.cleanup() }
    let proposal = try #require(try fixture.store.propose(.zsh))
    try fixture.journal(proposal)
    if moved {
      var seed = fixture.seed
      seed.replacement = proposal
      _ = try seed.seed(approval: seed.plan().approval)
      try FileManager.default.removeItem(at: fixture.store.url)
    }
    let result = try await UnifiedSetupRecoveryCommandRunner.live.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(),
      acknowledgeUnverifiedSpicetify: false, json: true)
    #expect(result.succeeded == !moved, "\(result.output)")
    if moved {
      #expect(
        try SetupNativeReplacement.digest(URL(filePath: proposal.backup)) == proposal.originalDigest
      )
      #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.base.state).read() != nil)
    } else {
      #expect(try SetupNativeReplacement.digest(fixture.original) == proposal.originalDigest)
    }
  }

  @Test func interruptedDirectoryCopyIsRetainedAndRecoveryRetriesWithoutClobberingIt() async throws
  {
    let fixture = try Fixture(kind: "directory")
    defer { fixture.cleanup() }
    let proposal = try #require(try fixture.store.propose(.neovim))
    var seed = fixture.seed
    seed.replacement = proposal
    try fixture.journal(proposal)
    _ = try seed.seed(approval: seed.plan().approval)
    var interrupted = fixture.store
    interrupted.checkpoint = { if $0 == .starterRetained { throw Interrupted() } }
    #expect(throws: Interrupted.self) { try interrupted.restore([proposal]) }
    let record = try #require(try fixture.store.read().records.first)
    let staging = URL(filePath: try #require(record.restoreStaging))
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    try "partial-copy".write(
      to: staging.appending(path: "partial"), atomically: true, encoding: .utf8)
    let result = try await UnifiedSetupRecoveryCommandRunner.live.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(),
      acknowledgeUnverifiedSpicetify: false, json: true)
    #expect(result.succeeded, "\(result.output)")
    let restored = try #require(try fixture.store.read().records.first)
    let partial = try #require(restored.partialRestorations?.first)
    #expect(try String(contentsOfFile: partial + "/partial", encoding: .utf8) == "partial-copy")
    #expect(result.output.contains(partial))
    #expect(try SetupNativeReplacement.digest(fixture.original) == proposal.originalDigest)
  }

  @Test(arguments: [false, true])
  func replacementPreviewNeverCreatesAnOperationalLock(active: Bool) throws {
    let fixture = try Fixture(kind: "file")
    defer { fixture.cleanup() }
    let proposal = try #require(try fixture.store.propose(.zsh))
    if active {
      var seed = fixture.seed
      seed.replacement = proposal
      try fixture.journal(proposal)
      _ = try seed.seed(approval: seed.plan().approval)
    }
    let run = fixture.base.state.appending(path: "run")
    if FileManager.default.fileExists(atPath: run.path) {
      try FileManager.default.removeItem(at: run)
    }
    _ = try fixture.store.restore(active ? [proposal] : [], dryRun: true)
    #expect(!FileManager.default.fileExists(atPath: run.path))
    if active {
      #expect(try fixture.store.read().records.first?.phase == .installed)
      #expect(
        try SetupNativeReplacement.digest(URL(filePath: proposal.backup)) == proposal.originalDigest
      )
    }
  }

  @Test func kittyDirectoryStagingCollisionIsNeverAdoptedAndRecoveryPreservesIt() async throws {
    let fixture = try Fixture(kind: "kitty-directory-link")
    defer { fixture.cleanup() }
    let proposal = try #require(try fixture.store.propose(.kitty))
    var seed = fixture.seed
    seed.replacement = proposal
    let plan = try seed.plan()
    try fixture.journal(proposal)
    let staging = URL(filePath: proposal.staging)
    var store = fixture.store
    store.checkpoint = { checkpoint in
      if checkpoint == .journaled {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try "foreign files are not starter ownership".write(
          to: staging.appending(path: "foreign"), atomically: true, encoding: .utf8)
      }
    }
    #expect(throws: (any Error).self) { try store.install(seed, approval: plan.approval) }
    #expect(try SetupNativeReplacement.kind(fixture.original) == S_IFLNK)
    #expect(try SetupNativeReplacement.kind(URL(filePath: proposal.backup)) == nil)
    let recovery = try await UnifiedSetupRecoveryCommandRunner.live.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(),
      acknowledgeUnverifiedSpicetify: false, json: true)
    #expect(recovery.succeeded, "\(recovery.output)")
    #expect(
      try String(contentsOf: staging.appending(path: "foreign"), encoding: .utf8)
        == "foreign files are not starter ownership")
    #expect(try SetupNativeReplacement.digest(fixture.original) == proposal.originalDigest)
    #expect(recovery.output.contains(proposal.staging))
  }

  private struct Interrupted: Error {}

  private struct Fixture {
    let base: EnvironmentLifecycleFixture
    let provider: EnvironmentNativeSeed.Provider
    let original: URL
    let targetFile: URL
    let targetBytes = Data("export DOTFILE=untouched\n".utf8)
    var store: SetupNativeReplacement { .init(homeDirectory: base.home, stateRoot: base.state) }
    var seed: EnvironmentNativeSeed {
      .init(
        provider: provider, destination: provider.standardURL(homeDirectory: base.home),
        homeDirectory: base.home, stateRoot: base.state,
        resourcesRoot: repositoryRoot.appending(path: "Environment"), createParentDirectory: true)
    }
    var context: UnifiedSetupPlanContext {
      UnifiedSetupPlanContext(
        themesRoot: repositoryRoot.appending(path: "Themes"),
        keybindingsResourcesRoot: repositoryRoot.appending(path: "Keybindings"),
        desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
        environmentResourcesRoot: repositoryRoot.appending(path: "Environment"),
        profileURL: base.profile, profileRequired: true,
        machineProfileURL: base.root.appending(path: "missing-machine.toml"),
        machineProfileRequired: false, stateRoot: base.state, homeDirectory: base.home)
    }
    init(kind: String) throws {
      base = try EnvironmentLifecycleFixture(externalEntries: false)
      provider = kind == "directory" ? .neovim : kind == "kitty-directory-link" ? .kitty : .zsh
      original =
        kind == "kitty-directory-link"
        ? base.home.appending(path: ".config/kitty")
        : provider.standardURL(homeDirectory: base.home)
      let target = base.home.appending(path: "dotfiles")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      targetFile = target.appending(path: kind == "kitty-directory-link" ? "kitty.conf" : "zshrc")
      try targetBytes.write(to: targetFile)
      switch kind {
      case "directory":
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try "return { personal = true }\n".write(
          to: original.appending(path: "init.lua"), atomically: true, encoding: .utf8)
      case "link":
        try FileManager.default.createSymbolicLink(
          atPath: original.path, withDestinationPath: "dotfiles/zshrc")
      case "kitty-directory-link":
        try FileManager.default.createSymbolicLink(
          atPath: original.path, withDestinationPath: "../dotfiles")
      default:
        try "export ORIGINAL=1\n".write(to: original, atomically: true, encoding: .utf8)
      }
    }
    func journal(_ proposal: SetupNativeReplacement.Proposal) throws {
      try UnifiedSetupTransactionStore(stateRoot: base.state).write(
        .init(
          operation: .apply, stages: [], desiredAppearance: .dark,
          contextDigest: unifiedSetupContextDigest(
            context: context, consumerPaths: testConsumerPaths()),
          nativeReplacements: [proposal]))
    }
    func cleanup() { try? FileManager.default.removeItem(at: base.root) }
  }
}
