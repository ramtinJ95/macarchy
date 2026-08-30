import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingsEffectiveCommandTests {
  @Test
  func cleanStateAgreesAcrossInspectionPlanApplyAndStatus() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }

    let reports = try fixture.crossCommandReports()

    #expect(reports.list["status"] as? String == "clean")
    #expect(reports.plan["schema_version"] as? Int == 2)
    #expect(reports.plan["effective_status"] as? String == "clean")
    #expect(reports.status["outcome"] as? String == "clean")
    #expect(reports.apply["outcome"] as? String == "planned")
    #expect(reports.doctorIDs.contains("effective.status.clean"))
    #expect(try fixture.show(fixture.inspect()).stateMessage.contains("Not configured"))
  }

  @Test
  func managedConvergedStateAgreesAcrossInspectionPlanApplyAndStatus() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    #expect(
      try fixture.applyRunner().execute(
        resourcesRoot: fixture.resources,
        profileURL: fixture.profile,
        profileRequired: true,
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        json: true
      ).succeeded
    )

    let reports = try fixture.crossCommandReports()

    #expect(reports.list["status"] as? String == "converged")
    #expect(reports.plan["effective_status"] as? String == "converged")
    #expect(reports.status["outcome"] as? String == "converged")
    #expect(reports.apply["outcome"] as? String == "no_change")
    #expect(reports.doctorIDs.contains("effective.status.converged"))
    let popup = try fixture.show(fixture.inspect())
    #expect(popup.heading == "Managed Keybindings")
    #expect(popup.stateMessage.contains("does not expose its complete in-memory binding table"))
  }

  @Test
  func managedInputDriftAgreesAcrossInspectionPlanApplyAndStatus() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    _ = try fixture.applyRunner().execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    try "alt - j : changed again\ncmd - x : personal command\ncmd - a : tied order\n".write(
      to: fixture.profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
      atomically: true,
      encoding: .utf8
    )

    let reports = try fixture.crossCommandReports()

    #expect(reports.list["status"] as? String == "drifted")
    #expect(reports.plan["effective_status"] as? String == "drifted")
    #expect(reports.status["outcome"] as? String == "drifted")
    #expect(reports.apply["outcome"] as? String == "planned")
    #expect(reports.doctorIDs.contains("effective.status.drifted"))
    #expect(try fixture.show(fixture.inspect()).stateMessage.contains("Showing desired bindings"))
  }

  @Test
  func externallyManagedAdoptionStateAgreesAcrossInspectionPlanApplyAndStatus() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    try "alt - j : authoritative external command\n".write(
      to: fixture.home.appending(path: ".config/skhd/skhdrc"),
      atomically: true,
      encoding: .utf8
    )

    let reports = try fixture.crossCommandReports()

    #expect(reports.list["status"] as? String == "externally_managed")
    #expect(reports.plan["effective_status"] as? String == "externally_managed")
    #expect(reports.status["outcome"] as? String == "externally_managed")
    #expect(reports.apply["outcome"] as? String == "blocked")
    #expect(reports.doctorIDs.contains("effective.status.externally_managed"))
    let popup = try fixture.show(fixture.inspect())
    #expect(popup.stateMessage.contains("Externally managed"))
    #expect(popup.stateMessage.contains("not the authoritative external source"))
  }

  @Test
  func corruptGeneratedStateAgreesAcrossInspectionPlanApplyAndStatus() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let keybindings = fixture.stateRoot.appending(
      path: "keybindings", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: keybindings, withIntermediateDirectories: true)
    try Data("not a symlink".utf8).write(to: keybindings.appending(path: "current"))

    let reports = try fixture.crossCommandReports()

    #expect(reports.list["status"] as? String == "blocked")
    #expect(reports.plan["effective_status"] as? String == "blocked")
    #expect(reports.status["outcome"] as? String == "blocked")
    #expect(reports.apply["outcome"] as? String == "blocked")
    #expect(reports.doctorIDs.contains("effective.status.blocked"))
    #expect(throws: KeybindingsShowError.self) {
      try fixture.show(fixture.inspect())
    }
  }

  @Test
  func pendingRecoveryStateAgreesAcrossInspectionPlanApplyAndStatus() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.stateRoot,
      withIntermediateDirectories: true
    )
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(
      KeybindingApplyTransaction(
        operation: .installEntry,
        phase: .staged,
        generationID: "k-01234567-89ab-cdef-0123-456789abcdef",
        previousGenerationID: nil,
        generationCreated: true
      )
    )

    let reports = try fixture.crossCommandReports()

    #expect(reports.list["status"] as? String == "recovery_required")
    #expect(reports.plan["effective_status"] as? String == "recovery_required")
    #expect(reports.status["outcome"] as? String == "recovery_required")
    #expect(reports.apply["outcome"] as? String == "recovery_planned")
    #expect(reports.doctorIDs.contains("effective.status.recovery_required"))
    #expect(try fixture.show(fixture.inspect()).stateMessage.contains("Recovery required"))
  }

  @Test
  func listShowDoctorPlanAndApplyPreviewConsumeOneAttributedEffectiveState() throws {
    let fixture = try EffectiveCommandFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let state = fixture.inspect()

    let list = try KeybindingsListCommandRunner.live.execute(effectiveState: state, json: true)
    let listReport = try fixture.json(list.output)
    let listed = try #require(listReport["bindings"] as? [[String: Any]])
    let disabled = try #require(listReport["disabled_defaults"] as? [[String: Any]])

    let show = try KeybindingsShowCommandLoader(
      read: readSkhdConfiguration,
      loadCatalog: { try SkhdKeybindingCatalogLoader().load(at: $0) },
      loadTheme: { _ in try fixture.theme() }
    ).load(effectiveState: state, stateRoot: fixture.stateRoot)

    let doctor = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: state,
      stateRoot: fixture.stateRoot,
      json: true
    )
    let doctorReport = try fixture.json(doctor.output)
    let findings = try #require(doctorReport["findings"] as? [[String: Any]])

    let plan = try KeybindingsPlanCommandRunner.live.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let planReport = try fixture.json(plan.output)
    let planned = try #require(planReport["bindings"] as? [[String: Any]])

    let apply = try KeybindingsApplyCommandRunner(
      lifecycle: KeybindingLifecycleController(
        preflight: {},
        restart: {},
        reload: {},
        verifyProcess: {},
        inspectProcess: { .testRunning }
      )
    ).preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let applyReport = try fixture.json(apply.output)

    let expectedPresentedIdentities = ["cmd-a", "cmd-x", "alt-j"]
    #expect(list.succeeded)
    #expect(show.rows.map(\.identity) == expectedPresentedIdentities)
    #expect(
      listed.compactMap { $0["identity"] as? String } == expectedPresentedIdentities
    )
    #expect(
      planned.compactMap { $0["identity"] as? String } == ["alt-j", "cmd-a", "cmd-x"]
    )
    #expect(
      listed.compactMap { $0["command_source"] as? String } == [
        "user_addition", "user_addition", "user_replacement",
      ])
    #expect(
      show.rows.compactMap(\.commandSource) == [
        "user_addition", "user_addition", "user_replacement",
      ])
    #expect(disabled.first?["identity"] as? String == "alt-k")
    #expect(disabled.first?["command_source"] as? String == "packaged_default")
    #expect(disabled.first?["metadata_source"] as? String == "packaged_default")
    #expect(listReport["generation_agreement"] as? String == "missing")
    #expect(listReport["schema_version"] as? Int == 2)
    #expect(listReport["operation"] as? String == "keybindings_list_effective")
    #expect(show.heading == "Desired Managed Keybindings")
    #expect(show.stateMessage.contains("Not configured"))
    #expect(show.rowDescription == "desired shortcuts")
    #expect(
      findings.contains {
        $0["id"] as? String == "effective.disabled"
          && $0["identities"] as? [String] == ["alt-k"]
      }
    )
    #expect(doctorReport["schema_version"] as? Int == 2)
    #expect(doctorReport["operation"] as? String == "keybindings_doctor_effective")
    #expect(plan.succeeded)
    #expect(apply.succeeded)
    #expect(applyReport["outcome"] as? String == "planned")
    #expect(applyReport["mutated"] as? Bool == false)
  }

  @Test
  func differingGenerationIsVisibleAsDesiredDriftInPopup() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let desired = fixture.inspect()
    let composition = try #require(desired.configuration.composition)
    try fixture.publish(
      configuration: try #require(composition.renderedConfiguration),
      inputDigest: sha256Digest(Data("different inputs".utf8)),
      renderedDigest: try #require(composition.renderedDigest)
    )
    let state = fixture.inspect()

    let content = try fixture.show(state)

    #expect(state.generationAgreement == .differs)
    #expect(content.heading == "Desired Managed Keybindings")
    #expect(content.stateMessage.contains("Drift detected"))
    #expect(content.stateMessage.contains("Showing desired bindings"))
  }

  @Test
  func corruptGenerationFailsListDoctorAndPopup() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let keybindings = fixture.stateRoot.appending(
      path: "keybindings", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: keybindings, withIntermediateDirectories: true)
    try Data("not a symlink".utf8).write(to: keybindings.appending(path: "current"))
    let state = fixture.inspect()

    let list = try KeybindingsListCommandRunner.live.execute(effectiveState: state, json: true)
    let doctor = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: state,
      stateRoot: fixture.stateRoot,
      json: true
    )
    let doctorReport = try fixture.json(doctor.output)

    #expect(!list.succeeded)
    #expect(!doctor.succeeded)
    #expect(doctorReport["outcome"] as? String == "unhealthy")
    #expect(throws: KeybindingsShowError.self) {
      try fixture.show(state)
    }
  }

  @Test
  func interruptedOrCorruptTransactionFailsEffectiveDoctorClosed() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.stateRoot, withIntermediateDirectories: true)
    let transaction = KeybindingApplyTransaction(
      operation: .installEntry,
      phase: .activating,
      generationID: "k-01234567-89ab-cdef-0123-456789abcdef",
      previousGenerationID: nil,
      generationCreated: true
    )
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(transaction)

    let interrupted = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: fixture.inspect(),
      stateRoot: fixture.stateRoot,
      json: true
    )
    let interruptedReport = try fixture.json(interrupted.output)
    let interruptedFindings = try #require(
      interruptedReport["findings"] as? [[String: Any]])

    #expect(!interrupted.succeeded)
    #expect(interruptedReport["outcome"] as? String == "unhealthy")
    #expect(
      interruptedFindings.contains {
        ($0["id"] as? String)?.hasPrefix("transaction.recovery.install_entry.activating.")
          == true
      }
    )

    try Data("{}".utf8).write(
      to: fixture.stateRoot.appending(path: "keybindings/transaction.json"),
      options: .atomic
    )
    let corrupt = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: fixture.inspect(),
      stateRoot: fixture.stateRoot,
      json: true
    )
    let corruptFindings = try #require(
      fixture.json(corrupt.output)["findings"] as? [[String: Any]])
    #expect(!corrupt.succeeded)
    #expect(corruptFindings.contains { $0["id"] as? String == "transaction.invalid" })
  }

  @Test
  func repeatedEffectiveDiagnosticCodesHaveStableUniqueIDs() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    try "unsupported line\nalso unsupported\n".write(
      to: fixture.profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    let state = fixture.inspect()
    let doctor = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: state,
      stateRoot: fixture.stateRoot,
      json: true
    )
    let findings = try #require(
      fixture.json(doctor.output)["findings"] as? [[String: Any]])
    let syntaxIDs = findings.compactMap { finding -> String? in
      guard let id = finding["id"] as? String, id.hasPrefix("effective.unsupported_syntax.")
      else { return nil }
      return id
    }

    #expect(syntaxIDs.count == 2)
    #expect(Set(syntaxIDs).count == 2)
    #expect(syntaxIDs.contains { $0.hasSuffix("line-1") })
    #expect(syntaxIDs.contains { $0.hasSuffix("line-2") })
  }

  @Test
  func successfulApplyPersistsGenerationCorrelatedLifecycleEvidence() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let runner = fixture.applyRunner()
    let applied = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )

    #expect(applied.succeeded)
    #expect(fixture.inspect().lifecycleEvidence.status == .matched)

    try KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot).remove()
    let legacy = fixture.inspect()
    #expect(legacy.status == .drifted)
    #expect(legacy.lifecycleEvidence.status == .missing)
    let preview = try runner.preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(preview.succeeded)
    #expect(try fixture.json(preview.output)["lifecycle"] as? String == "reload")

    let repaired = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(repaired.succeeded)
    #expect(fixture.inspect().status == .converged)
  }

  @Test
  func corruptLifecycleEvidenceBlocksConvergence() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    _ = try fixture.applyRunner().execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    try Data("{}".utf8).write(
      to: fixture.stateRoot.appending(path: "keybindings/lifecycle.json"),
      options: .atomic
    )

    let behavior = fixture.inspect()

    #expect(behavior.status == .blocked)
    #expect(behavior.lifecycleEvidence.status == .invalid)
  }

  @Test
  func lifecycleEvidenceReadRejectsMissingOrInvalidProcessIdentity() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    _ = try fixture.applyRunner().execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let evidence = try #require(fixture.inspect().lifecycleEvidence.evidence)
    let encoded = try JSONEncoder().encode(evidence)
    let base = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var missingProcessID = base
    missingProcessID.removeValue(forKey: "process_id")
    var missingExecutable = base
    missingExecutable.removeValue(forKey: "executable_path")
    var missingArguments = base
    missingArguments.removeValue(forKey: "arguments")
    var zeroProcessID = base
    zeroProcessID["process_id"] = 0
    var unsupportedExecutable = base
    unsupportedExecutable["executable_path"] = "/unsupported/skhd"
    var emptyArguments = base
    emptyArguments["arguments"] = []
    let lifecycle = fixture.stateRoot.appending(path: "keybindings/lifecycle.json")

    for malformed in [
      missingProcessID,
      missingExecutable,
      missingArguments,
      zeroProcessID,
      unsupportedExecutable,
      emptyArguments,
    ] {
      try JSONSerialization.data(withJSONObject: malformed, options: [.sortedKeys]).write(
        to: lifecycle,
        options: .atomic
      )
      let behavior = fixture.inspect()
      #expect(behavior.status == .blocked)
      #expect(behavior.lifecycleEvidence.status == .invalid)
    }
  }

  @Test
  func lifecycleEvidenceWriteRejectsInvalidProcessValues() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    _ = try fixture.applyRunner().execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let evidence = try #require(fixture.inspect().lifecycleEvidence.evidence)
    let encoded = try JSONEncoder().encode(evidence)
    let base = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var zeroProcessID = base
    zeroProcessID["process_id"] = 0
    var unsupportedExecutable = base
    unsupportedExecutable["executable_path"] = "/unsupported/skhd"
    var emptyArguments = base
    emptyArguments["arguments"] = []
    let store = KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot)

    for malformed in [zeroProcessID, unsupportedExecutable, emptyArguments] {
      let decoded = try JSONDecoder().decode(
        KeybindingLifecycleEvidence.self,
        from: JSONSerialization.data(withJSONObject: malformed, options: [.sortedKeys])
      )
      #expect(throws: KeybindingApplyTransactionError.self) {
        try store.write(decoded)
      }
    }
  }

  @Test
  func lifecycleEvidenceRequiresExactProcessIdentityAndArguments() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    _ = try fixture.applyRunner().execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let evidence = try #require(fixture.inspect().lifecycleEvidence.evidence)
    let encoded = try JSONEncoder().encode(evidence)
    let base = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var differentProcessID = base
    differentProcessID["process_id"] = evidence.processID + 1
    var differentArguments = base
    differentArguments["arguments"] = ["skhd", "--verbose"]
    let store = KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot)

    for stale in [differentProcessID, differentArguments] {
      let decoded = try JSONDecoder().decode(
        KeybindingLifecycleEvidence.self,
        from: JSONSerialization.data(withJSONObject: stale, options: [.sortedKeys])
      )
      try store.write(decoded)
      let behavior = fixture.inspect()
      #expect(behavior.status == .drifted)
      #expect(behavior.lifecycleEvidence.status == .stale)
    }
  }

  @Test
  func managedStoppedProcessBlocksPlanInsteadOfReportingNoChange() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    _ = try fixture.applyRunner().execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )

    let plan = try fixture.planner(process: .notRunning).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )

    #expect(!plan.succeeded)
    #expect(try fixture.json(plan.output)["outcome"] as? String == "blocked")
  }

  @Test
  func applyPostconditionRequiresConvergedEffectiveBehaviorBeforeCleanup() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let observations = Mutex(0)
    let inspector = KeybindingProcessInspector {
      observations.withLock { count in
        count += 1
        return count <= 2 ? .testRunning : .notRunning
      }
    }
    let runner = KeybindingsApplyCommandRunner(
      lifecycle: KeybindingLifecycleController(
        restart: {},
        reload: {},
        verifyProcess: {},
        inspectProcess: { .testRunning }
      ),
      planner: KeybindingsPlanCommandRunner(
        effectiveInspector: KeybindingEffectiveBehaviorInspector(processInspector: inspector)
      )
    )

    let execution = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(try fixture.json(execution.output)["outcome"] as? String == "failed")
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing
    )
  }

  @Test
  func changingObservationFailsClosedAfterBoundedInspectionRetries() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let observations = Mutex(0)
    let inspector = KeybindingProcessInspector {
      observations.withLock { count in
        count += 1
        return count.isMultiple(of: 2) ? .notRunning : .testRunning
      }
    }

    let behavior = KeybindingEffectiveBehaviorInspector(processInspector: inspector).inspect(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home
    )

    #expect(behavior.status == .blocked)
    #expect(behavior.statusMessage.contains("changed during bounded inspection"))
  }

  @Test
  func processInspectionValidatesExecutableIdentityAndConfigSelection() {
    let expected = "/supported/skhd"
    let supported = KeybindingProcessInspector.validated(
      processIDs: [42],
      expectedExecutable: expected,
      snapshot: { id in
        KeybindingProcessSnapshot(
          processID: id,
          executablePath: expected,
          arguments: ["skhd"]
        )
      }
    )
    let wrongExecutable = KeybindingProcessInspector.validated(
      processIDs: [42],
      expectedExecutable: expected,
      snapshot: { id in
        KeybindingProcessSnapshot(
          processID: id,
          executablePath: "/unsupported/skhd",
          arguments: ["skhd"]
        )
      }
    )
    let explicitConfig = KeybindingProcessInspector.validated(
      processIDs: [42],
      expectedExecutable: expected,
      snapshot: { id in
        KeybindingProcessSnapshot(
          processID: id,
          executablePath: expected,
          arguments: ["skhd", "-c", "/tmp/external.skhdrc"]
        )
      }
    )
    let missingArguments = KeybindingProcessInspector.validated(
      processIDs: [42],
      expectedExecutable: expected,
      snapshot: { id in
        KeybindingProcessSnapshot(
          processID: id,
          executablePath: expected,
          arguments: []
        )
      }
    )

    #expect(supported.status == .running)
    #expect(wrongExecutable.status == .unsupported)
    #expect(explicitConfig.status == .unsupported)
    #expect(missingArguments.status == .unavailable)
  }

  @Test
  func statusExitSemanticsAreZeroOnlyForConverged() throws {
    let fixture = try EffectiveCommandFixture()
    defer { fixture.remove() }
    let base = fixture.inspect()
    let statuses: [KeybindingEffectiveStatus] = [
      .clean, .converged, .drifted, .externallyManaged, .blocked, .recoveryRequired,
    ]

    for status in statuses {
      let behavior = KeybindingEffectiveBehavior(
        desired: base.desired,
        provider: base.provider,
        transaction: base.transaction,
        process: base.process,
        lifecycleEvidence: base.lifecycleEvidence,
        status: status,
        statusMessage: status.rawValue
      )
      let execution = try KeybindingsStatusCommandRunner().execute(
        behavior: behavior,
        json: true
      )
      #expect(execution.succeeded == (status == .converged))
    }
  }
}

