import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeBrowserTests {
  @Test
  func loaderShowsEveryThemeAndUsesCanonicalAndRememberedSelections() throws {
    let packages = try repository.packages()
    let activePackage = try #require(packages.first(where: { $0.id == "kanagawa-wave" }))
    let activeBackground = try #require(activePackage.backgrounds.first)
    let loader = ThemeBrowserCommandLoader(
      loadPackages: { _ in packages },
      loadPreferences: { _ in
        ["tokyo-night": "default", "kanagawa-wave": "removed-background"]
      },
      loadActiveManifest: { _ in
        manifest(
          themeID: activePackage.id,
          background: GenerationBackground(id: activeBackground.id, format: activeBackground.format)
        )
      },
      loadWallpaperOverrides: { _, _ in [:] },
      renderPreview: { ThemePreviewRenderer().render(package: $0) }
    )

    let content = try loader.load(
      repository: repository,
      stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory)
    )

    #expect(content.items.map(\.id) == packages.map(\.id))
    #expect(content.initialThemeID == "kanagawa-wave")
    #expect(content.item(id: "kanagawa-wave")?.initialBackgroundID == activeBackground.id)
    #expect(content.item(id: "tokyo-night")?.initialBackgroundID == "default")
    #expect(content.filteredItems(query: "TOKYO dark").map(\.id) == ["tokyo-night"])
    for item in content.items {
      #expect(!item.generatedPreview.data.isEmpty)
    }
  }

  @Test
  func navigationChangesOnlyLocalSelectionAndBackgroundsWrap() throws {
    let base = try repository.package(id: "catppuccin-mocha")
    let first = try #require(base.backgrounds.first)
    let second = ThemeBackground(
      id: "second",
      path: "wallpapers/second.png",
      source: first.source,
      author: first.author,
      license: first.license,
      format: .png
    )
    let package = ThemePackage(
      packageURL: base.packageURL,
      schemaVersion: base.schemaVersion,
      id: base.id,
      displayName: base.displayName,
      appearance: base.appearance,
      semantic: base.semantic,
      terminal: base.terminal,
      backgrounds: [first, second],
      backgroundData: [first.id: base.data(for: first), second.id: base.data(for: first)],
      mappings: base.mappings
    )
    let item = ThemeBrowserItem(
      package: package,
      generatedPreview: ThemeBrowserPreview(
        label: "Generated palette",
        data: ThemePreviewRenderer().render(package: package).data
      ),
      initialBackgroundID: first.id,
      wallpaperOverrideData: nil
    )
    var state = ThemeBrowserState(
      content: ThemeBrowserContent(items: [item], initialThemeID: item.id)
    )

    #expect(state.selection == ThemeBrowserSelection(themeID: item.id, backgroundID: first.id))
    state.moveBackground(by: 1)
    #expect(state.selection.backgroundID == second.id)
    state.moveBackground(by: 1)
    #expect(state.selection.backgroundID == first.id)
    state.updateSearch("no match")
    #expect(state.visibleItems.isEmpty)
    #expect(state.selection.themeID == item.id)
  }

  @Test
  func importedGalleriesRemainLazyUntilTheSelectedThemeRequestsThem() throws {
    let calls = Mutex(0)
    let package = try repository.package(id: "catppuccin-mocha")
    let content = try ThemeBrowserCommandLoader(
      loadPackages: { _ in [package] },
      loadPreferences: { _ in [:] },
      loadActiveManifest: { _ in nil },
      loadWallpaperOverrides: { _, _ in [:] },
      renderPreview: { ThemePreviewRenderer().render(package: $0) }
    ).load(
      repository: repository,
      stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory)
    )
    #expect(calls.withLock { $0 } == 0)

    let gallery = ThemeBrowserGalleryLoader(loadAssets: { _ in
      calls.withLock { $0 += 1 }
      return []
    })
    let item = try #require(content.items.first)
    #expect(try gallery.load(item: item).isEmpty)
    #expect(calls.withLock { $0 } == 1)
  }

  @Test
  func loaderPreviewsTheEffectivePersonalWallpaperOverride() throws {
    let package = try repository.package(id: "catppuccin-mocha")
    let override = Data("personal-samurai-wallpaper".utf8)
    let content = try ThemeBrowserCommandLoader(
      loadPackages: { _ in [package] },
      loadPreferences: { _ in [:] },
      loadActiveManifest: { _ in nil },
      loadWallpaperOverrides: { _, themeIDs in
        #expect(themeIDs == [package.id])
        return [package.id: override]
      },
      renderPreview: { ThemePreviewRenderer().render(package: $0) }
    ).load(
      repository: repository,
      stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory)
    )

    let item = try #require(content.items.first)
    let background = try #require(item.backgrounds.first)
    #expect(item.usesWallpaperOverride)
    #expect(item.backgroundData(id: background.id) == override)
  }

  @Test
  func backgroundDecoderCreatesABoundedThumbnail() throws {
    let package = try repository.package(id: "catppuccin-mocha")
    let background = try #require(package.backgrounds.first)
    let data = package.data(for: background)

    let image = try #require(
      ThemeBrowserImageDecoder.thumbnail(data: data, maximumPixelSize: 320)
    )

    #expect(max(image.width, image.height) <= 320)
  }

  @Test
  func explicitApplyForwardsOneThemeAndBackgroundActivation() async throws {
    let activations = Mutex(0)
    let selectedBackground = Mutex<String?>(nil)
    let runner = ThemeSetCommandRunner(
      preflight: { _, _, _, _ in },
      activate: { package, backgroundID, _, _, _ in
        activations.withLock { $0 += 1 }
        selectedBackground.withLock { $0 = backgroundID }
        let manifest = manifest(
          themeID: package.id,
          background: backgroundID.map { GenerationBackground(id: $0, format: .png) }
        )
        return ThemeActivationResult(
          manifest: manifest,
          reconciliation: try ReconciliationRecord(manifest: manifest, results: [])
        )
      }
    )
    let stateRoot = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-theme-browser-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let execution = try await runner.execute(
      repository: repository,
      themeID: "catppuccin-mocha",
      stateRoot: stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: false,
      requestedBackgroundID: "default"
    )

    #expect(execution.succeeded)
    #expect(activations.withLock { $0 } == 1)
    #expect(selectedBackground.withLock { $0 } == "default")
  }

  @Test
  func applyUsesWallpaperOnlyPathForTheActiveThemeAndFullActivationOtherwise() async throws {
    let activeTheme = Mutex("lavender")
    let calls = Mutex([String]())
    let runner = ThemeBrowserApplyRunner(
      activeThemeID: { _ in activeTheme.withLock { $0 } },
      setActiveBackground: { _, backgroundID, _, _ in
        calls.withLock { $0.append("background:\(backgroundID)") }
        return ("background", true)
      },
      setThemeAndBackground: { _, themeID, backgroundID, _, _ in
        calls.withLock { $0.append("theme:\(themeID):\(backgroundID ?? "none")") }
        return ("theme", true)
      }
    )
    let root = URL(filePath: "/test/state", directoryHint: .isDirectory)

    _ = try await runner.execute(
      repository: repository,
      themeID: "lavender",
      backgroundID: "plane-purple",
      stateRoot: root,
      consumerPaths: testConsumerPaths()
    )
    activeTheme.withLock { $0 = "catppuccin-mocha" }
    _ = try await runner.execute(
      repository: repository,
      themeID: "lavender",
      backgroundID: "plane-purple",
      stateRoot: root,
      consumerPaths: testConsumerPaths()
    )

    #expect(calls.withLock { $0 } == ["background:plane-purple", "theme:lavender:plane-purple"])
  }

  @Test
  func applyLauncherSpawnsTheSameCommandWithAnExplicitSelectionRequest() throws {
    struct Spawn: Sendable {
      let executableURL: URL
      let arguments: [String]
      let environment: [String: String]
    }
    let spawned = Mutex<Spawn?>(nil)
    let launcher = ThemeBrowserApplyProcessLauncher(
      spawn: { executableURL, arguments, environment in
        spawned.withLock {
          $0 = Spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
          )
        }
        return ThemeBrowserApplyProcessLauncher.RunningProcess(
          isRunning: { false },
          terminationStatus: { 0 }
        )
      }
    )
    let executableURL = URL(filePath: "/test/macarchy")
    let arguments = ["theme", "browse", "--state-root", "/test/state"]
    let selection = ThemeBrowserSelection(
      themeID: "lavender",
      backgroundID: "plane-purple"
    )

    _ = try launcher.launch(
      selection: selection,
      executableURL: executableURL,
      arguments: arguments,
      environment: ["PRESERVED": "yes"]
    )

    let invocation = try #require(spawned.withLock { $0 })
    #expect(invocation.executableURL == executableURL)
    #expect(invocation.arguments == arguments)
    #expect(invocation.environment["PRESERVED"] == "yes")
    #expect(ThemeBrowserApplyRequest(environment: invocation.environment)?.selection == selection)
  }

  private var repository: ThemeRepository {
    ThemeRepository(builtInRoot: themesRoot)
  }

  private var themesRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Themes", directoryHint: .isDirectory)
  }
}

private func manifest(
  themeID: String,
  background: GenerationBackground?
) -> GenerationManifest {
  GenerationManifest(
    generationID: "g-browser-test",
    themeID: themeID,
    themeSchemaVersion: 1,
    inputDigest: String(repeating: "a", count: 71),
    themeDigest: String(repeating: "b", count: 71),
    background: background,
    rendererVersions: [:],
    artifacts: [:]
  )
}
