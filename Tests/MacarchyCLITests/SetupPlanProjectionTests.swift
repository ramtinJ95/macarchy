import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI

struct SetupPlanProjectionTests {
  @Test
  func disabledDesktopSkipsOnlyKeybindingFileOwnershipAndEmbedsTheComponentReport() throws {
    let fixture = try ProjectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n[desktop]\nprovider = \"disabled\"\n".write(
      to: fixture.context.profileURL, atomically: true, encoding: .utf8
    )
    let runner = fixture.runner()
    let preparation = try runner.prepare(context: fixture.context)
    guard case .ready(let model, let report) = preparation else {
      Issue.record("Expected a ready plan")
      return
    }
    #expect(model.profile.desktop.provider.rawValue == "disabled")
    #expect(report.providers["desktop"] == "disabled")
    #expect(report.files.map(\.id) == ["yabai_entry"])
    #expect(report.adoption.isEmpty)
    let components = try #require(report.components)
    let original = try fixture.runner().desktopPlanner(fixture.context, model.profile)
    #expect(try renderJSON(components.desktop) == renderJSON(original))
    #expect(
      try runner.inspectedReport(report, context: fixture.context).render(json: true)
        == runner.execute(context: fixture.context, json: true).output)

    let unplannedKeybindings = fixture.runner(desktop: desktopPlanStub(keybindings: nil))
    do {
      _ = try unplannedKeybindings.prepare(context: fixture.context)
      Issue.record("Expected disabled desktop to still require the keybinding plan")
    } catch let error as SetupComponentReportError {
      #expect(error.description == "Delegated plan is missing desktop.keybindings")
    }
  }
}

private struct ProjectionFixture {
  let root: URL
  let context: UnifiedSetupPlanContext

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-setup-projection-tests-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    context = UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes"),
      keybindingsResourcesRoot: root.appending(path: "Keybindings"),
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: root.appending(path: "Environment"),
      profileURL: root.appending(path: "profile.toml"),
      profileRequired: false,
      machineProfileURL: root.appending(path: "machine.toml"),
      machineProfileRequired: false,
      stateRoot: root.appending(path: "state"),
      homeDirectory: root.appending(path: "home")
    )
  }

  func runner(
    desktop: SetupComponentPlan<DesktopPlanReport> = desktopPlanStub(),
    environment: SetupComponentPlan<EnvironmentPlanReport> = environmentPlanStub()
  ) -> UnifiedSetupPlanCommandRunner {
    UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: { _ in true },
      desktopPlanner: { _, _ in desktop },
      environmentPlanner: { _, _, _ in environment },
      packageInventoryReader: { .init(packages: [], issues: []) },
      standardBrewfile: { _ in SetupBrewfile(packages: []) }
    )
  }
}
