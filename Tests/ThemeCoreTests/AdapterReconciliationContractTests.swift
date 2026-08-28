import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func processRunnerTerminatesTimedOutCommands() throws {
    let executable = URL(filePath: "/bin/sleep")
    do {
      _ = try ProcessRunner.live.run(
        ProcessRequest(executableURL: executable, arguments: ["10"], timeout: 0.05)
      )
      Issue.record("Expected the process to time out")
    } catch let error as ProcessRunnerError {
      #expect(error == .timedOut(executable, 0.05))
    }
  }

  @Test
  func processRunnerAppliesEnvironmentOverrides() throws {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/printenv"),
        arguments: ["MACARCHY_PROCESS_TEST"],
        environmentOverrides: ["MACARCHY_PROCESS_TEST": "expected-value"]
      )
    )

    #expect(result.terminationStatus == 0)
    #expect(result.output == "expected-value")
  }

  @Test
  func independentAdaptersReconcileConcurrentlyAndPersistDeterministically() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)
    let reconciler = ThemeReconciler(statusStore: store)
    let entered = Mutex(Set<String>())

    let first = AdapterReconciliation(id: "zeta", requirement: .optional) {
      _ = entered.withLock { $0.insert("zeta") }
      try await Self.waitForBothAdapters(entered)
      return AdapterOutcome(status: .pending)
    }
    let second = AdapterReconciliation(id: "alpha", requirement: .required) {
      _ = entered.withLock { $0.insert("alpha") }
      try await Self.waitForBothAdapters(entered)
      throw ReconciliationTestError.expectedFailure
    }

    let record = try await reconciler.reconcile(manifest: manifest, adapters: [first, second])
    #expect(
      record.results
        == [
          AdapterResult(
            adapterID: "alpha",
            requirement: .required,
            status: .failed,
            message: "expectedFailure"
          ),
          AdapterResult(adapterID: "zeta", requirement: .optional, status: .pending),
        ]
    )
    #expect(try store.read() == .current(record))

    let duplicateCalls = Mutex(0)
    await #expect(throws: ReconciliationStatusError.duplicateAdapterID) {
      _ = try await reconciler.reconcile(
        manifest: manifest,
        adapters: ["duplicate", "duplicate"].map { id in
          AdapterReconciliation(id: id, requirement: .required) {
            duplicateCalls.withLock { $0 += 1 }
            return AdapterOutcome(status: .applied)
          }
        }
      )
    }
    #expect(duplicateCalls.withLock { $0 } == 0)

    let supersedingPackage = try tokyoNightPackage()
    let supersedingActivator = testActivator(root: root)
    let superseding = AdapterReconciliation(id: "kitty", requirement: .required) {
      _ = try supersedingActivator.activate(package: supersedingPackage)
      return AdapterOutcome(status: .applied)
    }
    do {
      _ = try await reconciler.reconcile(manifest: manifest, adapters: [superseding])
      Issue.record("Expected reconciliation persistence failure")
    } catch let error as ReconciliationPersistenceError {
      #expect(error.manifest.generationID == manifest.generationID)
      #expect(
        error.results == [
          AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)
        ])
      #expect(error.cause.contains("Cannot persist reconciliation"))
    }
  }

  @Test
  func reconciliationFaultsExposeWhetherCompletedResultsWerePersisted() async throws {
    for checkpoint in [
      ReconciliationCheckpoint.adaptersCompleted,
      .statusPersisted,
    ] {
      let root = try temporaryDirectory()
      defer {
        makeWritableForRemoval(root)
        try? FileManager.default.removeItem(at: root)
      }
      let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
      let store = ReconciliationStatusStore(root: root)
      let calls = Mutex(0)
      let adapter = AdapterReconciliation(id: "kitty", requirement: .required) {
        calls.withLock { $0 += 1 }
        return AdapterOutcome(status: .applied)
      }
      let reconciler = ThemeReconciler(
        statusStore: store,
        faultInjector: { reached in
          if reached == checkpoint { throw ReconciliationTestError.expectedFailure }
        }
      )

      let interruption: ReconciliationInterruptedError
      do {
        _ = try await reconciler.reconcile(manifest: manifest, adapters: [adapter])
        throw ReconciliationTestError.expectedInterruption
      } catch let error as ReconciliationInterruptedError {
        interruption = error
      }

      #expect(interruption.statusPersisted == (checkpoint == .statusPersisted))
      #expect(
        interruption.results
          == [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
      )
      if checkpoint == .adaptersCompleted {
        #expect(try store.read() == .missing(activeGenerationID: manifest.generationID))
      } else {
        guard case .current(let record) = try store.read() else {
          throw ReconciliationTestError.expectedCurrentStatus
        }
        #expect(record.results == interruption.results)
      }

      let recovered = try await ThemeReconciler(statusStore: store).reconcile(
        manifest: manifest,
        adapters: [adapter]
      )
      #expect(try store.read() == .current(recovered))
      #expect(calls.withLock { $0 } == 2)
    }

    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let cancelled = ThemeReconciler(
      statusStore: ReconciliationStatusStore(root: root),
      faultInjector: { _ in throw CancellationError() }
    )
    await #expect(throws: CancellationError.self) {
      _ = try await cancelled.reconcile(
        manifest: manifest,
        adapters: [
          AdapterReconciliation(id: "kitty", requirement: .required) {
            AdapterOutcome(status: .applied)
          }
        ]
      )
    }
  }

  @Test
  func typedResultsArePersistedDeterministicallyForTheActiveGeneration() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)

    let persisted = try store.persist(
      manifest: manifest,
      results: [
        AdapterResult(
          adapterID: "wallpaper",
          requirement: .required,
          status: .failed,
          message: "Desktop image could not be updated"
        ),
        AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
        AdapterResult(
          adapterID: "sketchybar",
          requirement: .required,
          status: .drifted,
          message: "Observed palette differs from the active generation"
        ),
      ]
    )

    #expect(persisted.generationID == manifest.generationID)
    #expect(persisted.themeID == manifest.themeID)
    #expect(persisted.results.map(\.adapterID) == ["kitty", "sketchybar", "wallpaper"])
    #expect(
      persisted.results.map(\.status)
        == [.applied, .drifted, .failed]
    )
    #expect(try store.read() == .current(persisted))

    let statusData = try Data(contentsOf: root.appending(path: "state/reconciliation.json"))
    #expect(statusData.last == 0x0a)
    let permissions = try #require(
      FileManager.default.attributesOfItem(
        atPath: root.appending(path: "state/reconciliation.json").path
      )[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o077 == 0)

    _ = try store.persist(manifest: manifest, results: Array(persisted.results.reversed()))
    #expect(
      try Data(contentsOf: root.appending(path: "state/reconciliation.json")) == statusData
    )
  }

  @Test
  func statusCannotOverrideOrConcealTheActiveGeneration() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let store = ReconciliationStatusStore(root: root)
    let catppuccin = try testActivator(root: root).activate(package: catppuccinPackage())
    let record = try store.persist(
      manifest: catppuccin,
      results: [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
    )

    let tokyoNight = try testActivator(root: root).activate(package: tokyoNightPackage())
    #expect(
      try store.read()
        == .stale(activeGenerationID: tokyoNight.generationID, record: record)
    )

    #expect(
      throws: ReconciliationStatusError.generationChanged(
        expected: catppuccin.generationID,
        active: tokyoNight.generationID
      )
    ) {
      _ = try store.persist(
        manifest: catppuccin,
        results: [AdapterResult(adapterID: "kitty", requirement: .required, status: .failed)]
      )
    }
  }

  @Test
  func missingAndMalformedStatusAreExplicit() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)

    #expect(try store.read() == .missing(activeGenerationID: manifest.generationID))
    let statusURL = root.appending(path: "state/reconciliation.json")
    try FileManager.default.createDirectory(
      at: statusURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let redirectedStatus = root.appending(path: "redirected-status.json")
    try "{}".write(to: redirectedStatus, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: statusURL.path,
      withDestinationPath: redirectedStatus.path
    )
    #expect(throws: ReconciliationStatusError.self) {
      _ = try store.read()
    }
    try FileManager.default.removeItem(at: statusURL)

    #expect(throws: ReconciliationStatusError.self) {
      _ = try store.persist(
        manifest: manifest,
        results: [
          AdapterResult(
            adapterID: "oversized",
            requirement: .required,
            status: .failed,
            message: String(repeating: "x", count: BoundedRegularFile.maximumSize)
          )
        ]
      )
    }
    #expect(throws: ReconciliationStatusError.duplicateAdapterID) {
      _ = try store.persist(
        manifest: manifest,
        results: [
          AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
          AdapterResult(adapterID: "kitty", requirement: .required, status: .drifted),
        ]
      )
    }

    _ = try store.persist(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "a", requirement: .required, status: .applied),
        AdapterResult(adapterID: "b", requirement: .required, status: .applied),
      ]
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: statusURL)) as? [String: Any]
    )
    object["results"] = Array(try #require(object["results"] as? [[String: Any]]).reversed())
    try JSONSerialization.data(withJSONObject: object).write(to: statusURL)
    #expect(throws: ReconciliationStatusError.nondeterministicResultOrder) {
      _ = try store.read()
    }
  }

  @Test
  func activeManifestRejectsBrokenPointerAndManifestIdentity() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let store = ReconciliationStatusStore(root: root)
    let missingGenerationID = "g-00000000-0000-0000-0000-000000000000"
    try FileManager.default.createSymbolicLink(
      atPath: root.appending(path: "current").path,
      withDestinationPath: "generations/\(missingGenerationID)"
    )
    try expectInvalidActiveGeneration { try store.activeManifest() }

    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let manifestURL = root.appending(path: "generations/\(manifest.generationID)/manifest.json")
    let original = try Data(contentsOf: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: manifestURL.path
    )
    try expectInvalidActiveGeneration { try store.activeManifest() }

    var object = try #require(
      JSONSerialization.jsonObject(with: original) as? [String: Any]
    )
    object["manifest_schema_version"] = GenerationManifest.currentSchemaVersion + 1
    try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: manifestURL.path
    )
    try expectInvalidActiveGeneration { try store.activeManifest() }

    object["manifest_schema_version"] = GenerationManifest.currentSchemaVersion
    object["generation_id"] = missingGenerationID
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: manifestURL.path
    )
    try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: manifestURL.path
    )
    try expectInvalidActiveGeneration { try store.activeManifest() }
  }

  private static func waitForBothAdapters(_ entered: borrowing Mutex<Set<String>>) async throws {
    for _ in 0..<100 {
      if entered.withLock({ $0.count }) == 2 { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ReconciliationTestError.timedOut
  }

  private func expectInvalidActiveGeneration(
    _ operation: () throws -> GenerationManifest
  ) throws {
    do {
      _ = try operation()
      Issue.record("Expected invalid active generation")
    } catch ReconciliationStatusError.invalidActiveGeneration {
      return
    }
  }

}
