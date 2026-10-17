import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct SetupOwnershipTests {
  @Test
  func batAndEzaOwnedSeamsRoundTripTogether() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership(
      fixture.legacyBatEza(bat: "--italic-text=always\n", shell: "export EDITOR=nvim\n"))
    let cacheSentinel = fixture.home.appending(path: ".cache/bat/preserve")
    try FileManager.default.createDirectory(
      at: cacheSentinel.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("cache".utf8).write(to: cacheSentinel)

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )

    var teardownStatuses = unownedTeardownStatuses
    for id in ["bat.selector", "bat.theme-link", "eza.environment", "eza.theme-link"] {
      teardownStatuses[id] = .removed
    }
    expectStatuses(teardown, teardownStatuses)
    #expect(try fixture.batConfigurationText() == "--italic-text=always\n")
    #expect(try fixture.shellConfigurationText() == "export EDITOR=nvim\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.batThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.ezaThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.batSelectorBackup.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.ezaEnvironmentBackup.path))
    #expect(try String(contentsOf: cacheSentinel, encoding: .utf8) == "cache")
  }

  @Test
  func teardownReportsAnEarlierRemovalWhenALaterMutationRaces() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership(
      fixture.legacyBatEza(bat: "--italic-text=always\n", shell: "export EDITOR=nvim\n"))
    let checkpoints = Mutex(0)
    let shellConfiguration = fixture.shellConfiguration
    let manager = SetupOwnershipManager { checkpoint in
      guard checkpoint == .teardownReady else { return }
      let shouldEdit = checkpoints.withLock { count in
        count += 1
        return count == 2
      }
      if shouldEdit {
        try Data("concurrent shell edit\n".utf8).write(
          to: shellConfiguration,
          options: .atomic
        )
      }
    }

    let execution = try TeardownCommandRunner(ownershipManager: manager).execute(
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    let report = try decode(TeardownReport.self, execution.output)

    #expect(!execution.succeeded)
    var reportStatuses = unownedTeardownStatuses.mapValues { _ in "none" }
    for id in ["kitty.include", "bat.selector", "bat.theme-link"] {
      reportStatuses.removeValue(forKey: id)
    }
    reportStatuses["eza.environment"] = "failed"
    reportStatuses["eza.theme-link"] = "removed"
    expectStatuses(report.integrations, reportStatuses)
    #expect(
      Set(report.integrations.filter(\.mutationAttempted).map(\.id))
        == Set(["eza.environment", "eza.theme-link"])
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.ezaThemeLink.path))
    #expect(try fixture.shellConfigurationText() == "concurrent shell edit\n")
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func teardownRestoresOnlyTheRecordedKittyChange() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([fixture.legacyKittyInclude()])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fixture.kittyConfiguration.path
    )
    try fixture.setExtendedAttribute(name: "io.github.macarchy.test", value: "preserve")
    let sentinel = fixture.stateRoot.appending(path: "generations/keep/manifest.json")
    try FileManager.default.createDirectory(
      at: sentinel.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("preserve".utf8).write(to: sentinel)

    let teardownDryRun = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: true, json: true)
    let teardownPreview = try decode(TeardownReport.self, teardownDryRun.output)
    var teardownPreviewStatuses = unownedTeardownStatuses.mapValues { _ in "none" }
    teardownPreviewStatuses["kitty.include"] = "planned"
    expectStatuses(teardownPreview.integrations, teardownPreviewStatuses)
    #expect(try fixture.configuration().contains(fixture.includeDirective))

    let teardown = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: false, json: true)
    let teardownReport = try decode(TeardownReport.self, teardown.output)
    let teardownJSON = try #require(
      JSONSerialization.jsonObject(with: Data(teardown.output.utf8)) as? [String: Any]
    )

    #expect(teardown.succeeded)
    #expect(teardownJSON["integration"] == nil)
    var teardownReportStatuses = unownedTeardownStatuses.mapValues { _ in "none" }
    teardownReportStatuses["kitty.include"] = "removed"
    expectStatuses(teardownReport.integrations, teardownReportStatuses)
    #expect(try fixture.configuration() == "font_size 13\n")
    #expect(try fixture.permissions() == 0o600)
    #expect(try fixture.extendedAttribute(name: "io.github.macarchy.test") == "preserve")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")

    let repeatedTeardown = try #require(
      SetupOwnershipManager().teardown(
        homeDirectory: fixture.home,
        dryRun: false
      ).first)
    #expect(repeatedTeardown.status == .none)
  }
}
