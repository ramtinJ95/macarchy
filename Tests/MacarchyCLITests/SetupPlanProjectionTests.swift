import Foundation
import Testing

@testable import MacarchyCLI

struct SetupPlanProjectionTests {
  @Test(arguments: [
    MalformedReport(
      desktop: ["actions": .null, "keybindings": .null],
      error: "Delegated plan field desktop.actions is not an array"
    ),
    MalformedReport(
      desktop: ["actions": .array([.object([:]), .null])],
      environment: ["actions": .null],
      error: "Delegated plan is missing desktop.actions[0].id"
    ),
    MalformedReport(
      desktop: ["actions": .array([.object(["id": .string("first")]), .null])],
      error: "Delegated plan is missing desktop.actions[0].message"
    ),
    MalformedReport(
      desktop: ["keybindings": .null],
      environment: ["actions": .array([.null])],
      error: "Delegated plan field environment.actions[0] is not an object"
    ),
    MalformedReport(
      desktop: ["keybindings": .null, "provider": .null],
      error: "Delegated plan is missing desktop.keybindings.provider_status"
    ),
    MalformedReport(
      desktop: ["keybindings": .object(["provider_status": .string("managed")])],
      error: "Delegated plan is missing desktop.keybindings.ownership"
    ),
    MalformedReport(
      desktop: ["provider": .null],
      error: "Delegated plan field desktop.provider is not an object"
    ),
    MalformedReport(
      desktop: ["provider": .object([:])],
      error: "Delegated plan is missing desktop.provider.entry_point"
    ),
    MalformedReport(
      desktop: ["provider": .object(["entry_point": .string("/yabai")])],
      error: "Delegated plan is missing desktop.provider.status"
    ),
    MalformedReport(
      desktop: ["sketchybar": .null],
      error: "Delegated plan is missing desktop.sketchybar.provider"
    ),
    MalformedReport(
      desktop: ["sketchybar": .object(["provider": .null])],
      error: "Delegated plan field desktop.sketchybar.provider is not an object"
    ),
    MalformedReport(
      desktop: ["sketchybar": .object(["provider": .object([:])])],
      error: "Delegated plan is missing desktop.sketchybar.provider.entry_point"
    ),
    MalformedReport(
      environment: ["entries": .null, "adoption_evidence_digest": .bool(false)],
      error: "Delegated plan field environment.entries is not an array"
    ),
    MalformedReport(
      environment: ["entries": .array([.object([:]), .null])],
      error: "Delegated plan is missing environment.entries[0].id"
    ),
    MalformedReport(
      environment: ["entries": .array([.object(["id": .string("kitty")]), .null])],
      error: "Delegated plan is missing environment.entries[0].path"
    ),
    MalformedReport(
      environment: ["entries": .array([.null])],
      error: "Delegated plan field environment.entries[0] is not an object"
    ),
    MalformedReport(
      desktop: [
        "keybindings": .object([
          "provider_status": .string("managed"), "ownership": .string("managed"),
          "adoption_evidence_digest": .bool(false),
        ])
      ],
      environment: ["adoption_evidence_digest": .bool(false)],
      error: "Delegated plan field desktop.keybindings.adoption_evidence_digest is not a string"
    ),
    MalformedReport(
      desktop: [
        "provider": .object([
          "entry_point": .string("/yabai"), "status": .string("managed"),
          "ownership": .string("managed"), "adoption_evidence_digest": .bool(false),
        ])
      ],
      error: "Delegated plan field desktop.provider.adoption_evidence_digest is not a string"
    ),
    MalformedReport(
      desktop: [
        "sketchybar": .object([
          "provider": .object([
            "entry_point": .string("/bar"), "status": .string("managed"),
            "ownership": .string("managed"), "adoption_evidence_digest": .bool(false),
          ])
        ])
      ],
      error:
        "Delegated plan field desktop.sketchybar.provider.adoption_evidence_digest is not a string"
    ),
    MalformedReport(
      environment: ["adoption_evidence_digest": .bool(false)],
      error: "Delegated plan field environment.adoption_evidence_digest is not a string"
    ),
  ])
  func malformedReportsPreserveTheFirstStrictError(_ malformed: MalformedReport) throws {
    let fixture = try ProjectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    // Even blocked components have their actions/files/evidence inspected before suppression.
    let runner = fixture.runner(
      desktop: malformed.desktop, environment: malformed.environment, succeeded: false
    )
    do {
      _ = try runner.prepare(context: fixture.context)
      Issue.record("Expected malformed delegated report to throw")
    } catch let error as SetupComponentReportError {
      #expect(error.description == malformed.error)
    }
  }

  @Test
  func disabledDesktopSkipsOnlyKeybindingFileOwnershipAndPreservesNestedJSON() throws {
    let fixture = try ProjectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "schema_version = 1\n[desktop]\nprovider = \"disabled\"\n".write(
      to: fixture.context.profileURL, atomically: true, encoding: .utf8
    )
    let desktop: [String: JSONValue] = [
      "keybindings": .object([
        "provider_status": .string("managed"), "ownership": .bool(false),
        "adoption_evidence_digest": .null,
      ]),
      "unused": .object(["integer": .unsignedInteger(UInt64.max), "array": .array([.null])]),
    ]
    let runner = fixture.runner(desktop: desktop)
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
    let original = try fixture.runner(desktop: desktop).desktopPlanner(
      fixture.context, model.profile
    )
    #expect(try renderJSON(components.desktop) == renderJSON(original))
    #expect(
      try components.desktop.report["unused"].map(renderJSON) == desktop["unused"].map(renderJSON))
    #expect(
      try runner.inspectedReport(report).render(json: true)
        == runner.execute(context: fixture.context, json: true).output)

    let invalidStatus = fixture.runner(desktop: ["keybindings": .object([:])])
    do {
      _ = try invalidStatus.prepare(context: fixture.context)
      Issue.record("Expected disabled desktop to still validate keybinding adoption status")
    } catch let error as SetupComponentReportError {
      #expect(error.description == "Delegated plan is missing desktop.keybindings.provider_status")
    }
  }

  struct MalformedReport: Sendable {
    var desktop: [String: JSONValue] = [:]
    var environment: [String: JSONValue] = [:]
    let error: String
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
      desktopResourcesRoot: root.appending(path: "Desktop"),
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
    desktop: [String: JSONValue] = [:],
    environment: [String: JSONValue] = [:],
    succeeded: Bool = true
  ) -> UnifiedSetupPlanCommandRunner {
    UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: { _ in true },
      desktopPlanner: { _, _ in
        let report: [String: JSONValue] = [
          "outcome": .string(succeeded ? "ready" : "blocked"),
          "keybindings": .object([
            "provider_status": .string("managed"), "ownership": .string("managed"),
          ]),
          "provider": .object([
            "entry_point": .string("/yabai"), "status": .string("managed"),
            "ownership": .string("managed"),
          ]),
          "actions": .array([]),
        ]
        return try SetupComponentExecution(
          (
            output: renderJSON(JSONValue.object(report.merging(desktop) { _, new in new })),
            succeeded: succeeded
          ))
      },
      environmentPlanner: { _, _ in
        let report: [String: JSONValue] = [
          "outcome": .string("ready"), "entries": .array([]), "actions": .array([]),
        ]
        return try SetupComponentExecution(
          (
            output: renderJSON(JSONValue.object(report.merging(environment) { _, new in new })),
            succeeded: true
          ))
      }
    )
  }
}
