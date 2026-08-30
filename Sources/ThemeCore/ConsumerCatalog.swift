import Foundation

package struct ConsumerID: Hashable, RawRepresentable, Sendable {
  package let rawValue: String

  package init(rawValue: String) {
    self.rawValue = rawValue
  }

  package static let macOSAppearance = ConsumerID(rawValue: MacOSAppearanceAdapter.id)
  package static let atuin = ConsumerID(rawValue: AtuinAdapter.id)
  package static let bat = ConsumerID(rawValue: BatAdapter.id)
  package static let btop = ConsumerID(rawValue: BtopAdapter.id)
  package static let codex = ConsumerID(rawValue: CodexAdapter.id)
  package static let eza = ConsumerID(rawValue: EzaAdapter.id)
  package static let herdr = ConsumerID(rawValue: HerdrAdapter.id)
  package static let kitty = ConsumerID(rawValue: KittyAdapter.id)
  package static let neovim = ConsumerID(rawValue: NeovimAdapter.id)
  package static let pi = ConsumerID(rawValue: PiAdapter.id)
  package static let sketchyBar = ConsumerID(rawValue: SketchyBarAdapter.id)
  package static let slack = ConsumerID(rawValue: SlackAdapter.id)
  package static let spicetify = ConsumerID(rawValue: SpicetifyAdapter.id)
  package static let starship = ConsumerID(rawValue: StarshipAdapter.id)
  package static let tuicr = ConsumerID(rawValue: TuicrAdapter.id)
  package static let wallpaper = ConsumerID(rawValue: WallpaperAdapter.id)
  package static let yazi = ConsumerID(rawValue: YaziAdapter.id)
}

package enum RuntimeAdapterKind: CaseIterable, Hashable, Sendable {
  case macOSAppearance
  case atuin
  case bat
  case btop
  case codex
  case eza
  case herdr
  case kitty
  case neovim
  case pi
  case sketchyBar
  case spicetify
  case starship
  case tuicr
  case wallpaper
  case yazi
}

package enum ConsumerMode: Sendable {
  case runtime(RuntimeAdapterKind, requirement: AdapterRequirement)
  case manual

  package var requirement: AdapterRequirement? {
    guard case .runtime(_, let requirement) = self else { return nil }
    return requirement
  }

  package var runtimeKind: RuntimeAdapterKind? {
    guard case .runtime(let kind, _) = self else { return nil }
    return kind
  }

  fileprivate var requiresRenderer: Bool {
    switch self {
    case .manual:
      true
    case .runtime:
      false
    }
  }
}

package enum ConsumerDependencyRole: Sendable {
  case desktopSubstrate
  case requiredAdapter
  case optionalAdapter
}

package struct ConsumerDependencyRegistration: Sendable {
  package let id: String
  package let role: ConsumerDependencyRole

  package init(id: String, role: ConsumerDependencyRole) {
    self.id = id
    self.role = role
  }
}

package struct ConsumerManualNotice: Sendable {
  package let summary: String
  package let instructions: String
  package let artifactPath: String
  package let artifactSummary: String

  package init(
    summary: String,
    instructions: String,
    artifactPath: String,
    artifactSummary: String
  ) {
    self.summary = summary
    self.instructions = instructions
    self.artifactPath = artifactPath
    self.artifactSummary = artifactSummary
  }
}

package struct ConsumerManualPayloadTarget: Equatable, Sendable {
  package let id: String
  package let artifactPath: String
}

package struct ConsumerRenderedOutput: Sendable {
  package let path: String
  package let data: Data

  package init(path: String, data: Data) {
    self.path = path
    self.data = data
  }

  package init(path: String, string: String) {
    self.init(path: path, data: Data(string.utf8))
  }
}

