import Foundation
import Testing

@testable import ThemeCore

struct ConsumerCatalogTests {
  @Test
  func productionCatalogDerivesRuntimeRendererAndArtifactInventories() throws {
    let catalog = ConsumerCatalog.shared

    #expect(
      Set(catalog.runtimeEntries.compactMap { $0.mode.runtimeKind })
        == Set(RuntimeAdapterKind.allCases))
    #expect(
      ThemeActivationCoordinator.adapterRequirements
        == Dictionary(
          uniqueKeysWithValues: catalog.runtimeEntries.map {
            ($0.id.rawValue, $0.mode.requirement!)
          }
        )
    )
    #expect(catalog.rendererVersions[TextMateThemeArtifact.rendererID] == 1)
    #expect(catalog.rendererVersions[PiAdapter.id] == PiAdapter.rendererVersion)
    #expect(catalog.rendererVersions[SlackAdapter.id] == SlackAdapter.rendererVersion)

    let metadata = try ThemeRenderer.validatedArtifactMetadata()
    #expect(
      Set(metadata.keys)
        == Set(
          catalog.artifactMetadata.map(\.path) + ["theme.json", "generated/capabilities.json"]))
    #expect(catalog.namedThemeFallbackConsumerIDs == [HerdrAdapter.id, NeovimAdapter.id])
    #expect(catalog.manualNotice(for: .slack)?.artifactPath == SlackAdapter.outputPath)
    #expect(
      catalog.manualPayloadTargets
        == [ConsumerManualPayloadTarget(id: "slack", artifactPath: SlackAdapter.outputPath)]
    )
  }

  @Test
  func catalogRejectsDuplicateAndInconsistentRegistrations() throws {
    let first = try #require(ConsumerCatalog.shared.entries.first)
    #expect(throws: ConsumerCatalogError.duplicateConsumerID(first.id.rawValue)) {
      _ = try ConsumerCatalog(entries: [first, first])
    }

    let invalidManual = ConsumerCatalogEntry(
      id: ConsumerID(rawValue: "fixture-manual"),
      mode: .manual
    )
    #expect(throws: ConsumerCatalogError.invalidManualNotice("fixture-manual")) {
      _ = try ConsumerCatalog(entries: [invalidManual])
    }

    let invalidSetup = ConsumerCatalogEntry(
      id: ConsumerID(rawValue: "fixture-generated"),
      mode: .generatedPalette,
      setupManaged: true
    )
    #expect(throws: ConsumerCatalogError.invalidSetupParticipation("fixture-generated")) {
      _ = try ConsumerCatalog(entries: [invalidSetup])
    }

    func renderedEntry(_ id: String, rendererID: String) -> ConsumerCatalogEntry {
      ConsumerCatalogEntry(
        id: ConsumerID(rawValue: id),
        mode: .generatedPalette,
        renderer: ConsumerRendererRegistration(
          id: rendererID,
          version: 1,
          artifacts: [RenderedArtifactMetadata(path: "generated/duplicate.txt")]
        ) { _, _, _ in
          [ConsumerRenderedOutput(path: "generated/duplicate.txt", data: Data())]
        }
      )
    }
    #expect(
      throws: ConsumerCatalogError.duplicateArtifactPath("generated/duplicate.txt")
    ) {
      _ = try ConsumerCatalog(
        entries: [
          renderedEntry("fixture-one", rendererID: "fixture-one"),
          renderedEntry("fixture-two", rendererID: "fixture-two"),
        ]
      )
    }
  }

  @Test
  func generatedPaletteConsumerExtendsRenderingThroughOneCatalogEntry() throws {
    let path = "generated/fixture-palette.txt"
    let fixture = ConsumerCatalogEntry(
      id: ConsumerID(rawValue: "fixture-palette"),
      mode: .generatedPalette,
      renderer: ConsumerRendererRegistration(
        id: "fixture-palette",
        version: 1,
        artifacts: [RenderedArtifactMetadata(path: path)]
      ) { package, generationID, _ in
        [
          ConsumerRenderedOutput(
            path: path,
            string: "\(package.id) \(generationID) \(package.semantic.accent.rawValue)\n"
          )
        ]
      }
    )
    let catalog = try ConsumerCatalog(entries: ConsumerCatalog.shared.entries + [fixture])
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )

    let rendered = try ThemeRenderer(catalog: catalog).render(
      package: package,
      generationID: "fixture-generation"
    )

    #expect(
      String(decoding: try #require(rendered.artifact(atPath: path)).data, as: UTF8.self)
        == "catppuccin-mocha fixture-generation #cba6f7\n"
    )
    #expect(try ThemeRenderer.validatedArtifactMetadata()[path] == nil)
    #expect(try ThemeRenderer.validatedArtifactMetadata(catalog: catalog)[path] != nil)
  }
}
