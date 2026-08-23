import Foundation
import Synchronization
import Testing

@testable import ThemeCore

struct AdapterContractTests {
  @Test
  func activationPublishesBeforeKittyReloadFailureIsPersisted() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let includeDirective = "include \(root.path)/current/generated/kitty.conf"
    let configurationURL = root.appending(path: "kitty.conf")
    try "\(includeDirective)\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let state = Mutex((published: false, requests: [ProcessRequest]()))
    let runner = ProcessRunner { request in
      let published = state.withLock { state in
        state.requests.append(request)
        return state.published
      }
      #expect(published)
      if request.arguments == ["-0", "kitty"] {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      return ProcessResult(terminationStatus: 1, output: "reload denied")
    }
    let store = ReconciliationStatusStore(root: root)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      kittyConfigurationURL: configurationURL,
      processRunner: runner,
      onThemeChanged: { _ in state.withLock { $0.published = true } }
    )

    let activation = try await coordinator.activate(package: catppuccinPackage())

    #expect(
      state.withLock { $0.requests }
        == [
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/killall"),
            arguments: ["-USR1", "kitty"]
          ),
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/killall"),
            arguments: ["-0", "kitty"]
          ),
        ]
    )
    #expect(
      activation.reconciliation.results
        == [
          AdapterResult(
            adapterID: "kitty",
            requirement: .required,
            status: .failed,
            message: "reload denied"
          )
        ]
    )
    #expect(try store.read() == .current(activation.reconciliation))

    let retryRequests = Mutex([ProcessRequest]())
    let retryKitty = KittyAdapter(
      configurationURL: configurationURL,
      includeDirective: includeDirective,
      processRunner: ProcessRunner { request in
        retryRequests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 1, output: "no matching process")
      }
    )
    let recovered = try await ThemeReconciler(statusStore: store).reconcile(
      manifest: activation.manifest,
      adapters: [retryKitty.reconciliation()]
    )
    #expect(
      recovered.results
        == [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
    )
    #expect(
      retryRequests.withLock { $0 }.map(\.arguments)
        == [["-USR1", "kitty"], ["-0", "kitty"]]
    )
    #expect(try store.read() == .current(recovered))
  }

  @Test
  func kittyPreflightFailurePreservesThePreviousGeneration() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let previous = try testActivator(root: root).activate(package: tokyoNightPackage())
    let configurationURL = root.appending(path: "kitty.conf")
    try "include bindings.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let calls = Mutex(0)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      kittyConfigurationURL: configurationURL,
      processRunner: ProcessRunner { _ in
        calls.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      onThemeChanged: { _ in calls.withLock { $0 += 1 } }
    )

    await #expect(throws: KittyAdapterError.self) {
      _ = try await coordinator.activate(package: catppuccinPackage())
    }

    #expect(calls.withLock { $0 } == 0)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: "current").path
      ) == "generations/\(previous.generationID)"
    )
  }

  @Test
  func cancellationBeforeActivationDoesNotCommit() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configurationURL = root.appending(path: "kitty.conf")
    try "include \(root.path)/current/generated/kitty.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let coordinator = ThemeActivationCoordinator(
      root: root,
      kittyConfigurationURL: configurationURL,
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") }
    )

    let activation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await coordinator.activate(package: catppuccinPackage())
    }
    await #expect(throws: CancellationError.self) {
      _ = try await activation.value
    }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "current").path))
  }

  @Test
  func supersedingActivationReturnsTheCommittedManifestWithPostcommitFailure() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configurationURL = root.appending(path: "kitty.conf")
    try "include \(root.path)/current/generated/kitty.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let tokyoNight = try tokyoNightPackage()
    let supersedingManifest = Mutex<GenerationManifest?>(nil)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      kittyConfigurationURL: configurationURL,
      processRunner: ProcessRunner { _ in
        let manifest = try ThemeActivator(root: root, faultInjector: { _ in }).activate(
          package: tokyoNight
        )
        supersedingManifest.withLock { $0 = manifest }
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )

    let error: ThemeCommittedWithReconciliationError
    do {
      _ = try await coordinator.activate(package: catppuccinPackage())
      throw ReconciliationTestError.expectedCommittedError
    } catch let committed as ThemeCommittedWithReconciliationError {
      error = committed
    }

    let active = try #require(supersedingManifest.withLock { $0 })
    #expect(error.manifest.themeID == "catppuccin-mocha")
    #expect(
      try ReconciliationStatusStore(root: root).read()
        == .missing(activeGenerationID: active.generationID)
    )
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
  func selectedReconciliationRejectsInvalidIDsBeforeProcessesOrStatusWrites() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let configurationURL = root.appending(path: "kitty.conf")
    try "include \(root.path)/current/generated/kitty.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let processCalls = Mutex(0)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      kittyConfigurationURL: configurationURL,
      processRunner: ProcessRunner { _ in
        processCalls.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )

    await #expect(throws: AdapterSelectionError.unknown("wallpaper")) {
      _ = try await coordinator.reconcile(adapterIDs: ["wallpaper"])
    }
    await #expect(throws: AdapterSelectionError.duplicate("kitty")) {
      _ = try await coordinator.reconcile(adapterIDs: ["kitty", "kitty"])
    }

    #expect(processCalls.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "state").path))
  }

  @Test
  func reconcileDryRunInspectsWithoutProcessesOrStatusWrites() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let configurationURL = root.appending(path: "kitty.conf")
    try "include other.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let processCalls = Mutex(0)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      kittyConfigurationURL: configurationURL,
      processRunner: ProcessRunner { _ in
        processCalls.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )

    let preview = try coordinator.previewReconciliation([])

    #expect(preview.manifest.generationID == manifest.generationID)
    #expect(preview.manifest.themeID == manifest.themeID)
    #expect(preview.inspections.count == 1)
    #expect(preview.inspections[0].adapterID == "kitty")
    #expect(preview.inspections[0].status == .drifted)
    #expect(preview.inspections[0].message?.contains("must contain") == true)
    #expect(processCalls.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "state").path))

    try FileManager.default.removeItem(at: configurationURL)
    let unreadable = try coordinator.inspectAdapters([])
    #expect(unreadable[0].status == .failed)
  }

  @Test
  func repeatedSelectedReconciliationPreservesOtherResultsAndIsIdempotent() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let configurationURL = root.appending(path: "kitty.conf")
    try "include \(root.path)/current/generated/kitty.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let statusStore = ReconciliationStatusStore(root: root)
    _ = try statusStore.persist(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "kitty", requirement: .required, status: .failed),
        AdapterResult(
          adapterID: "wallpaper",
          requirement: .required,
          status: .failed,
          message: "apply failed"
        ),
      ]
    )
    let requests = Mutex([ProcessRequest]())
    let coordinator = ThemeActivationCoordinator(
      root: root,
      kittyConfigurationURL: configurationURL,
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 1, output: "no matching process")
      }
    )

    let first = try await coordinator.reconcile(adapterIDs: ["kitty"])
    let statusURL = root.appending(path: "state/reconciliation.json")
    let firstData = try Data(contentsOf: statusURL)
    let second = try await coordinator.reconcile(adapterIDs: ["kitty"])

    #expect(first.record == second.record)
    #expect(first.record.results.map(\.adapterID) == ["kitty", "wallpaper"])
    #expect(first.record.results[1].message == "apply failed")
    #expect(try Data(contentsOf: statusURL) == firstData)
    #expect(
      requests.withLock { $0 }.map(\.arguments)
        == [
          ["-USR1", "kitty"], ["-0", "kitty"],
          ["-USR1", "kitty"], ["-0", "kitty"],
        ]
    )
  }

  @Test
  func reconciliationRejectsCorruptActiveArtifactsBeforeProcessesRun() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let configurationURL = root.appending(path: "kitty.conf")
    try "include \(root.path)/current/generated/kitty.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let artifactURL = root.appending(
      path: "generations/\(manifest.generationID)/generated/kitty.conf"
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: artifactURL.path)
    try "corrupt\n".write(to: artifactURL, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444], ofItemAtPath: artifactURL.path)
    let processCalls = Mutex(0)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      kittyConfigurationURL: configurationURL,
      processRunner: ProcessRunner { _ in
        processCalls.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )

    await #expect(throws: ReconciliationStatusError.self) {
      _ = try await coordinator.reconcile(adapterIDs: [])
    }
    #expect(processCalls.withLock { $0 } == 0)
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

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func catppuccinPackage() throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
  }

  private func tokyoNightPackage() throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/tokyo-night",
        directoryHint: .isDirectory
      )
    )
  }

  private func testActivator(root: URL) -> ThemeActivator {
    ThemeActivator(root: root, faultInjector: { _ in })
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-adapter-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeWritableForRemoval(_ root: URL) {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else { return }
    var directories = [root]
    for case let item as URL in enumerator {
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(item)
      }
    }
    for directory in directories.reversed() {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
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

private enum ReconciliationTestError: Error {
  case expectedCommittedError
  case expectedFailure
  case timedOut
}