package struct ConsumerRendererRegistration: Sendable {
  package let id: String
  package let version: Int
  package let artifacts: [RenderedArtifactMetadata]
  package let render:
    @Sendable (_ package: ThemePackage, _ generationID: String, _ wallpaperData: Data?) throws
      -> [ConsumerRenderedOutput]

  package init(
    id: String,
    version: Int,
    artifacts: [RenderedArtifactMetadata],
    render:
      @escaping @Sendable (
        _ package: ThemePackage, _ generationID: String, _ wallpaperData: Data?
      ) throws -> [ConsumerRenderedOutput]
  ) {
    self.id = id
    self.version = version
    self.artifacts = artifacts
    self.render = render
  }
}

package struct ConsumerCatalogEntry: Sendable {
  package let id: ConsumerID
  package let mode: ConsumerMode
  package let renderer: ConsumerRendererRegistration?
  package let dependencies: [ConsumerDependencyRegistration]
  package let setupManaged: Bool
  package let supportsNamedThemeFallback: Bool
  package let manualNotice: ConsumerManualNotice?

  package init(
    id: ConsumerID,
    mode: ConsumerMode,
    renderer: ConsumerRendererRegistration? = nil,
    dependencies: [ConsumerDependencyRegistration] = [],
    setupManaged: Bool = false,
    supportsNamedThemeFallback: Bool = false,
    manualNotice: ConsumerManualNotice? = nil
  ) {
    self.id = id
    self.mode = mode
    self.renderer = renderer
    self.dependencies = dependencies
    self.setupManaged = setupManaged
    self.supportsNamedThemeFallback = supportsNamedThemeFallback
    self.manualNotice = manualNotice
  }
}

package enum ConsumerCatalogError: Error, CustomStringConvertible, Equatable, Sendable {
  case duplicateArtifactPath(String)
  case duplicateConsumerID(String)
  case duplicateDependencyCapabilityID(String)
  case duplicateRendererID(String)
  case duplicateRuntimeKind
  case invalidConsumerID(String)
  case invalidDependencyRole(String)
  case invalidManualNotice(String)
  case invalidRenderer(String)
  case invalidSetupParticipation(String)

  package var description: String {
    switch self {
    case .duplicateArtifactPath(let path):
      "Consumer catalog contains duplicate artifact path '\(path)'"
    case .duplicateConsumerID(let id):
      "Consumer catalog contains duplicate consumer ID '\(id)'"
    case .duplicateDependencyCapabilityID(let id):
      "Consumer catalog contains duplicate dependency capability ID '\(id)'"
    case .duplicateRendererID(let id):
      "Consumer catalog contains duplicate renderer ID '\(id)'"
    case .duplicateRuntimeKind:
      "Consumer catalog assigns one runtime adapter kind more than once"
    case .invalidConsumerID(let id):
      "Consumer catalog contains invalid consumer ID '\(id)'"
    case .invalidDependencyRole(let id):
      "Consumer '\(id)' has dependency metadata inconsistent with its requirement"
    case .invalidManualNotice(let id):
      "Consumer '\(id)' has inconsistent manual-notice metadata"
    case .invalidRenderer(let id):
      "Consumer '\(id)' has invalid renderer metadata"
    case .invalidSetupParticipation(let id):
      "Consumer '\(id)' cannot participate in setup"
    }
  }
}

