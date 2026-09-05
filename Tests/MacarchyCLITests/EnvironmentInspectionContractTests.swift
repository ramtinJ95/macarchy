import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

struct EnvironmentInspectionContractTests {
  @Test(arguments: [false, true])
  func presentationKeepsSeparatePlanMapsAndFlatStatusMap(selected: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-presentation-contract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profileURL = root.appending(path: "profile.toml")
    try """
      schema_version = 1
      [tools]
    bat = \(selected)
    btop = \(!selected)
    eza = \(!selected)
    yazi = \(selected)
    [presets]
    codex = \(selected)
    herdr = \(!selected)
    pi = \(selected)
    slack = \(!selected)
    spicetify = \(selected)
    tuicr = \(!selected)
    """.write(to: profileURL, atomically: true, encoding: .utf8)
    let on = selected ? "enabled" : "disabled"
    let off = selected ? "disabled" : "enabled"
    let tools = ["bat": on, "btop": off, "eza": off, "yazi": on]
    let presets = [
      "codex": on, "herdr": off, "pi": on, "slack": off, "spicetify": on, "tuicr": off,
    ]
    let plan = try EnvironmentPlanCommandRunner().execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profileURL, profileRequired: true,
      stateRoot: root.appending(path: "state"), json: true)
    let report = try jsonObject(plan.output)
    #expect(plan.succeeded)
    #expect(report["daily_tools"] as? [String: String] == tools)
    #expect(report["presets"] as? [String: String] == presets)
    #expect(report["providers"] == nil)

    let profile = try PortableProfileLoader().load(at: profileURL, required: true)
    let status = EnvironmentStatusCommandRunner.providers(profile.environment)
    #expect(
      status == [
        "terminal": "kitty", "shell": "zsh", "prompt": "starship", "history": "atuin",
        "editor": "neovim", "bat": on, "btop": off, "eza": off, "yazi": on,
        "codex": on, "herdr": off, "pi": on, "slack": off, "spicetify": on, "tuicr": off,
      ])
  }

  @Test(arguments: [
    ("Codex", EnvironmentLegacyIntegration.codexIDs),
    ("Pi", EnvironmentLegacyIntegration.piIDs),
    ("Spicetify", EnvironmentLegacyIntegration.spicetifyIDs),
    ("tuicr", EnvironmentLegacyIntegration.tuicrIDs),
  ])
  func legacyValidatorPreservesAbsentCompleteAndEveryPartialTuple(
    name: String, requiredIDs: Set<String>
  ) throws {
    let ordered = requiredIDs.sorted()
    for mask in 0..<(1 << ordered.count) {
      let present = Set(
        ordered.enumerated().compactMap { index, id in
          mask & (1 << index) == 0 ? nil : id
        })
      let setupIDs = present.union(["unrelated.integration"])
      if present.isEmpty || present == requiredIDs {
        #expect(
          try EnvironmentLegacyIntegration.hasCompleteLegacyIntegration(
            named: name, requiredIDs: requiredIDs, setupIDs: setupIDs
          ) == (present == requiredIDs))
      } else {
        do {
          _ = try EnvironmentLegacyIntegration.hasCompleteLegacyIntegration(
            named: name, requiredIDs: requiredIDs, setupIDs: setupIDs)
          Issue.record("Partial legacy ownership must block")
        } catch {
          #expect(
            String(describing: error)
              == "environment lifecycle is blocked: legacy setup-owned \(name) integration is incomplete: \(present.sorted().joined(separator: ", "))"
          )
        }
      }
    }
  }

  @Test(arguments: [
    ["Codex", "Pi", "Spicetify", "tuicr"],
    ["Pi", "Spicetify"],
    ["Spicetify", "tuicr"],
    ["Codex"],
  ])
  func incompleteLegacyTuplesPreserveCallerFirstError(partial: [String]) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-inspection-contract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home")
    let state = home.appending(path: ".config/macarchy")
    for directory in [
      ".codex/themes", ".pi/agent/themes", ".config/spicetify/Themes/text",
      ".config/tuicr/themes", ".config/macarchy",
    ] {
      try FileManager.default.createDirectory(
        at: home.appending(path: directory), withIntermediateDirectories: true)
    }
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: home)
    var records = [SetupOwnershipRecord]()
    if partial.contains("Codex") {
      _ = try manager.setupCodexThemeLink(context: context, dryRun: false, records: &records)
    }
    if partial.contains("Pi") {
      _ = try manager.setupPiThemeLink(context: context, dryRun: false, records: &records)
    }
    if partial.contains("Spicetify") {
      _ = try manager.setupSpicetifyColorLink(context: context, dryRun: false, records: &records)
    }
    if partial.contains("tuicr") {
      _ = try manager.setupTuicrThemeLink(context: context, dryRun: false, records: &records)
    }
    let ids = [
      "Codex": SetupOwnershipManager.codexThemeLinkID,
      "Pi": SetupOwnershipManager.piThemeLinkID,
      "Spicetify": SetupOwnershipManager.spicetifyColorLinkID,
      "tuicr": SetupOwnershipManager.tuicrThemeLinkID,
    ]
    let runtimeFirst = try #require(partial.first)
    let planFirst = try #require(
      ["tuicr", "Pi", "Spicetify", "Codex"].first(where: partial.contains))
    func expected(_ name: String) -> String {
      "environment lifecycle is blocked: legacy setup-owned \(name) integration is incomplete: \(ids[name]!)"
    }
    do {
      _ = try ThemeRuntimeSelection.enabledAdapterIDs(stateRoot: state, homeDirectory: home)
      Issue.record("Incomplete legacy ownership must block runtime selection")
    } catch {
      #expect(String(describing: error) == expected(runtimeFirst))
    }
    let plan = try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: root.appending(path: "absent.toml"), profileRequired: false,
      stateRoot: state, homeDirectory: home, json: true)
    let report = try jsonObject(plan.output)
    let diagnostics = try #require(report["diagnostics"] as? [[String: Any]])
    #expect(!plan.succeeded)
    #expect(diagnostics.first?["message"] as? String == expected(planFirst))
    #expect(try manager.readRecords(context: context) == records)
    #expect(try EnvironmentStateStore(stateRoot: state).readOwnership() == nil)
  }
}
