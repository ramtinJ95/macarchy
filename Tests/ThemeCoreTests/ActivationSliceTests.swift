import CryptoKit
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import ThemeCore

@Suite(.serialized)
struct ActivationSliceTests {
  @Test
  func schemaOneActiveGenerationRemainsReadableAcrossBackgroundManifestUpgrade() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let current = try testActivator(root: root).activate(package: catppuccinPackage())
    let manifestURL = root.appending(
      path: "generations/\(current.generationID)/manifest.json"
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
    )
    object["manifest_schema_version"] = GenerationManifest.legacySchemaVersion
    object.removeValue(forKey: "theme_digest")
    object.removeValue(forKey: "background")
    var data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0a)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: manifestURL.path
    )
    try data.write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: manifestURL.path
    )

    let legacy = try ReconciliationStatusStore(root: root).activeManifest()
    #expect(legacy.manifestSchemaVersion == GenerationManifest.legacySchemaVersion)
    #expect(legacy.themeDigest.isEmpty)
    #expect(legacy.background == nil)
  }

  @Test
  func importedPaletteOutputsBecomeRequiredWithoutInvalidatingOlderManifests() throws {
    let metadata = try ThemeRenderer.validatedArtifactMetadata()
    #expect(metadata[ThemeRenderer.capabilitiesOutputPath]?.requirement == .optional)
    #expect(metadata[WallpaperAdapter.outputPath]?.sizePolicy == .wallpaper)
    #expect(metadata[WallpaperAdapter.outputPath]?.maximumSize == WallpaperAsset.maximumSize)
    #expect(
      metadata[HerdrAdapter.outputPath]?.requirement
        == .requiredWhenRendererVersion(renderer: .herdr, minimumVersion: 3)
    )
    #expect(
      try !ThemeRenderer.requiredOutputPaths(rendererVersions: [HerdrAdapter.id: 2])
        .contains(HerdrAdapter.outputPath)
    )
    #expect(
      try ThemeRenderer.requiredOutputPaths(rendererVersions: [HerdrAdapter.id: 3])
        .contains(HerdrAdapter.outputPath)
    )
    #expect(
      try !ThemeRenderer.requiredOutputPaths(rendererVersions: [NeovimAdapter.id: 3])
        .contains(NeovimAdapter.outputPath)
    )
    #expect(
      try ThemeRenderer.requiredOutputPaths(rendererVersions: [NeovimAdapter.id: 4])
        .contains(NeovimAdapter.outputPath)
    )
    #expect(
      try !ThemeRenderer.requiredOutputPaths(rendererVersions: [:])
        .contains(SlackAdapter.outputPath)
    )
    #expect(
      try ThemeRenderer.requiredOutputPaths(rendererVersions: [SlackAdapter.id: 1])
        .contains(SlackAdapter.outputPath)
    )
    let legacyHerdr = try HerdrAdapter.decodeGeneratedTheme(
      Data("tokyo-night\n".utf8),
      rendererVersion: 2
    )
    #expect(legacyHerdr == GeneratedHerdrTheme(name: "tokyo-night"))
  }

  @Test
  func sealedGenerationArtifactValidationEnforcesInventoryAcrossVersionGates() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let base = try testActivator(root: root).activate(package: catppuccinPackage())
    let generationURL = root.appending(
      path: "generations/\(base.generationID)",
      directoryHint: .isDirectory
    )
    var nullDigestObject = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: generationURL.appending(path: "manifest.json"))
      ) as? [String: Any]
    )
    nullDigestObject["theme_digest"] = NSNull()
    let nullDigestData = try JSONSerialization.data(withJSONObject: nullDigestObject)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(GenerationManifest.self, from: nullDigestData)
    }

    func manifest(
      rendererVersions: [String: Int],
      artifacts: [String: String],
      themeDigest: String? = nil,
      background: GenerationBackground? = nil
    ) -> GenerationManifest {
      GenerationManifest(
        generationID: base.generationID,
        themeID: base.themeID,
        themeSchemaVersion: base.themeSchemaVersion,
        inputDigest: base.inputDigest,
        themeDigest: themeDigest ?? base.themeDigest,
        background: background ?? base.background,
        rendererVersions: rendererVersions,
        artifacts: artifacts
      )
    }

    var unknownArtifacts = base.artifacts
    unknownArtifacts["generated/unknown.txt"] = sha256Digest(Data())
    #expect(throws: GenerationIntegrityError.self) {
      try manifest(
        rendererVersions: base.rendererVersions,
        artifacts: unknownArtifacts
      ).validateArtifacts(at: generationURL)
    }

    var missingRequired = base.artifacts
    missingRequired.removeValue(forKey: ThemeRenderer.themeOutputPath)
    #expect(throws: GenerationIntegrityError.self) {
      try manifest(
        rendererVersions: base.rendererVersions,
        artifacts: missingRequired
      ).validateArtifacts(at: generationURL)
    }

    var missingSelectedWallpaper = base.artifacts
    missingSelectedWallpaper.removeValue(forKey: WallpaperAdapter.outputPath)
    #expect(throws: GenerationIntegrityError.self) {
      try manifest(
        rendererVersions: base.rendererVersions,
        artifacts: missingSelectedWallpaper
      ).validateArtifacts(at: generationURL)
    }

    let wrongFormat = manifest(
      rendererVersions: base.rendererVersions,
      artifacts: base.artifacts,
      background: GenerationBackground(id: "default", format: .jpeg)
    )
    #expect(throws: GenerationIntegrityError.self) {
      try wrongFormat.validateArtifacts(at: generationURL)
    }

    let invalidDigest = manifest(
      rendererVersions: base.rendererVersions,
      artifacts: base.artifacts,
      themeDigest: ""
    )
    #expect(throws: GenerationIntegrityError.self) {
      try invalidDigest.validateArtifacts(at: generationURL)
    }

    for currentGatedPath in [
      HerdrAdapter.outputPath,
      NeovimAdapter.outputPath,
      SlackAdapter.outputPath,
    ] {
      var missingCurrentGated = base.artifacts
      missingCurrentGated.removeValue(forKey: currentGatedPath)
      #expect(throws: GenerationIntegrityError.self) {
        try manifest(
          rendererVersions: base.rendererVersions,
          artifacts: missingCurrentGated
        ).validateArtifacts(at: generationURL)
      }
    }

    var omittedOptional = base.artifacts
    omittedOptional.removeValue(forKey: ThemeRenderer.capabilitiesOutputPath)
    try manifest(
      rendererVersions: base.rendererVersions,
      artifacts: omittedOptional
    ).validateArtifacts(at: generationURL)

    var legacyVersions = base.rendererVersions
    legacyVersions[HerdrAdapter.id] = 2
    legacyVersions[NeovimAdapter.id] = 3
    legacyVersions.removeValue(forKey: SlackAdapter.id)
    var omittedLegacyGated = base.artifacts
    omittedLegacyGated.removeValue(forKey: HerdrAdapter.outputPath)
    omittedLegacyGated.removeValue(forKey: NeovimAdapter.outputPath)
    omittedLegacyGated.removeValue(forKey: SlackAdapter.outputPath)
    try manifest(
      rendererVersions: legacyVersions,
      artifacts: omittedLegacyGated
    ).validateArtifacts(at: generationURL)
  }

  @Test
  func preparedBackgroundValidationPreservesOversizeErrorAndRejectsFormatMismatch() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let reachedOutputCheckpoint = Mutex(false)
    let activator = ThemeActivator(root: root) { checkpoint in
      if checkpoint == .outputsRendered {
        reachedOutputCheckpoint.withLock { $0 = true }
      }
    }
    let oversized = Data(count: WallpaperAsset.maximumSize + 1)

    #expect(
      throws: ThemeActivationError.generatedFileTooLarge(
        path: WallpaperAdapter.outputPath,
        size: oversized.count,
        maximumSize: WallpaperAsset.maximumSize
      )
    ) {
      _ = try activator.activate(
        package: catppuccinPackage(),
        expectedActiveGenerationID: nil,
        preparedBackground: {
          try preparedBackground(package: catppuccinPackage(), data: oversized)
        }
      )
    }
    #expect(reachedOutputCheckpoint.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "current").path))

    let package = try catppuccinPackage()
    #expect(throws: ThemeImageAssetError.mediaTypeMismatch) {
      _ = try activator.activate(
        package: package,
        expectedActiveGenerationID: nil,
        preparedBackground: {
          PreparedThemeBackground(
            selection: GenerationBackground(id: "default", format: .jpeg),
            data: package.defaultBackgroundData
          )
        }
      )
    }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "current").path))
  }

  @Test
  func activationCreatesCompleteGenerationAndReplacesCurrentWithRelativeSymlink() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let previousMarker = try installPreviousGeneration(at: root)
    let package = try catppuccinPackage()

    let activation = try testActivator(root: root).activate(package: package)

    let current = root.appending(path: "current")
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
    #expect(destination == "generations/\(activation.generationID)")
    #expect(try String(contentsOf: previousMarker, encoding: .utf8) == "previous\n")

    let generationURL = root.appending(
      path: "generations/\(activation.generationID)", directoryHint: .isDirectory)
    let manifest = try JSONDecoder().decode(
      GenerationManifest.self,
      from: Data(contentsOf: generationURL.appending(path: "manifest.json")))
    #expect(manifest.manifestSchemaVersion == GenerationManifest.currentSchemaVersion)
    #expect(manifest.generationID == activation.generationID)
    #expect(manifest.themeID == package.id)
    #expect(manifest.themeSchemaVersion == package.schemaVersion)
    #expect(manifest.inputDigest == activation.inputDigest)
    let rendered = try ThemeRenderer().render(
      package: package,
      generationID: activation.generationID
    )
    #expect(manifest.artifacts == rendered.manifestArtifacts)
    #expect(
      manifest.rendererVersions
        == [
          "atuin": 1, "bat": 1, "btop": 1, "capabilities": 1, "eza": 1, "herdr": 3,
          "kitty": 2,
          "neovim": 4, "normalized_theme": 1, "pi": 3, "sketchybar": 1,
          "slack": 1, "spicetify": 1, "starship": 1, "tuicr": 1, "wallpaper": 1,
          "yazi": 1,
        ]
    )
    #expect(manifest.inputDigest.hasPrefix("sha256:"))
    #expect(manifest.inputDigest.count == 71)
    #expect(
      Set(manifest.artifacts.keys)
        == [
          "generated/atuin.toml", "generated/bat.tmTheme", "generated/btop.theme",
          "generated/capabilities.json", "generated/eza.yml", "generated/herdr.txt",
          "generated/kitty.conf",
          "generated/neovim.lua", "generated/pi.json", "generated/sketchybar.lua",
          "generated/slack.txt", "generated/spicetify.ini", "generated/starship.toml",
          "generated/tuicr.toml", "generated/wallpaper.png", "generated/yazi-flavor.toml",
          "generated/yazi.tmTheme", "theme.json",
        ]
    )

    for (path, expectedDigest) in manifest.artifacts {
      #expect(expectedDigest == sha256(try Data(contentsOf: generationURL.appending(path: path))))
    }

    let normalizedData = try Data(contentsOf: current.appending(path: "theme.json"))
    let normalized = try JSONDecoder().decode(NormalizedTheme.self, from: normalizedData)
    #expect(normalized.themeID == package.id)
    #expect(normalized.generationID == manifest.generationID)

    for path in ["manifest.json"] + manifest.artifacts.keys.sorted() {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: generationURL.appending(path: path).path)
      let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
      #expect(permissions.intValue & 0o222 == 0)
    }
    for path in ["", "generated"] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: generationURL.appending(path: path).path)
      let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
      #expect(permissions.intValue & 0o222 == 0)
    }
  }

  @Test
  func activationGeneratesImportedHerdrAndNeovimPalettes() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let package = try packageWithoutNamedThemeMappings(at: root)

    let manifest = try testActivator(root: root).activate(package: package)
    let generation = root.appending(path: "generations/\(manifest.generationID)")
    let capabilities = try JSONDecoder().decode(
      GeneratedThemeCapabilities.self,
      from: Data(contentsOf: generation.appending(path: ThemeRenderer.capabilitiesOutputPath))
    )

    #expect(try capabilities.validated().unsupportedAdapters.isEmpty)
    let herdr = try JSONDecoder().decode(
      GeneratedHerdrTheme.self,
      from: Data(contentsOf: generation.appending(path: HerdrAdapter.outputPath))
    ).validated()
    #expect(herdr.name == "catppuccin")
    #expect(Set(herdr.custom.keys) == HerdrAdapter.customKeySet)
    let neovim = try String(
      contentsOf: generation.appending(path: NeovimAdapter.outputPath),
      encoding: .utf8
    )
    #expect(neovim.contains("colorscheme = \"\(NeovimAdapter.importedColorscheme)\""))
    #expect(neovim.contains("theme_id = \"\(package.id)\""))
    #expect(neovim.contains("accent = \"\(package.semantic.accent.rawValue)\""))
    #expect(
      try Set(manifest.artifacts.keys).isSuperset(
        of: ThemeRenderer.requiredOutputPaths(rendererVersions: manifest.rendererVersions)
      )
    )
    #expect(
      try ReconciliationStatusStore(root: root).activeManifest().generationID
        == manifest.generationID)
  }

  @Test
  func committedThemeIsPublishedAfterUnlockAndCanBeReopened() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let publication = Mutex<Result<ThemePublication, PublicationTestError>?>(nil)
    let darwinHint = Mutex<Result<DarwinHint, PublicationTestError>?>(nil)
    let activator = ThemeActivator(
      root: root,
      faultInjector: { _ in },
      onThemeChanged: { event in
        do {
          let data = try Data(contentsOf: root.appending(path: "current/theme.json"))
          let theme = try JSONDecoder().decode(NormalizedTheme.self, from: data)
          let activationLockWasAvailable = try externalProcessCanAcquireLock(at: root)
          publication.withLock {
            $0 = .success(
              ThemePublication(
                event: event,
                reopenedGenerationID: theme.generationID,
                reopenedThemeID: theme.themeID,
                activationLockWasAvailable: activationLockWasAvailable
              )
            )
          }
        } catch {
          publication.withLock { $0 = .failure(.failed(String(describing: error))) }
        }
      },
      postDarwinNotification: { name in
        do {
          try darwinHint.withLock {
            $0 = .success(
              DarwinHint(
                name: name,
                activationLockWasAvailable: try externalProcessCanAcquireLock(at: root),
                currentExists: FileManager.default.fileExists(
                  atPath: root.appending(path: "current/theme.json").path)
              )
            )
          }
        } catch {
          darwinHint.withLock { $0 = .failure(.failed(String(describing: error))) }
        }
      }
    )

    let manifest = try activator.activate(package: catppuccinPackage())
    let observed = try #require(publication.withLock { $0 }).get()
    #expect(observed.event.generationID == manifest.generationID)
    #expect(observed.event.themeID == manifest.themeID)
    #expect(observed.reopenedGenerationID == manifest.generationID)
    #expect(observed.reopenedThemeID == manifest.themeID)
    #expect(observed.activationLockWasAvailable)
    let hint = try #require(darwinHint.withLock { $0 }).get()
    #expect(hint.name == ThemeChanged.darwinNotificationName)
    #expect(hint.activationLockWasAvailable)
    #expect(hint.currentExists)
  }

  @Test
  func everyPreReplacementFaultPreservesPreviousCanonicalGeneration() throws {
    let package = try catppuccinPackage()
    let checkpoints: [ActivationCheckpoint] = [
      .inputDigested,
      .outputsRendered,
      .generationWritten,
      .generationSealed,
      .generationCommitted,
      .currentPointerReady,
    ]
    for checkpoint in checkpoints {
      let root = try temporaryDirectory()
      defer {
        makeWritableForRemoval(root)
        try? FileManager.default.removeItem(at: root)
      }
      let previousMarker = try installPreviousGeneration(at: root)
      let publicationCounts = Mutex((typed: 0, darwin: 0))
      let activator = ThemeActivator(
        root: root,
        faultInjector: { reached in
          if reached == checkpoint { throw InjectedFault.expected }
        },
        onThemeChanged: { _ in publicationCounts.withLock { $0.typed += 1 } },
        postDarwinNotification: { _ in publicationCounts.withLock { $0.darwin += 1 } }
      )

      #expect(throws: InjectedFault.self) {
        _ = try activator.activate(package: package)
      }

      let current = root.appending(path: "current")
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
          == "generations/previous")
      #expect(try String(contentsOf: previousMarker, encoding: .utf8) == "previous\n")

      let rootChildren = try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
      #expect(!rootChildren.contains { $0.lastPathComponent.hasPrefix(".current-") })
      let generationChildren = try FileManager.default.contentsOfDirectory(
        at: root.appending(path: "generations"), includingPropertiesForKeys: nil)
      #expect(!generationChildren.contains { $0.lastPathComponent.hasPrefix(".staging-") })
      #expect(publicationCounts.withLock { $0.typed } == 0)
      #expect(publicationCounts.withLock { $0.darwin } == 0)

      let recovered = try testActivator(root: root).activate(package: package)
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
          == "generations/\(recovered.generationID)"
      )
    }
  }

  @Test
  func everyPostcommitActivationFaultLeavesRecoverableCanonicalState() async throws {
    let package = try tokyoNightPackage()
    for checkpoint in [
      ActivationCheckpoint.currentReplaced,
      .generationsCleaned,
      .changePublished,
    ] {
      let root = try temporaryDirectory()
      defer {
        makeWritableForRemoval(root)
        try? FileManager.default.removeItem(at: root)
      }
      let previous = try testActivator(root: root).activate(package: catppuccinPackage())
      let store = ReconciliationStatusStore(root: root)
      _ = try store.persist(
        manifest: previous,
        results: [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
      )
      let publications = Mutex((typed: 0, darwin: 0))
      let activator = ThemeActivator(
        root: root,
        faultInjector: { reached in
          if reached == checkpoint { throw InjectedFault.expected }
        },
        onThemeChanged: { _ in publications.withLock { $0.typed += 1 } },
        postDarwinNotification: { _ in publications.withLock { $0.darwin += 1 } }
      )

      let committed: ThemeCommittedActivationError
      do {
        _ = try activator.activate(package: package)
        throw TestError.expectedCommittedError
      } catch let error as ThemeCommittedActivationError {
        committed = error
      }

      #expect(try store.activeManifest().generationID == committed.manifest.generationID)
      guard case .stale(let activeGenerationID, let stale) = try store.read() else {
        throw TestError.expectedStaleStatus
      }
      #expect(activeGenerationID == committed.manifest.generationID)
      #expect(stale.generationID == previous.generationID)
      let expectedPublicationCount = checkpoint == .currentReplaced ? 0 : 1
      #expect(publications.withLock { $0.typed } == expectedPublicationCount)
      #expect(publications.withLock { $0.darwin } == expectedPublicationCount)
      #expect(try transactionResidue(at: root).isEmpty)

      let recovered = try await ThemeReconciler(statusStore: store).reconcile(
        manifest: committed.manifest,
        adapters: [
          AdapterReconciliation(id: "kitty", requirement: .required) {
            AdapterOutcome(status: .applied)
          }
        ]
      )
      #expect(try store.read() == .current(recovered))
    }
  }

  @Test
  func recoveryAndCleanupDoNotFollowPrefixMatchingSymlinks() throws {
    let root = try temporaryDirectory()
    let external = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
      makeWritableForRemoval(external)
      try? FileManager.default.removeItem(at: external)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    try FileManager.default.setAttributes([.posixPermissions: 0o711], ofItemAtPath: external.path)
    let generationsRoot = root.appending(path: "generations", directoryHint: .isDirectory)
    let stagingLink = generationsRoot.appending(
      path: ".staging-g-\(UUID().uuidString.lowercased())"
    )
    let generationLink = generationsRoot.appending(
      path: "g-\(UUID().uuidString.lowercased())"
    )
    for link in [stagingLink, generationLink] {
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    }
    let pointerLookalike = root.appending(
      path: ".current-g-\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())"
    )
    try Data().write(to: pointerLookalike)

    _ = try testActivator(root: root).activate(package: tokyoNightPackage())

    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: stagingLink.path) == external.path
    )
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: generationLink.path)
        == external.path
    )
    #expect(FileManager.default.fileExists(atPath: pointerLookalike.path))
    let permissions = try #require(
      FileManager.default.attributesOfItem(atPath: external.path)[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue == 0o711)
  }

  @Test
  func processDeathBeforeAndAfterPointerReplacementLeavesRecoverableState() async throws {
    let precommitRoot = try temporaryDirectory()
    defer {
      makeWritableForRemoval(precommitRoot)
      try? FileManager.default.removeItem(at: precommitRoot)
    }
    let original = try testActivator(root: precommitRoot).activate(package: catppuccinPackage())

    try runCrashProbe(root: precommitRoot, checkpoint: "generationWritten")

    #expect(
      try ReconciliationStatusStore(root: precommitRoot).activeManifest().generationID
        == original.generationID)
    #expect(try !transactionResidue(at: precommitRoot).isEmpty)
    #expect(try externalProcessCanAcquireLock(at: precommitRoot))
    let pointer = precommitRoot.appending(
      path: ".current-g-\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())"
    )
    try FileManager.default.createSymbolicLink(
      at: pointer,
      withDestinationURL: precommitRoot.appending(path: "generations/missing")
    )
    let trash = precommitRoot.appending(
      path:
        "generations/.trash-g-\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: trash.path)
    let recoveredActivation = try testActivator(root: precommitRoot).activate(
      package: tokyoNightPackage()
    )
    #expect(try transactionResidue(at: precommitRoot).isEmpty)
    #expect(
      try ReconciliationStatusStore(root: precommitRoot).activeManifest().generationID
        == recoveredActivation.generationID)

    let postcommitRoot = try temporaryDirectory()
    defer {
      makeWritableForRemoval(postcommitRoot)
      try? FileManager.default.removeItem(at: postcommitRoot)
    }
    let previous = try testActivator(root: postcommitRoot).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: postcommitRoot)
    _ = try store.persist(
      manifest: previous,
      results: [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
    )

    try runCrashProbe(root: postcommitRoot, checkpoint: "currentReplaced")

    let committed = try store.activeManifest()
    #expect(committed.themeID == "tokyo-night")
    guard case .stale(let activeGenerationID, let stale) = try store.read() else {
      throw TestError.expectedStaleStatus
    }
    #expect(activeGenerationID == committed.generationID)
    #expect(stale.generationID == previous.generationID)
    #expect(try externalProcessCanAcquireLock(at: postcommitRoot))

    let recoveredStatus = try await ThemeReconciler(statusStore: store).reconcile(
      manifest: committed,
      adapters: [
        AdapterReconciliation(id: "kitty", requirement: .required) {
          AdapterOutcome(status: .applied)
        }
      ]
    )
    #expect(try store.read() == .current(recoveredStatus))
    _ = try testActivator(root: postcommitRoot).activate(package: catppuccinPackage())
  }

  @Test
  func generationCleanupRetainsOnlyCurrentAndPreviousReusableEvidence() throws {
    let fixtureRoot = try temporaryDirectory()
    defer {
      makeWritableForRemoval(fixtureRoot)
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    let packages = try distinctCatppuccinPackages(at: fixtureRoot)
    let stateRoot = fixtureRoot.appending(path: "state", directoryHint: .isDirectory)
    let first = try testActivator(root: stateRoot).activate(package: packages[0])
    let second = try testActivator(root: stateRoot).activate(package: packages[1])
    let third = try testActivator(root: stateRoot).activate(package: packages[2])

    #expect(try generationIDs(at: stateRoot) == [second.generationID, third.generationID].sorted())
    #expect(
      !FileManager.default.fileExists(
        atPath: stateRoot.appending(path: "generations/\(first.generationID)").path
      ))

    let reuseOnly = ThemeActivator(root: stateRoot) { checkpoint in
      if checkpoint == .outputsRendered { throw InjectedFault.expected }
    }
    let reused = try reuseOnly.activate(package: packages[1])
    #expect(reused.generationID == second.generationID)
    _ = try reuseOnly.activate(package: packages[1])
    #expect(try generationIDs(at: stateRoot) == [second.generationID, third.generationID].sorted())
    #expect(
      try ReconciliationStatusStore(root: stateRoot).activeManifest().generationID
        == second.generationID)
  }

  @Test
  func cleanupFailureIsReportedAfterCommitAndPublication() throws {
    let fixtureRoot = try temporaryDirectory()
    defer {
      makeWritableForRemoval(fixtureRoot)
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    let packages = try distinctCatppuccinPackages(at: fixtureRoot)
    let stateRoot = fixtureRoot.appending(path: "state", directoryHint: .isDirectory)
    let first = try testActivator(root: stateRoot).activate(package: packages[0])
    _ = try testActivator(root: stateRoot).activate(package: packages[1])
    let protectedArtifact = stateRoot.appending(
      path: "generations/\(first.generationID)/theme.json"
    )
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: protectedArtifact.path)
    defer {
      try? FileManager.default.setAttributes(
        [.immutable: false],
        ofItemAtPath: protectedArtifact.path
      )
      if let trash = try? FileManager.default.contentsOfDirectory(
        at: stateRoot.appending(path: "generations"),
        includingPropertiesForKeys: nil
      ).first(where: { $0.lastPathComponent.hasPrefix(".trash-") }) {
        try? FileManager.default.setAttributes(
          [.immutable: false],
          ofItemAtPath: trash.appending(path: "theme.json").path
        )
      }
    }
    let publications = Mutex((typed: 0, darwin: 0))
    let activator = ThemeActivator(
      root: stateRoot,
      faultInjector: { _ in },
      onThemeChanged: { _ in publications.withLock { $0.typed += 1 } },
      postDarwinNotification: { _ in publications.withLock { $0.darwin += 1 } }
    )

    let error: ThemeCommittedActivationError
    do {
      _ = try activator.activate(package: packages[2])
      throw TestError.expectedCommittedError
    } catch let committed as ThemeCommittedActivationError {
      error = committed
    }
    #expect(
      try ReconciliationStatusStore(root: stateRoot).activeManifest().generationID
        == error.manifest.generationID)
    #expect(publications.withLock { $0.typed } == 1)
    #expect(publications.withLock { $0.darwin } == 1)
    #expect(try generationIDs(at: stateRoot).count == 2)
  }

  @Test
  func concurrentEquivalentActivationsRenderOneGeneration() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let package = try catppuccinPackage()
    let firstActivationEntered = DispatchSemaphore(value: 0)
    let secondActivationEntered = DispatchSemaphore(value: 0)
    let releaseFirstActivation = DispatchSemaphore(value: 0)
    defer { releaseFirstActivation.signal() }
    let state = Mutex(ConcurrentActivationState())
    let activator = ThemeActivator(root: root) { checkpoint in
      switch checkpoint {
      case .inputDigested:
        let shouldWait = state.withLock { state in
          state.inputDigestCount += 1
          return state.inputDigestCount == 1
        }
        if shouldWait {
          firstActivationEntered.signal()
          releaseFirstActivation.wait()
        } else {
          secondActivationEntered.signal()
        }
      case .outputsRendered:
        state.withLock { $0.renderCount += 1 }
      default:
        break
      }
    }

    let group = DispatchGroup()
    let callersReady = DispatchSemaphore(value: 0)
    let startCallers = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
    for start in startCallers {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        callersReady.signal()
        start.wait()
        do {
          let manifest = try activator.activate(package: package)
          state.withLock { $0.generationIDs.append(manifest.generationID) }
        } catch {
          state.withLock { $0.errors.append(String(describing: error)) }
        }
      }
    }

    guard callersReady.wait(timeout: .now() + .seconds(2)) == .success,
      callersReady.wait(timeout: .now() + .seconds(2)) == .success
    else { throw TestError.timedOut }
    startCallers[0].signal()
    guard firstActivationEntered.wait(timeout: .now() + .seconds(2)) == .success else {
      throw TestError.timedOut
    }
    startCallers[1].signal()
    #expect(secondActivationEntered.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
    releaseFirstActivation.signal()
    guard secondActivationEntered.wait(timeout: .now() + .seconds(2)) == .success else {
      throw TestError.timedOut
    }
    guard group.wait(timeout: .now() + .seconds(2)) == .success else {
      throw TestError.timedOut
    }

    let result = state.withLock { $0 }
    #expect(result.errors.isEmpty)
    #expect(result.inputDigestCount == 2)
    #expect(result.renderCount == 1)
    #expect(Set(result.generationIDs).count == 1)
    #expect(try generationIDs(at: root).count == 1)
  }

  @Test
  func conditionalActivationRejectsASupersededGenerationBeforeWork() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let requested = try catppuccinPackage()
    let original = try testActivator(root: root).activate(package: requested)
    let active = try testActivator(root: root).activate(package: tokyoNightPackage())
    let conditional = ThemeActivator(
      root: root,
      faultInjector: { _ in
        Issue.record("A failed generation condition must stop before activation work")
      }
    )

    #expect(
      throws: ThemeActivationError.activeGenerationChanged(
        expected: original.generationID,
        active: active.generationID
      )
    ) {
      _ = try conditional.activate(
        package: requested,
        expectedActiveGenerationID: original.generationID,
        preparedBackground: {
          try preparedBackground(package: requested, data: requested.defaultBackgroundData)
        }
      )
    }
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: "current").path
      ) == "generations/\(active.generationID)"
    )
  }

  @Test
  func crossProcessLockIsHeldAcrossActivationAndReleasedAfterFailure() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let activationEntered = DispatchSemaphore(value: 0)
    let releaseActivation = DispatchSemaphore(value: 0)
    defer { releaseActivation.signal() }
    let completion = DispatchSemaphore(value: 0)
    let outcome = Mutex<String?>(nil)
    let package = try catppuccinPackage()
    let activator = ThemeActivator(root: root) { checkpoint in
      if checkpoint == .inputDigested {
        activationEntered.signal()
        releaseActivation.wait()
      }
    }
    DispatchQueue.global().async {
      defer { completion.signal() }
      do {
        _ = try activator.activate(package: package)
      } catch {
        outcome.withLock { $0 = String(describing: error) }
      }
    }

    guard activationEntered.wait(timeout: .now() + .seconds(2)) == .success else {
      throw TestError.timedOut
    }
    #expect(try !externalProcessCanAcquireLock(at: root))
    releaseActivation.signal()
    guard completion.wait(timeout: .now() + .seconds(2)) == .success else {
      throw TestError.timedOut
    }
    #expect(outcome.withLock { $0 } == nil)
    #expect(try externalProcessCanAcquireLock(at: root))

    let failingActivator = ThemeActivator(root: root) { checkpoint in
      if checkpoint == .inputDigested { throw InjectedFault.expected }
    }
    #expect(throws: InjectedFault.self) {
      _ = try failingActivator.activate(package: package)
    }
    #expect(try externalProcessCanAcquireLock(at: root))
  }

  @Test
  func activationContinuesAfterLockHolderIsTerminated() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let lockPath = runDirectory.appending(path: "activation.lock").path
    FileManager.default.createFile(atPath: lockPath, contents: nil)

    let lockHolder = Process()
    let output = Pipe()
    lockHolder.executableURL = URL(filePath: "/usr/bin/python3")
    lockHolder.arguments = [
      "-c",
      "import fcntl, os, sys, time; f = open(sys.argv[1], 'r+'); fcntl.lockf(f, fcntl.LOCK_EX); os.write(1, b'1'); time.sleep(60)",
      lockPath,
    ]
    lockHolder.standardOutput = output
    lockHolder.standardError = output
    try lockHolder.run()
    defer {
      if lockHolder.isRunning {
        lockHolder.terminate()
        lockHolder.waitUntilExit()
      }
    }
    guard try output.fileHandleForReading.read(upToCount: 1) == Data("1".utf8) else {
      throw TestError.lockHolderDidNotStart
    }
    #expect(try !externalProcessCanAcquireLock(at: root))

    let activationAttempted = DispatchSemaphore(value: 0)
    let activationCompleted = DispatchSemaphore(value: 0)
    let outcome = Mutex<String?>(nil)
    let package = try catppuccinPackage()
    DispatchQueue.global().async {
      activationAttempted.signal()
      defer { activationCompleted.signal() }
      do {
        _ = try testActivator(root: root).activate(package: package)
      } catch {
        outcome.withLock { $0 = String(describing: error) }
      }
    }
    guard activationAttempted.wait(timeout: .now() + .seconds(2)) == .success else {
      throw TestError.timedOut
    }
    #expect(activationCompleted.wait(timeout: .now() + .milliseconds(100)) == .timedOut)

    lockHolder.terminate()
    lockHolder.waitUntilExit()

    guard activationCompleted.wait(timeout: .now() + .seconds(2)) == .success else {
      throw TestError.timedOut
    }
    #expect(outcome.withLock { $0 } == nil)
    #expect(try generationIDs(at: root).count == 1)
  }

  @Test
  func inputDigestUsesValidatedContentRatherThanSourceFormatting() throws {
    let fixtureRoot = try temporaryDirectory()
    defer {
      makeWritableForRemoval(fixtureRoot)
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    let source = repositoryRoot.appending(
      path: "Themes/catppuccin-mocha", directoryHint: .isDirectory)
    let equivalentURL = fixtureRoot.appending(path: "equivalent", directoryHint: .isDirectory)
    let changedURL = fixtureRoot.appending(path: "changed", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: equivalentURL)
    try FileManager.default.copyItem(at: source, to: changedURL)

    for file in ["theme.toml", "mappings.toml"] {
      let url = equivalentURL.appending(path: file)
      let original = try String(contentsOf: url, encoding: .utf8)
      try ("# Equivalent source comment\n" + original).write(
        to: url, atomically: true, encoding: .utf8)
    }
    let changedMappings = changedURL.appending(path: "mappings.toml")
    let originalMappings = try String(contentsOf: changedMappings, encoding: .utf8)
    try originalMappings.replacingOccurrences(
      of: "neovim = \"catppuccin-mocha\"", with: "neovim = \"catppuccin-mocha-updated\""
    ).write(to: changedMappings, atomically: true, encoding: .utf8)

    let stateRoot = fixtureRoot.appending(path: "state", directoryHint: .isDirectory)
    let originalManifest = try testActivator(root: stateRoot).activate(
      package: catppuccinPackage())
    let reuseOnly = ThemeActivator(root: stateRoot) { checkpoint in
      if checkpoint == .outputsRendered { throw InjectedFault.expected }
    }
    let equivalentManifest = try reuseOnly.activate(
      package: ThemePackageLoader().load(packageURL: equivalentURL))
    let changedManifest = try testActivator(root: stateRoot).activate(
      package: ThemePackageLoader().load(packageURL: changedURL))
    let overrideManifest = try testActivator(root: stateRoot).activate(
      package: catppuccinPackage(),
      expectedActiveGenerationID: nil,
      preparedBackground: {
        try preparedBackground(
          package: catppuccinPackage(),
          data: tokyoNightPackage().defaultBackgroundData
        )
      }
    )

    #expect(originalManifest.inputDigest == equivalentManifest.inputDigest)
    #expect(originalManifest.generationID == equivalentManifest.generationID)
    #expect(originalManifest.themeDigest == equivalentManifest.themeDigest)
    #expect(originalManifest.inputDigest != changedManifest.inputDigest)
    #expect(originalManifest.generationID != changedManifest.generationID)
    #expect(originalManifest.themeDigest != changedManifest.themeDigest)
    #expect(originalManifest.inputDigest != overrideManifest.inputDigest)
    #expect(originalManifest.themeDigest == overrideManifest.themeDigest)
    #expect(
      try Data(
        contentsOf: stateRoot.appending(
          path: "generations/\(overrideManifest.generationID)/generated/wallpaper.png"
        )
      )
        == tokyoNightPackage().defaultBackgroundData
    )
  }

  @Test
  func repeatedActivationAndRoundTripsReuseWithoutRendering() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let catppuccin = try catppuccinPackage()
    let tokyoNight = try tokyoNightPackage()

    let firstCatppuccin = try testActivator(root: root).activate(package: catppuccin)
    let stalePointer = root.appending(path: ".current-\(firstCatppuccin.generationID)")
    try FileManager.default.createSymbolicLink(
      atPath: stalePointer.path,
      withDestinationPath: "generations/\(firstCatppuccin.generationID)"
    )
    let publications = Mutex((generationIDs: [String](), darwinNames: [String]()))
    let reuseOnly = ThemeActivator(
      root: root,
      faultInjector: { checkpoint in
        if checkpoint == .outputsRendered { throw InjectedFault.expected }
      },
      onThemeChanged: { event in
        publications.withLock { $0.generationIDs.append(event.generationID) }
      },
      postDarwinNotification: { name in
        publications.withLock { $0.darwinNames.append(name) }
      }
    )
    let repeatedCatppuccin = try reuseOnly.activate(package: catppuccin)
    #expect(repeatedCatppuccin.generationID == firstCatppuccin.generationID)
    #expect(FileManager.default.fileExists(atPath: stalePointer.path))

    let tokyo = try testActivator(root: root).activate(package: tokyoNight)
    #expect(tokyo.generationID != firstCatppuccin.generationID)

    let failBeforePointer = ThemeActivator(root: root) { checkpoint in
      if checkpoint == .currentPointerReady { throw InjectedFault.expected }
    }
    #expect(throws: InjectedFault.self) {
      _ = try failBeforePointer.activate(package: catppuccin)
    }
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: "current").path
      ) == "generations/\(tokyo.generationID)"
    )

    let roundTripCatppuccin = try reuseOnly.activate(package: catppuccin)
    #expect(roundTripCatppuccin.generationID == firstCatppuccin.generationID)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: "current").path
      ) == "generations/\(firstCatppuccin.generationID)"
    )
    #expect(try generationIDs(at: root).count == 2)
    #expect(
      publications.withLock { $0.generationIDs }
        == [firstCatppuccin.generationID, firstCatppuccin.generationID]
    )
    #expect(
      publications.withLock { $0.darwinNames }
        == [ThemeChanged.darwinNotificationName, ThemeChanged.darwinNotificationName]
    )
  }

  @Test
  func corruptMatchingGenerationFailsWithoutChangingCurrent() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let catppuccin = try catppuccinPackage()
    let catppuccinGeneration = try testActivator(root: root).activate(package: catppuccin)
    let tokyoGeneration = try testActivator(root: root).activate(package: tokyoNightPackage())

    let corruptedTheme = root.appending(
      path: "generations/\(catppuccinGeneration.generationID)/theme.json")
    try overwriteReadOnlyFile(corruptedTheme, with: Data("corrupt\n".utf8))

    let error = try activationError {
      _ = try testActivator(root: root).activate(package: catppuccin)
    }
    guard case .corruptGeneration(let id, let reason) = error else {
      throw TestError.expectedCorruptGeneration
    }
    #expect(id == catppuccinGeneration.generationID)
    #expect(reason == "artifact digest does not match theme.json")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: "current").path
      ) == "generations/\(tokyoGeneration.generationID)"
    )
    #expect(try generationIDs(at: root).count == 2)
  }

  @Test
  func unknownMatchingManifestFieldFailsWithoutRendering() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let catppuccin = try catppuccinPackage()
    let catppuccinGeneration = try testActivator(root: root).activate(package: catppuccin)
    let tokyoGeneration = try testActivator(root: root).activate(package: tokyoNightPackage())

    let manifestURL = root.appending(
      path: "generations/\(catppuccinGeneration.generationID)/manifest.json")
    let manifestData = try Data(contentsOf: manifestURL)
    var manifestObject = try #require(
      JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    manifestObject["unexpected"] = true
    var invalidManifest = try JSONSerialization.data(
      withJSONObject: manifestObject, options: [.prettyPrinted, .sortedKeys])
    invalidManifest.append(0x0a)
    try overwriteReadOnlyFile(manifestURL, with: invalidManifest)

    let noRender = ThemeActivator(root: root) { checkpoint in
      if checkpoint == .outputsRendered { throw InjectedFault.expected }
    }
    let error = try activationError {
      _ = try noRender.activate(package: catppuccin)
    }
    guard case .corruptGeneration(let id, let reason) = error else {
      throw TestError.expectedCorruptGeneration
    }
    #expect(id == catppuccinGeneration.generationID)
    #expect(reason == "manifest.json contains unknown or missing fields")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: "current").path
      ) == "generations/\(tokyoGeneration.generationID)"
    )
    #expect(try generationIDs(at: root).count == 2)
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
        path: "Themes/catppuccin-mocha", directoryHint: .isDirectory))
  }

  private func tokyoNightPackage() throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/tokyo-night", directoryHint: .isDirectory))
  }

  private func testActivator(root: URL) -> ThemeActivator {
    ThemeActivator(root: root, faultInjector: { _ in })
  }

  private func preparedBackground(
    package: ThemePackage,
    data: Data
  ) throws -> PreparedThemeBackground {
    let background = try #require(package.backgrounds.first)
    return PreparedThemeBackground(
      selection: GenerationBackground(id: background.id, format: background.format),
      data: data
    )
  }

  private func installPreviousGeneration(at root: URL) throws -> URL {
    let previous = root.appending(path: "generations/previous", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    let marker = previous.appending(path: "marker.txt")
    try "previous\n".write(to: marker, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: root.appending(path: "current").path,
      withDestinationPath: "generations/previous"
    )
    return marker
  }

  private func generationIDs(at root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      at: root.appending(path: "generations"), includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).map(\.lastPathComponent).filter { $0.hasPrefix("g-") }.sorted()
  }

  private func transactionResidue(at root: URL) throws -> [URL] {
    let pointers = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".current-g-") }
    let generationsRoot = root.appending(path: "generations", directoryHint: .isDirectory)
    let staging = try FileManager.default.contentsOfDirectory(
      at: generationsRoot,
      includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasPrefix(".staging-g-")
        || $0.lastPathComponent.hasPrefix(".trash-g-")
    }
    return pointers + staging
  }

  private func distinctCatppuccinPackages(at root: URL) throws -> [ThemePackage] {
    let source = repositoryRoot.appending(
      path: "Themes/catppuccin-mocha",
      directoryHint: .isDirectory
    )
    return try (0..<3).map { index in
      let destination = root.appending(path: "package-\(index)", directoryHint: .isDirectory)
      try FileManager.default.copyItem(at: source, to: destination)
      let mappingsURL = destination.appending(path: "mappings.toml")
      let mappings = try String(contentsOf: mappingsURL, encoding: .utf8)
      try mappings.replacingOccurrences(
        of: "neovim = \"catppuccin-mocha\"",
        with: "neovim = \"catppuccin-mocha-\(index)\""
      ).write(to: mappingsURL, atomically: true, encoding: .utf8)
      return try ThemePackageLoader().load(packageURL: destination)
    }
  }

  private func packageWithoutNamedThemeMappings(at root: URL) throws -> ThemePackage {
    let source = repositoryRoot.appending(
      path: "Themes/catppuccin-mocha",
      directoryHint: .isDirectory
    )
    let destination = root.appending(path: "imported-package", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: destination)
    try "schema_version = 1\n\n[mappings]\n".write(
      to: destination.appending(path: "mappings.toml"),
      atomically: true,
      encoding: .utf8
    )
    return try ThemePackageLoader().load(packageURL: destination)
  }

  private func activationError(from operation: () throws -> Void) throws -> ThemeActivationError {
    do {
      try operation()
    } catch let error as ThemeActivationError {
      return error
    }
    throw TestError.expectedActivationError
  }

  private func overwriteReadOnlyFile(_ url: URL, with data: Data) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
    try handle.close()
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
  }

  private func sha256(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func externalProcessCanAcquireLock(at root: URL) throws -> Bool {
    let probe = Process()
    probe.executableURL = URL(filePath: "/usr/bin/python3")
    probe.arguments = [
      "-c",
      """
      import fcntl, sys
      lock = open(sys.argv[1], 'r+')
      try:
          fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
      except BlockingIOError:
          sys.exit(75)
      """,
      root.appending(path: "run/activation.lock").path,
    ]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    try probe.run()
    probe.waitUntilExit()
    switch probe.terminationStatus {
    case 0:
      return true
    case 75:
      return false
    default:
      throw TestError.lockProbeFailed(probe.terminationStatus)
    }
  }

  private func runCrashProbe(root: URL, checkpoint: String) throws {
    let process = Process()
    process.executableURL = repositoryRoot.appending(
      path: ".build/debug/theme-activation-crash-probe"
    )
    process.arguments = [
      root.path,
      checkpoint,
      repositoryRoot.appending(path: "Themes/tokyo-night").path,
    ]
    process.currentDirectoryURL = repositoryRoot
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 86)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(
        path: "macarchy-activation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeWritableForRemoval(_ root: URL) {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])
    else { return }
    var directories = [root]
    for case let item as URL in enumerator {
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(item)
      }
    }
    for directory in directories.reversed() {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
  }

  private enum InjectedFault: Error {
    case expected
  }

  private enum TestError: Error {
    case expectedActivationError
    case expectedCommittedError
    case expectedCorruptGeneration
    case expectedStaleStatus
    case lockHolderDidNotStart
    case lockProbeFailed(Int32)
    case timedOut
  }
}

private struct ConcurrentActivationState: Sendable {
  var inputDigestCount = 0
  var renderCount = 0
  var generationIDs: [String] = []
  var errors: [String] = []
}

private struct ThemePublication: Sendable {
  let event: ThemeChanged
  let reopenedGenerationID: String
  let reopenedThemeID: String
  let activationLockWasAvailable: Bool
}

private struct DarwinHint: Sendable {
  let name: String
  let activationLockWasAvailable: Bool
  let currentExists: Bool
}

private enum PublicationTestError: Error, Sendable {
  case failed(String)
}