private struct EffectiveCommandFixture {
  let root: URL
  let home: URL
  let resources: URL
  let profile: URL
  let stateRoot: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-effective-command-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    resources = root.appending(path: "resources", directoryHint: .isDirectory)
    profile = root.appending(path: "dotfiles/profile.toml")
    stateRoot = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    for directory in [
      resources,
      profile.deletingLastPathComponent(),
      home.appending(path: ".config/skhd", directoryHint: .isDirectory),
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    try "alt - j : default south\nalt - k : default north\n".write(
      to: resources.appending(path: "defaults.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try Self.metadata([
      ("alt-j", "Focus south", 1),
      ("alt-k", "Focus north", 2),
    ]).write(
      to: resources.appending(path: "metadata.toml"),
      atomically: true,
      encoding: .utf8
    )
    try """
    schema_version = 1
    [keybindings]
    override = "personal.skhdrc"
    metadata = "personal-metadata.toml"
    disabled = ["alt-k"]
    """.write(to: profile, atomically: true, encoding: .utf8)
    try "alt - j : personal south\ncmd - x : personal command\ncmd - a : tied order\n".write(
      to: profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try Self.metadata([
      ("alt-j", "Personal focus", 20),
      ("cmd-x", "Personal command", 1),
      ("cmd-a", "Tied order", 1),
    ]).write(
      to: profile.deletingLastPathComponent().appending(path: "personal-metadata.toml"),
      atomically: true,
      encoding: .utf8
    )
  }

  func inspect(
    process: KeybindingProcessInspection = .testRunning
  ) -> KeybindingEffectiveBehavior {
    KeybindingEffectiveBehaviorInspector(
      processInspector: KeybindingProcessInspector { process }
    ).inspect(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: true,
      stateRoot: stateRoot,
      homeDirectory: home
    )
  }

  func planner(
    process: KeybindingProcessInspection = .testRunning
  ) -> KeybindingsPlanCommandRunner {
    KeybindingsPlanCommandRunner(
      effectiveInspector: KeybindingEffectiveBehaviorInspector(
        processInspector: KeybindingProcessInspector { process }
      )
    )
  }

  func applyRunner(
    process: KeybindingProcessInspection = .testRunning
  ) -> KeybindingsApplyCommandRunner {
    KeybindingsApplyCommandRunner(
      lifecycle: KeybindingLifecycleController(
        preflight: {},
        restart: {},
        reload: {},
        verifyProcess: {},
        inspectProcess: { process }
      ),
      planner: planner(process: process)
    )
  }

  func crossCommandReports() throws -> (
    list: [String: Any],
    doctorIDs: [String],
    plan: [String: Any],
    apply: [String: Any],
    status: [String: Any]
  ) {
    let behavior = inspect()
    let list = try KeybindingsListCommandRunner.live.execute(
      effectiveState: behavior,
      json: true
    )
    let doctor = try KeybindingsDoctorCommandRunner.live.execute(
      effectiveState: behavior,
      stateRoot: stateRoot,
      json: true
    )
    let plan = try planner().execute(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: true,
      stateRoot: stateRoot,
      homeDirectory: home,
      json: true
    )
    let apply = try applyRunner().preview(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: true,
      stateRoot: stateRoot,
      homeDirectory: home,
      json: true
    )
    let status = try KeybindingsStatusCommandRunner().execute(behavior: behavior, json: true)
    let doctorJSON = try json(doctor.output)
    let doctorFindings = try #require(doctorJSON["findings"] as? [[String: Any]])
    return (
      try json(list.output),
      doctorFindings.compactMap { $0["id"] as? String },
      try json(plan.output),
      try json(apply.output),
      try json(status.output)
    )
  }

  func json(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  func theme() throws -> NormalizedTheme {
    let fixture = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures/Golden/catppuccin-mocha/theme.json")
    return try JSONDecoder().decode(NormalizedTheme.self, from: Data(contentsOf: fixture))
  }

  func show(_ state: KeybindingEffectiveBehavior) throws -> KeybindingsPopupContent {
    try KeybindingsShowCommandLoader(
      read: readSkhdConfiguration,
      loadCatalog: { try SkhdKeybindingCatalogLoader().load(at: $0) },
      loadTheme: { _ in try theme() }
    ).load(effectiveState: state, stateRoot: stateRoot)
  }

  func publish(configuration: String, inputDigest: String, renderedDigest: String) throws {
    let generationID = "k-01234567-89ab-cdef-0123-456789abcdef"
    let keybindings = stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
    let generation = keybindings.appending(
      path: "generations/\(generationID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    try JSONEncoder().encode(
      KeybindingGenerationManifest(
        generationID: generationID,
        inputDigest: inputDigest,
        renderedDigest: renderedDigest
      )
    ).write(to: generation.appending(path: "manifest.json"))
    try Data(configuration.utf8).write(to: generation.appending(path: "skhdrc"))
    for file in ["manifest.json", "skhdrc"] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444],
        ofItemAtPath: generation.appending(path: file).path
      )
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: generation.path)
    try FileManager.default.createSymbolicLink(
      atPath: keybindings.appending(path: "current").path,
      withDestinationPath: "generations/\(generationID)"
    )
  }

  func remove() {
    let generation = stateRoot.appending(
      path: "keybindings/generations/k-01234567-89ab-cdef-0123-456789abcdef"
    )
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: generation.path)
    try? FileManager.default.removeItem(at: root)
  }

  private static func metadata(_ records: [(String, String, Int)]) -> String {
    records.reduce(into: "schema_version = 1\n") { text, record in
      text += """

        [[bindings]]
        identity = "\(record.0)"
        label = "\(record.1)"
        category = "Test"
        order = \(record.2)
        """
    }
  }
}

extension KeybindingProcessInspection {
  static let testRunning = KeybindingProcessInspection(
    status: .running,
    message: "The test skhd process is running.",
    processID: 42,
    executablePath: KeybindingProcessInspector.supportedExecutablePath,
    arguments: ["skhd"]
  )
}
