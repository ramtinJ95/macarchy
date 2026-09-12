import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentStandardNativeFileTests {
  private let settings =
    "# personal\nsearch_mode = \"prefix\"\n[theme]\nname = \"macarchy-current\"\n"

  @Test(arguments: [false, true], [EnvironmentNativeSeed.Provider.atuin, .starship])
  func standardFileAndDotfileLinkSurviveApplyThemeAndTeardown(
    linked: Bool, provider: EnvironmentNativeSeed.Provider
  ) async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = provider == .atuin ? fixture.atuinConfigEntry : fixture.starshipEntry
    try FileManager.default.createDirectory(
      at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fixture.activateTheme()
    let source = linked ? fixture.root.appending(path: "personal.toml") : entry
    let seed = EnvironmentNativeSeed(
      provider: provider, destination: source, homeDirectory: fixture.home,
      stateRoot: fixture.state,
      resourcesRoot: repositoryRoot.appending(path: "Environment")
    )
    let preview = try seed.plan()
    if !linked { #expect(!FileManager.default.fileExists(atPath: source.path)) }
    _ = try seed.seed(approval: preview.approval)
    if !linked {
      #expect(throws: (any Error).self) { try seed.seed(approval: preview.approval) }
    }
    let personal = provider == .atuin ? settings : preview.contents + "\n# personal prompt\n"
    try personal.write(to: source, atomically: true, encoding: .utf8)
    if linked {
      try FileManager.default.createSymbolicLink(
        at: entry, withDestinationURL: source)
    }
    let text =
      try String(contentsOf: fixture.profile, encoding: .utf8)
      + "\n[\(provider.rawValue)]\nnative_configuration = \"\(entry.path)\"\n"
    try text.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let plan = try fixture.plan()
    #expect(plan.succeeded, "\(plan.output)")
    #expect(plan.output.contains("user_owned_native"))
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    let state = EnvironmentStateStore(stateRoot: fixture.state)
    let ownership = try #require(try state.readOwnership())
    #expect(!ownership.records.contains { $0.id == provider.entryID })
    #expect(ownership.standardNativeEntries == [provider.entryID])
    #expect(ownership.schemaVersion == 2)
    let edited = personal + "# native edit\n"
    try edited.write(to: source, atomically: true, encoding: .utf8)
    if provider == .atuin {
      let adapter = AtuinAdapter(
        root: fixture.state, configurationDirectoryURL: entry.deletingLastPathComponent(),
        executableURL: URL(filePath: "/fixture/atuin"), controlIsAvailable: { true },
        processRunner: ProcessRunner { _ in
          ProcessResult(terminationStatus: 0, output: AtuinAdapter.themeName)
        })
      #expect(adapter.inspection().status == .ready)
      #expect(try await adapter.reconciliation().run().status == .applied)
    } else {
      let paths = try ThemeRuntimeSelection.consumerPaths(
        stateRoot: fixture.state,
        consumerPaths: testConsumerPaths().managedEnvironmentPaths(
          stateRoot: fixture.state, homeDirectory: fixture.home, ownership: ownership))
      #expect(paths.starshipBehaviorURL == entry)
      let adapter = StarshipAdapter(
        root: fixture.state, configurationURL: entry, behaviorURL: paths.starshipBehaviorURL,
        executableURL: URL(filePath: "/fixture/starship"), controlIsAvailable: { true },
        processRunner: ProcessRunner { request in
          #expect(request.environmentOverrides["STARSHIP_CONFIG"] == source.path)
          return ProcessResult(terminationStatus: 0, output: "palette = \"macarchy_current\"")
        })
      #expect(adapter.inspection().status == .ready)
      #expect(try await adapter.reconciliation().run().status == .applied)
    }
    let repeated = try await fixture.apply(adopt: nil)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(try fixture.status().succeeded)
    let lookup = EnvironmentConfigurationSourceResolver(
      homeDirectory: fixture.home, stateRoot: fixture.state
    )
    .resolve(provider, profile: try PortableProfileLoader().decode(text, source: fixture.profile))
    #expect(lookup.status == .editable, "\(lookup.message)")
    #expect(lookup.source == entry.path)
    #expect(lookup.resolvedSource == source.path)
    let inherited = EnvironmentConfigurationSourceResolver(
      homeDirectory: fixture.home, stateRoot: fixture.state
    )
    .resolve(provider, profile: .defaults)
    #expect(inherited.status == .editable, "\(inherited.message)")
    #expect(inherited.authority == "native_ownership")
    #expect(try await fixture.teardown().succeeded)
    #expect(try String(contentsOf: source, encoding: .utf8) == edited)
    if linked {
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
          == source.path)
    }
  }

  @Test
  func standardPathDoesNotAuthorizeManagedStateOrAnotherProvider() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.atuinConfigEntry.deletingLastPathComponent(), withIntermediateDirectories: true)
    let managed = fixture.state.appending(path: "private.toml")
    for destination in [managed, fixture.zshEntry] {
      try settings.write(to: destination, atomically: true, encoding: .utf8)
      try FileManager.default.createSymbolicLink(
        at: fixture.atuinConfigEntry, withDestinationURL: destination)
      #expect(
        !EnvironmentNativeSource.targetIsAllowed(
          fixture.atuinConfigEntry.path, homeDirectory: fixture.home, stateRoot: fixture.state,
          userOwnedPublicEntry: .atuinConfiguration))
      try FileManager.default.removeItem(at: fixture.atuinConfigEntry)
    }
    #expect(
      !EnvironmentNativeSource.targetIsAllowed(
        fixture.zshEntry.path, homeDirectory: fixture.home, stateRoot: fixture.state,
        userOwnedPublicEntry: .atuinConfiguration))
  }
}