package struct ConsumerCatalog: Sendable {
  package static let shared: ConsumerCatalog = {
    do {
      let catalog = try ConsumerCatalog(entries: productionEntries)
      precondition(
        Set(catalog.runtimeEntries.compactMap { $0.mode.runtimeKind })
          == Set(RuntimeAdapterKind.allCases),
        "Built-in consumer catalog does not cover every runtime adapter kind"
      )
      return catalog
    } catch {
      preconditionFailure("Invalid built-in consumer catalog: \(error)")
    }
  }()

  package let entries: [ConsumerCatalogEntry]

  package init(entries: [ConsumerCatalogEntry]) throws {
    var consumerIDs = Set<ConsumerID>()
    var rendererIDs = Set<String>()
    var artifactPaths = Set<String>()
    var dependencyIDs = Set<String>()
    var runtimeKinds = Set<RuntimeAdapterKind>()

    for entry in entries {
      guard ThemeSchema.isThemeID(entry.id.rawValue) else {
        throw ConsumerCatalogError.invalidConsumerID(entry.id.rawValue)
      }
      guard consumerIDs.insert(entry.id).inserted else {
        throw ConsumerCatalogError.duplicateConsumerID(entry.id.rawValue)
      }

      if let kind = entry.mode.runtimeKind,
        !runtimeKinds.insert(kind).inserted
      {
        throw ConsumerCatalogError.duplicateRuntimeKind
      }
      if entry.setupManaged, entry.mode.runtimeKind == nil {
        throw ConsumerCatalogError.invalidSetupParticipation(entry.id.rawValue)
      }
      if entry.supportsNamedThemeFallback, entry.mode.runtimeKind == nil {
        throw ConsumerCatalogError.invalidRenderer(entry.id.rawValue)
      }

      let isManual = {
        if case .manual = entry.mode { return true }
        return false
      }()
      guard isManual == (entry.manualNotice != nil) else {
        throw ConsumerCatalogError.invalidManualNotice(entry.id.rawValue)
      }

      for dependency in entry.dependencies {
        guard dependencyIDs.insert(dependency.id).inserted else {
          throw ConsumerCatalogError.duplicateDependencyCapabilityID(dependency.id)
        }
        switch dependency.role {
        case .desktopSubstrate, .requiredAdapter:
          guard entry.mode.requirement == .required else {
            throw ConsumerCatalogError.invalidDependencyRole(entry.id.rawValue)
          }
        case .optionalAdapter:
          guard entry.mode.requirement == .optional else {
            throw ConsumerCatalogError.invalidDependencyRole(entry.id.rawValue)
          }
        }
      }

      guard let renderer = entry.renderer else {
        if entry.mode.requiresRenderer {
          throw ConsumerCatalogError.invalidRenderer(entry.id.rawValue)
        }
        continue
      }
      guard renderer.version > 0, ThemeSchema.isThemeID(renderer.id),
        !renderer.artifacts.isEmpty
      else {
        throw ConsumerCatalogError.invalidRenderer(entry.id.rawValue)
      }
      guard rendererIDs.insert(renderer.id).inserted else {
        throw ConsumerCatalogError.duplicateRendererID(renderer.id)
      }
      for artifact in renderer.artifacts {
        guard artifactPaths.insert(artifact.path).inserted else {
          throw ConsumerCatalogError.duplicateArtifactPath(artifact.path)
        }
      }
      if let notice = entry.manualNotice,
        !renderer.artifacts.contains(where: { $0.path == notice.artifactPath })
      {
        throw ConsumerCatalogError.invalidManualNotice(entry.id.rawValue)
      }
    }

    _ = try RenderedTheme(
      artifacts: entries.flatMap { $0.renderer?.artifacts ?? [] }.map {
        RenderedArtifact(metadata: $0, data: Data())
      }
    )

    self.entries = entries
  }

  package var runtimeEntries: [ConsumerCatalogEntry] {
    entries.filter { $0.mode.runtimeKind != nil }
  }

  package var rendererVersions: [String: Int] {
    Dictionary(
      uniqueKeysWithValues: entries.compactMap { entry in
        entry.renderer.map { ($0.id, $0.version) }
      })
  }

  package var artifactMetadata: [RenderedArtifactMetadata] {
    entries.flatMap { $0.renderer?.artifacts ?? [] }
  }

  package var setupConsumerIDs: Set<ConsumerID> {
    Set(entries.filter(\.setupManaged).map(\.id))
  }

  package var namedThemeFallbackConsumerIDs: Set<String> {
    Set(entries.filter(\.supportsNamedThemeFallback).map { $0.id.rawValue })
  }

  package func entry(for id: ConsumerID) -> ConsumerCatalogEntry? {
    entries.first { $0.id == id }
  }

  package func manualNotice(for id: ConsumerID) -> ConsumerManualNotice? {
    entry(for: id)?.manualNotice
  }

  package var manualPayloadTargets: [ConsumerManualPayloadTarget] {
    entries.compactMap { entry in
      entry.manualNotice.map {
        ConsumerManualPayloadTarget(id: entry.id.rawValue, artifactPath: $0.artifactPath)
      }
    }
  }

  package func manualPayloadTarget(id: String) -> ConsumerManualPayloadTarget? {
    manualPayloadTargets.first { $0.id == id }
  }

  private static let productionEntries: [ConsumerCatalogEntry] = [
    ConsumerCatalogEntry(
      id: .macOSAppearance,
      mode: .runtime(.macOSAppearance, requirement: .required)
    ),
    ConsumerCatalogEntry(
      id: .atuin,
      mode: .runtime(.atuin, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: AtuinAdapter.id,
        version: AtuinAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: AtuinAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: AtuinAdapter.outputPath, string: AtuinAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: AtuinAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .bat,
      mode: .runtime(.bat, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: TextMateThemeArtifact.rendererID,
        version: TextMateThemeArtifact.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: TextMateThemeArtifact.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: TextMateThemeArtifact.outputPath,
            string: TextMateThemeArtifact.render(package: package))
        ]
      },
      dependencies: [.init(id: BatAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .btop,
      mode: .runtime(.btop, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: BtopAdapter.id,
        version: BtopAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: BtopAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: BtopAdapter.outputPath, string: BtopAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: BtopAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .codex,
      mode: .runtime(.codex, requirement: .required),
      dependencies: [.init(id: CodexAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .eza,
      mode: .runtime(.eza, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: EzaAdapter.id,
        version: EzaAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: EzaAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: EzaAdapter.outputPath, string: EzaAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: EzaAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .herdr,
      mode: .runtime(.herdr, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: HerdrAdapter.id,
        version: HerdrAdapter.rendererVersion,
        artifacts: [
          RenderedArtifactMetadata(
            path: HerdrAdapter.outputPath,
            requirement: .requiredWhenRendererVersion(
              renderer: .herdr, minimumVersion: 3
            )
          )
        ]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: HerdrAdapter.outputPath, string: try HerdrAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: HerdrAdapter.id, role: .requiredAdapter)],
      setupManaged: true,
      supportsNamedThemeFallback: true
    ),
    ConsumerCatalogEntry(
      id: .kitty,
      mode: .runtime(.kitty, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: KittyAdapter.id,
        version: KittyAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: KittyAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: KittyAdapter.outputPath, string: KittyAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: KittyAdapter.id, role: .desktopSubstrate)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .neovim,
      mode: .runtime(.neovim, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: NeovimAdapter.id,
        version: NeovimAdapter.rendererVersion,
        artifacts: [
          RenderedArtifactMetadata(
            path: NeovimAdapter.outputPath,
            requirement: .requiredWhenRendererVersion(
              renderer: .neovim, minimumVersion: 4
            )
          )
        ]
      ) { package, generationID, _ in
        [
          ConsumerRenderedOutput(
            path: NeovimAdapter.outputPath,
            string: try NeovimAdapter.render(package: package, generationID: generationID))
        ]
      },
      dependencies: [.init(id: NeovimAdapter.id, role: .requiredAdapter)],
      setupManaged: true,
      supportsNamedThemeFallback: true
    ),
    ConsumerCatalogEntry(
      id: .pi,
      mode: .runtime(.pi, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: PiAdapter.id,
        version: PiAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: PiAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: PiAdapter.outputPath, string: try PiAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: PiAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .sketchyBar,
      mode: .runtime(.sketchyBar, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: SketchyBarAdapter.id,
        version: SketchyBarAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: SketchyBarAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: SketchyBarAdapter.outputPath, string: SketchyBarAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: SketchyBarAdapter.id, role: .desktopSubstrate)]
    ),
    ConsumerCatalogEntry(
      id: .slack,
      mode: .manual,
      renderer: ConsumerRendererRegistration(
        id: SlackAdapter.id,
        version: SlackAdapter.rendererVersion,
        artifacts: [
          RenderedArtifactMetadata(
            path: SlackAdapter.outputPath,
            requirement: .requiredWhenRendererVersion(renderer: .slack, minimumVersion: 1)
          )
        ]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: SlackAdapter.outputPath, string: SlackAdapter.render(package: package))
        ]
      },
      manualNotice: ConsumerManualNotice(
        summary:
          "Slack theme requires manual import; Slack exposes no supported theme automation API.",
        instructions: SlackAdapter.importInstructions,
        artifactPath: SlackAdapter.outputPath,
        artifactSummary:
          "The payload is also stored as the active generation's \(SlackAdapter.outputPath) artifact."
      )
    ),
    ConsumerCatalogEntry(
      id: .spicetify,
      mode: .runtime(.spicetify, requirement: .optional),
      renderer: ConsumerRendererRegistration(
        id: SpicetifyAdapter.id,
        version: SpicetifyAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: SpicetifyAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: SpicetifyAdapter.outputPath, string: SpicetifyAdapter.render(package: package))
        ]
      },
      dependencies: [
        .init(id: SpicetifyAdapter.id, role: .optionalAdapter),
        .init(id: "spotify", role: .optionalAdapter),
      ],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .starship,
      mode: .runtime(.starship, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: StarshipAdapter.id,
        version: StarshipAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: StarshipAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: StarshipAdapter.outputPath, string: StarshipAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: StarshipAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .tuicr,
      mode: .runtime(.tuicr, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: TuicrAdapter.id,
        version: TuicrAdapter.rendererVersion,
        artifacts: [RenderedArtifactMetadata(path: TuicrAdapter.outputPath)]
      ) { package, _, _ in
        [
          ConsumerRenderedOutput(
            path: TuicrAdapter.outputPath, string: TuicrAdapter.render(package: package))
        ]
      },
      dependencies: [.init(id: TuicrAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
    ConsumerCatalogEntry(
      id: .wallpaper,
      mode: .runtime(.wallpaper, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: WallpaperAdapter.id,
        version: WallpaperAdapter.rendererVersion,
        artifacts: [
          RenderedArtifactMetadata(
            path: WallpaperAdapter.outputPath,
            sizePolicy: .wallpaper,
            requirement: .optional
          )
        ]
      ) { _, _, wallpaperData in
        guard let wallpaperData else {
          throw GenerationIntegrityError(reason: "wallpaper renderer requires selected bytes")
        }
        return [ConsumerRenderedOutput(path: WallpaperAdapter.outputPath, data: wallpaperData)]
      }
    ),
    ConsumerCatalogEntry(
      id: .yazi,
      mode: .runtime(.yazi, requirement: .required),
      renderer: ConsumerRendererRegistration(
        id: YaziAdapter.id,
        version: YaziAdapter.rendererVersion,
        artifacts: [
          RenderedArtifactMetadata(path: YaziAdapter.flavorOutputPath),
          RenderedArtifactMetadata(path: TextMateThemeArtifact.yaziOutputPath),
        ]
      ) { package, _, _ in
        let textMate = TextMateThemeArtifact.render(package: package)
        return [
          ConsumerRenderedOutput(
            path: YaziAdapter.flavorOutputPath, string: YaziAdapter.renderFlavor(package: package)),
          ConsumerRenderedOutput(path: TextMateThemeArtifact.yaziOutputPath, string: textMate),
        ]
      },
      dependencies: [.init(id: YaziAdapter.id, role: .requiredAdapter)],
      setupManaged: true
    ),
  ]
}
