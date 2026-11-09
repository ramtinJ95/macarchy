import Darwin
import Foundation
import TOMLDecoder
import ThemeCore

struct EnvironmentEntryInspection: Encodable, Equatable, Sendable {
  let id: String
  let path: String
  let status: EnvironmentInspectionStatus
  let ownership: String
  let message: String
  let evidence: EnvironmentEntryEvidence?
}

struct EnvironmentProviderInspection: Sendable {
  let entries: [EnvironmentEntryInspection]
  let ownership: EnvironmentOwnership?
  let adoptionEvidenceDigest: String?
  let blockedMessage: String?
  let desiredEntries: [EnvironmentManagedEntry]
  let externalEvidence: [EnvironmentEntryID: EnvironmentEntryEvidence]
  let createdDirectories: [String]
  var proposedBtopOwnership: EnvironmentBtopOwnership? = nil
  var proposedCodexOwnership: EnvironmentCodexOwnership? = nil
  var proposedHerdrOwnership: EnvironmentHerdrOwnership? = nil
  var proposedPiOwnership: EnvironmentPiOwnership? = nil
  var proposedSpicetifyOwnership: EnvironmentSpicetifyOwnership? = nil
  var proposedGhosttyOwnership: EnvironmentGhosttyOwnership? = nil
  var proposedZedOwnership: EnvironmentZedOwnership? = nil
  var proposedZedFamilyOwnership: EnvironmentZedFamilyOwnership? = nil
  var proposedAlacrittyOwnership: EnvironmentAlacrittyOwnership? = nil
  var proposedTuicrOwnership: EnvironmentTuicrOwnership? = nil
  /// Planned evidence of each key-owned file apply must find unchanged.
  var keyOwnedExternalEvidence: [EnvironmentKeyOwnedFile: EnvironmentEntryEvidence] = [:]
  var proposedBordersOwnership: EnvironmentBordersOwnership? = nil
  var bordersServiceInspection: BordersServiceInspection? = nil
  var leanServiceInspection: EnvironmentLeanObservation? = nil
  var standardNativeEntries: [EnvironmentEntryID] = []

  static func blocked(_ error: any Error) -> Self {
    Self(
      entries: [], ownership: nil, adoptionEvidenceDigest: nil,
      blockedMessage: String(describing: error), desiredEntries: [], externalEvidence: [:],
      createdDirectories: [])
  }

  /// Whether apply adopts or installs the key-owned file rather than leaving it external.
  func proposesOwnership(of file: EnvironmentKeyOwnedFile) -> Bool {
    switch file {
    case .btop: proposedBtopOwnership != nil
    case .codex: proposedCodexOwnership != nil
    case .herdr: proposedHerdrOwnership != nil
    case .pi: proposedPiOwnership != nil
    case .spicetify: proposedSpicetifyOwnership != nil
    case .ghostty: proposedGhosttyOwnership != nil
    case .zed: proposedZedOwnership != nil
    case .zedFamily: proposedZedFamilyOwnership != nil
    case .alacritty: proposedAlacrittyOwnership != nil
    case .tuicr: proposedTuicrOwnership != nil
    }
  }

  var isBlocked: Bool {
    blockedMessage != nil
      || entries.contains { $0.status == .drifted || $0.status == .unsupported }
  }
}

struct EnvironmentProviderInspector: Sendable {
  private static let maximumExternalFileSize = 4 * 1_048_576
  let alacrittyVersion: @Sendable () throws -> [Int]
  let ghosttyVersion: @Sendable () throws -> [Int]
  let zedVersion: @Sendable () throws -> [Int]
  let slackPreset: EnvironmentSlackPreset
  /// Only unified first-install planning supplies a rendered, not-yet-active theme.
  let bootstrapTheme: ThemePackage?
  /// Only absent, validated starter plans may stand in for files during first-install review.
  let proposedNativeSources: Set<String>

  init(
    slackPreset: EnvironmentSlackPreset = EnvironmentSlackPreset(),
    bootstrapTheme: ThemePackage? = nil,
    proposedNativeSources: Set<String> = [],
    alacrittyVersion: @escaping @Sendable () throws -> [Int] = AlacrittyAdapter.installedVersion,
    ghosttyVersion: @escaping @Sendable () throws -> [Int] = GhosttyAdapter.installedVersion,
    zedVersion: @escaping @Sendable () throws -> [Int] = ZedAdapter.installedVersion
  ) {
    self.alacrittyVersion = alacrittyVersion
    self.ghosttyVersion = ghosttyVersion
    self.zedVersion = zedVersion
    self.slackPreset = slackPreset
    self.bootstrapTheme = bootstrapTheme
    self.proposedNativeSources = proposedNativeSources
  }

  func inspect(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    bordersService: BordersServiceInspection? = nil,
    leanService: EnvironmentLeanObservation? = nil
  ) -> EnvironmentProviderInspection {
    do {
      if let source = composition.profile.zsh.configurationURL {
        guard
          EnvironmentNativeSource.targetIsAllowed(
            source.path, homeDirectory: homeDirectory, stateRoot: stateRoot,
            userOwnedPublicEntry: .zsh)
        else {
          throw EnvironmentLifecycleError.blocked(
            "zsh.configuration must live outside Macarchy state and the managed ~/.zshrc entry point"
          )
        }
      }
      let store = EnvironmentStateStore(stateRoot: stateRoot)
      if let source = composition.profile.kitty.configurationURL {
        guard
          EnvironmentNativeSource.targetIsAllowed(
            source.path, homeDirectory: homeDirectory, stateRoot: stateRoot,
            userOwnedPublicEntry: .kitty)
        else {
          throw EnvironmentLifecycleError.blocked(
            "kitty.configuration must live outside Macarchy state and the managed ~/.config/kitty directory"
          )
        }
      }
      let ownership = try store.readOwnership()
      let currentDestination = try EnvironmentGenerationStore(stateRoot: stateRoot)
        .currentDestination()
      if let ownership {
        guard currentDestination == StateLayout.generationPath(ownership.generationID) else {
          throw EnvironmentLifecycleError.drift(
            "environment ownership and the selected generation disagree"
          )
        }
      } else if currentDestination != nil {
        throw EnvironmentLifecycleError.drift(
          "an environment generation is selected without ownership"
        )
      }
      var standardShellEntries = Set<EnvironmentEntryID>()
      for provider in [EnvironmentNativeSeed.Provider.zsh, .kitty] {
        guard provider.isEnabled(in: composition.profile) else { continue }
        let source = provider.source(in: composition.profile)
        let standard = provider.standardURL(homeDirectory: homeDirectory)
        if ownership?.standardNativeEntries?.contains(provider.entryID) == true,
          source?.path != standard.path
        {
          throw EnvironmentLifecycleError.blocked(
            "Keep \(provider.rawValue).configuration pointed at its user-owned standard path, or review a migration before changing the connection"
          )
        }
        guard source?.path == standard.path else { continue }
        guard ownership?.records.contains(where: { $0.id == provider.entryID }) != true else {
          throw EnvironmentLifecycleError.blocked(
            "Review migration of the managed \(provider.rawValue) entry before selecting its standard native path"
          )
        }
        if !proposedNativeSources.contains(standard.path) {
          try EnvironmentStandardNativeConfiguration.validate(
            provider, homeDirectory: homeDirectory, stateRoot: stateRoot)
        }
        standardShellEntries.insert(provider.entryID)
      }
      let neovim = EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
      let neovimSource =
        composition.profile.neovim.nativeConfigurationDirectoryURL
        ?? neovim.nativeTarget(in: ownership)
      let nativeNeovim = neovimSource != nil
      let standardNeovim = neovimSource?.path == neovim.publicURL.path
      if ownership?.standardNativeEntries?.contains(.neovim) == true, !standardNeovim {
        throw EnvironmentLifecycleError.blocked(
          "Neovim is user-owned at its standard path; changing that connection requires a reviewed migration"
        )
      }
      if composition.profile.editor == .neovim, let neovimSource {
        if !proposedNativeSources.contains(neovimSource.path) {
          try neovim.validateNativeTree(at: neovimSource, userOwnedPublicEntry: standardNeovim)
        }
        if let record = ownership?.records.first(where: { $0.id == .neovim }),
          record.managedTarget != neovimSource.path
        {
          throw EnvironmentLifecycleError.blocked(
            "Neovim source changed; review environment migrate-neovim --source before applying this profile"
          )
        }
      }
      let atuin = EnvironmentNativeFileMigration(
        provider: .atuin, homeDirectory: homeDirectory, stateRoot: stateRoot)
      let (atuinSource, standardAtuin) = try nativeFileConnection(
        atuin, configured: composition.profile.atuin.nativeConfigurationURL,
        selected: composition.profile.history == .atuin, ownership: ownership)
      let starship = EnvironmentNativeFileMigration(
        provider: .starship, homeDirectory: homeDirectory, stateRoot: stateRoot)
      let (starshipSource, standardStarship) = try nativeFileConnection(
        starship, configured: composition.profile.starship.nativeConfigurationURL,
        selected: composition.profile.prompt == .starship, ownership: ownership)
      let nativeSources = [
        EnvironmentEntryID.neovim: neovimSource, .atuinConfiguration: atuinSource,
        .starship: starshipSource,
      ].compactMapValues { $0 }
      let entries = desiredEntries(
        profile: composition.profile,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        retainBorders: ownership?.borders?.retainsBorders == true
      ).map { entry in
        guard let source = nativeSources[entry.id] else { return entry }
        return EnvironmentManagedEntry(
          id: entry.id, url: entry.url, kind: entry.kind, target: source.path)
      }
      let setupContext = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
      let legacyEntryIDs: [EnvironmentEntryID: [String]] = [
        .kitty: ["kitty.include"],
        .atuinConfiguration: ["atuin.selector", "atuin.theme-link"],
        .starship: ["starship.configuration-link"],
        .neovim: ["neovim.theme-link"],
      ]
      var legacyIDs = Set(entries.flatMap { legacyEntryIDs[$0.id] ?? [] })
      for tool in EnvironmentDailyTool.allCases
      where tool.isEnabled(in: composition.profile.tools) {
        legacyIDs.formUnion(tool.legacySetupIDs)
      }
      let setupRecords = try SetupOwnershipManager().readRecords(context: setupContext)
      let setupIDs = Set(setupRecords.map(\.id))
      var legacyOwned = [EnvironmentLinkedPreset: Bool]()
      // An incomplete legacy integration is reported in this order.
      for linked in [EnvironmentLinkedPreset.tuicr, .pi, .spicetify, .codex] {
        legacyOwned[linked] = try linked.hasCompleteLegacyIntegration(setupIDs: setupIDs)
      }
      // An enabled preset with neither key ownership, owned theme links nor legacy setup
      // ownership left its exact external tuple authoritative.
      var externallyAuthoritative = [EnvironmentLinkedPreset: Bool]()
      for linked in EnvironmentLinkedPreset.allCases {
        let enabled = ownership.map { linked.preset.isEnabled(in: $0) } == true
        let ownsLinks =
          ownership?.records.contains(where: { linked.themeLinks.contains($0.id) }) == true
        externallyAuthoritative[linked] =
          enabled && !linked.file.isOwned(by: ownership) && !ownsLinks
          && legacyOwned[linked] != true
      }
      let conflicts =
        setupRecords
        .map(\.id).filter { legacyIDs.contains($0) }
      guard conflicts.isEmpty else {
        throw EnvironmentLifecycleError.blocked(
          "legacy setup ownership must be torn down before environment adoption: \(conflicts.sorted().joined(separator: ", "))"
        )
      }
      let owned = Dictionary(uniqueKeysWithValues: (ownership?.records ?? []).map { ($0.id, $0) })
      let allowed = Dictionary(
        uniqueKeysWithValues: EnvironmentManagedEntry.all(
          homeDirectory: homeDirectory, stateRoot: stateRoot
        )
        .map { ($0.id, $0) }
      )
      for record in ownership?.records ?? [] {
        guard let entry = allowed[record.id],
          neovim.allows(record, entry: entry) || atuin.allows(record, entry: entry)
            || starship.allows(record, entry: entry)
        else {
          throw EnvironmentLifecycleError.blocked(
            "ownership for \(record.id.rawValue) contains an unexpected provider path or target"
          )
        }
      }
      var inspections = [EnvironmentEntryInspection]()
      var evidence = [EnvironmentEntryID: EnvironmentEntryEvidence]()
      var createdDirectories = Set<String>()
      func recordMissingParents(of url: URL) throws {
        for directory in try missingParentDirectories(of: url, homeDirectory: homeDirectory) {
          createdDirectories.insert(directory.path)
        }
      }
      var standardNativeEntries = [EnvironmentEntryID]()

      for entry in entries {
        if entry.id == .atuinConfiguration && standardAtuin
          || entry.id == .starship && standardStarship
          || entry.id == .neovim && standardNeovim
          || standardShellEntries.contains(entry.id), owned[entry.id] == nil
        {
          standardNativeEntries.append(entry.id)
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.id == .kitty
                ? entry.url.appending(path: "kitty.conf").path : entry.url.path,
              status: .external,
              ownership: "user_owned_native",
              message:
                "The application reads this user-owned standard configuration directly. Macarchy maintains only its declared theme seam; reapply and teardown preserve behavior and personal links.",
              evidence: nil))
          continue
        }
        let hasExternalAncestor = try hasSymlinkAncestor(
          entry.url,
          stoppingAt: homeDirectory
        )
        let captured =
          owned[entry.id] == nil
          ? try capture(
            entry.url,
            directoryLink: entry.id.directoryLinkKind
          ) : nil
        if let captured,
          entry.id != .atuinTheme || hasExternalAncestor,
          try externalEntryIsExact(entry, evidence: captured, composition: composition)
        {
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: .external,
              ownership: "external_exact",
              message: "The exact provider seam remains externally owned.",
              evidence: captured
            )
          )
          continue
        }
        if entry.id == .spicetifyColor, let captured, captured.kind != .absent {
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: .unsupported,
              ownership: "external",
              message: "A divergent Spicetify color.ini is never adopted or replaced.",
              evidence: captured
            )
          )
          continue
        }
        if hasExternalAncestor {
          if Self.isDailyToolEntry(entry.id) {
            inspections.append(
              EnvironmentEntryInspection(
                id: entry.id.rawValue,
                path: entry.url.path,
                status: .unsupported,
                ownership: "external",
                message: "The provider entry is below a symlink-owned parent.",
                evidence: captured
              )
            )
            continue
          }
          throw EnvironmentLifecycleError.blocked(
            "provider entry is below a symlink-owned parent: \(entry.url.path)"
          )
        }

        if let record = owned[entry.id] {
          guard record.publicPath == entry.url.path,
            record.managedKind == entry.kind.rawValue,
            record.managedTarget == entry.target
          else {
            throw EnvironmentLifecycleError.drift("ownership for \(entry.id.rawValue) is invalid")
          }
          let exact = try managedEntryIsExact(entry)
          if exact, entry.id == .neovim, let neovimSource {
            try neovim.validateNativeTree(at: neovimSource)
          }
          if exact, entry.id == .atuinConfiguration, let atuinSource {
            try atuin.validateNativeFile(at: atuinSource)
          }
          if exact, entry.id == .starship, let starshipSource {
            try starship.validateNativeFile(at: starshipSource)
          }
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: exact ? .managed : .drifted,
              ownership: "macarchy",
              message: exact
                ? (entry.id == .neovim
                  ? (nativeNeovim
                    ? "Neovim behavior and Lazy lock are user-owned; only the entry and theme bridges are managed."
                    : "Neovim configuration is immutable; interactive Lazy writes require environment migrate-neovim.")
                  : (entry.id == .atuinConfiguration && atuinSource != nil
                    ? "Atuin behavior is user-owned; only the entry and theme link are managed. Profile behavior options are seed-only in this mode."
                    : (entry.id == .starship && starshipSource != nil
                      ? "Starship behavior is user-owned; only the entry, selector and reserved palette are managed. Profile behavior is seed-only in this mode."
                      : "The provider entry is managed.")))
                : "The managed provider entry drifted.",
              evidence: nil
            )
          )
          continue
        }

        guard let captured else {
          throw EnvironmentLifecycleError.blocked(
            "provider inspection lost external evidence for \(entry.id.rawValue)"
          )
        }
        if entry.id == .spicetifyColor, captured.kind == .absent,
          try !missingParentDirectories(
            of: entry.url,
            homeDirectory: homeDirectory
          ).isEmpty
        {
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: .unsupported,
              ownership: "external",
              message:
                "Spicetify's Themes/text directory must already exist; Macarchy never owns it.",
              evidence: captured
            )
          )
          continue
        }
        evidence[entry.id] = captured
        try recordMissingParents(of: entry.url)
        let absent = captured.kind == .absent
        inspections.append(
          EnvironmentEntryInspection(
            id: entry.id.rawValue,
            path: entry.url.path,
            status: absent ? .installRequired : .adoptionRequired,
            ownership: "external",
            message: absent
              ? "The provider entry will be installed."
              : "The provider entry must be adopted with reviewed evidence.",
            evidence: captured
          )
        )
      }

      if composition.profile.tools.eza, composition.profile.shell == .disabled {
        inspections.append(
          try inspectExternalEzaEnvironment(
            homeDirectory: homeDirectory,
            configurationDirectory: homeDirectory.appending(path: ConsumerHomePath.ezaDirectory)
          )
        )
      }

      let btop = try inspectBtop(
        composition: composition,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        ownership: ownership?.btop,
        ownershipGenerationID: ownership?.generationID
      )
      if let entry = btop.entry { inspections.append(entry) }
      if btop.proposedOwnership != nil {
        try recordMissingParents(
          of: homeDirectory.appending(path: ConsumerHomePath.btopConfiguration))
      }

      let codex = try inspectSelector(
        .codex, EnvironmentSelectorDocument<EnvironmentCodexOwnership>.codex,
        composition: composition,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        ownership: ownership?.codex,
        legacyOwned: legacyOwned[.codex, default: false],
        externallyAuthoritative: externallyAuthoritative[.codex, default: false]
      )
      if let entry = codex.entry { inspections.append(entry) }
      inspections += try preservedPresetLinks(
        .codex, in: allowed, legacyOwned: legacyOwned[.codex, default: false],
        externallyAuthoritative: externallyAuthoritative[.codex, default: false],
        composition: composition)
      if codex.proposedOwnership != nil {
        try recordMissingParents(
          of: homeDirectory.appending(path: ConsumerHomePath.codexConfiguration))
      }

      let herdr = try inspectHerdr(
        composition: composition,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        ownership: ownership?.herdr,
        previouslyEnabled: ownership?.herdrEnabled == true
      )
      if let entry = herdr.entry { inspections.append(entry) }
      if herdr.proposedOwnership != nil, herdr.proposedOwnership?.directoryLink == nil {
        try recordMissingParents(
          of: homeDirectory.appending(path: ConsumerHomePath.herdrConfiguration))
      }

      let pi = try inspectSelector(
        .pi, EnvironmentSelectorDocument<EnvironmentPiOwnership>.pi,
        composition: composition,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        ownership: ownership?.pi,
        legacyOwned: legacyOwned[.pi, default: false],
        externallyAuthoritative: externallyAuthoritative[.pi, default: false]
      )
      if let entry = pi.entry { inspections.append(entry) }
      inspections += try preservedPresetLinks(
        .pi, in: allowed, legacyOwned: legacyOwned[.pi, default: false],
        externallyAuthoritative: externallyAuthoritative[.pi, default: false],
        composition: composition)
      if pi.proposedOwnership != nil {
        try recordMissingParents(of: homeDirectory.appending(path: ConsumerHomePath.piSettings))
      }

      let spicetify = try inspectSpicetify(
        composition: composition,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        ownership: ownership?.spicetify,
        legacyOwned: legacyOwned[.spicetify, default: false],
        externallyAuthoritative: externallyAuthoritative[.spicetify, default: false]
      )
      if let entry = spicetify.entry { inspections.append(entry) }
      inspections += try preservedPresetLinks(
        .spicetify, in: allowed, legacyOwned: legacyOwned[.spicetify, default: false],
        externallyAuthoritative: externallyAuthoritative[.spicetify, default: false],
        composition: composition)

      if composition.profile.presets.slack {
        inspections.append(
          slackPreset.entry(
            stateRoot: stateRoot,
            applied: ownership?.slackEnabled == true,
            bootstrapTheme: bootstrapTheme
          )
        )
      } else if ownership?.slackEnabled == true {
        inspections.append(
          EnvironmentEntryInspection(
            id: EnvironmentSlackPreset.manualEntryID,
            path: EnvironmentSlackPreset.bundleURL.path,
            status: .restorationRequired,
            ownership: "macarchy_authority",
            message: "Slack manual-import authority will be removed without touching Slack.",
            evidence: nil
          )
        )
      }

      let zed = try inspectZed(
        enabled: composition.profile.presets.zed, ownership: ownership?.zed, home: homeDirectory)
      let zedFamily = try inspectZedFamily(
        enabled: composition.profile.presets.zed, ownership: ownership?.zedFamily,
        home: homeDirectory, root: stateRoot)
      for entry in [zed.entry, zedFamily.entry].compactMap({ $0 }) { inspections.append(entry) }
      for path in [zed.proposedOwnership?.path, zedFamily.proposedOwnership?.path].compactMap({ $0 }
      ) { try recordMissingParents(of: URL(filePath: path)) }
      let alacritty = try inspectAlacritty(
        enabled: composition.profile.presets.alacritty, ownership: ownership?.alacritty,
        home: homeDirectory, root: stateRoot)
      if let entry = alacritty.entry { inspections.append(entry) }
      if let proposed = alacritty.proposedOwnership {
        try recordMissingParents(of: URL(filePath: proposed.path))
      }

      let ghostty = try inspectGhostty(
        enabled: composition.profile.presets.ghostty, ownership: ownership?.ghostty,
        home: homeDirectory, root: stateRoot)
      if let entry = ghostty.entry { inspections.append(entry) }
      if let proposed = ghostty.proposedOwnership {
        try recordMissingParents(of: URL(filePath: proposed.path))
      }

      let tuicr = try inspectSelector(
        .tuicr, EnvironmentSelectorDocument<EnvironmentTuicrOwnership>.tuicr,
        composition: composition,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        ownership: ownership?.tuicr,
        legacyOwned: legacyOwned[.tuicr, default: false],
        externallyAuthoritative: externallyAuthoritative[.tuicr, default: false]
      )
      if let entry = tuicr.entry { inspections.append(entry) }
      inspections += try preservedPresetLinks(
        .tuicr, in: allowed, legacyOwned: legacyOwned[.tuicr, default: false],
        externallyAuthoritative: externallyAuthoritative[.tuicr, default: false],
        composition: composition)
      if tuicr.proposedOwnership != nil {
        try recordMissingParents(
          of: homeDirectory.appending(path: ConsumerHomePath.tuicrConfiguration))
      }

      for record in ownership?.records ?? [] where !entries.contains(where: { $0.id == record.id })
      {
        let entry = managedEntry(from: record)
        let exact = try managedEntryIsExact(entry)
        inspections.append(
          EnvironmentEntryInspection(
            id: record.id.rawValue,
            path: record.publicPath,
            status: exact ? .restorationRequired : .drifted,
            ownership: "macarchy",
            message: exact
              ? "The disabled provider entry will be restored."
              : "The disabled provider entry drifted before restoration.",
            evidence: nil
          )
        )
      }

      let desiredLean =
        composition.profile.focusRing == .lean
        ? leanService?.configuration ?? ownership?.borders?.leanService : nil
      if composition.profile.focusRing == .lean, desiredLean == nil {
        throw EnvironmentLifecycleError.blocked("Lean service evidence was not inspected")
      }
      let borders = try inspectBorders(
        enabled: composition.profile.focusRing == .borders,
        previous: ownership?.borders,
        homeDirectory: homeDirectory,
        service: bordersService,
        lean: desiredLean,
        leanInspection: leanService?.current
      )
      inspections.append(contentsOf: borders.entries)
      let adoptionRequired = inspections.contains { $0.status == .adoptionRequired }
      return EnvironmentProviderInspection(
        entries: inspections.sorted { $0.id < $1.id },
        ownership: ownership,
        adoptionEvidenceDigest: adoptionRequired
          ? try adoptionDigest(
            composition: composition,
            entries: inspections,
            selected: entries,
            keyOwnedPaths: [
              EnvironmentKeyOwnedFile.btop: btop.proposedOwnership?.path,
              .codex: codex.proposedOwnership?.path,
              .herdr: herdr.proposedOwnership?.path,
              .pi: pi.proposedOwnership?.path,
              .spicetify: spicetify.proposedOwnership?.path,
              .ghostty: ghostty.proposedOwnership?.path,
              .zed: zed.proposedOwnership?.path, .zedFamily: zedFamily.proposedOwnership?.path,
              .alacritty: alacritty.proposedOwnership?.path,
              .tuicr: tuicr.proposedOwnership?.path,
            ].compactMapValues { $0 },
            borders: borders.ownership,
            bordersService: bordersService
          ) : nil,
        blockedMessage: nil,
        desiredEntries: entries,
        externalEvidence: evidence,
        createdDirectories: createdDirectories.sorted(),
        proposedBtopOwnership: btop.proposedOwnership,
        proposedCodexOwnership: codex.proposedOwnership,
        proposedHerdrOwnership: herdr.proposedOwnership,
        proposedPiOwnership: pi.proposedOwnership,
        proposedSpicetifyOwnership: spicetify.proposedOwnership,
        proposedGhosttyOwnership: ghostty.proposedOwnership,
        proposedZedOwnership: zed.proposedOwnership,
        proposedZedFamilyOwnership: zedFamily.proposedOwnership,
        proposedAlacrittyOwnership: alacritty.proposedOwnership,
        proposedTuicrOwnership: tuicr.proposedOwnership,
        keyOwnedExternalEvidence: [
          EnvironmentKeyOwnedFile.btop: btop.externalEvidence,
          .codex: codex.externalEvidence,
          .herdr: herdr.externalEvidence,
          .pi: pi.externalEvidence,
          .spicetify: spicetify.externalEvidence,
          .ghostty: ghostty.externalEvidence,
          .zed: zed.externalEvidence, .zedFamily: zedFamily.externalEvidence,
          .alacritty: alacritty.externalEvidence,
          .tuicr: tuicr.externalEvidence,
        ].compactMapValues { $0 },
        proposedBordersOwnership: borders.ownership,
        bordersServiceInspection: bordersService,
        leanServiceInspection: leanService,
        standardNativeEntries: standardNativeEntries
      )
    } catch {
      return .blocked(error)
    }
  }

  func desiredEntries(
    profile: EnvironmentProfile,
    homeDirectory: URL,
    stateRoot: URL,
    retainBorders: Bool = false
  ) -> [EnvironmentManagedEntry] {
    var enabled = Set<EnvironmentEntryID>()
    if profile.focusRing == .borders || (profile.focusRing == .lean && retainBorders) {
      let directory = homeDirectory.appending(path: ".config/borders")
      var metadata = stat()
      let directoryIsLink =
        lstat(directory.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK
      enabled.insert(directoryIsLink ? .bordersDirectory : .bordersConfiguration)
    }
    if profile.terminal == .kitty { enabled.insert(.kitty) }
    if profile.shell == .zsh { enabled.insert(.zsh) }
    if profile.prompt == .starship { enabled.insert(.starship) }
    if profile.history == .atuin {
      enabled.formUnion([.atuinConfiguration, .atuinTheme])
    }
    if profile.editor == .neovim { enabled.insert(.neovim) }
    for tool in EnvironmentDailyTool.allCases where tool.isEnabled(in: profile.tools) {
      enabled.formUnion(tool.entryIDs)
    }
    for linked in EnvironmentLinkedPreset.allCases
    where linked.preset.isEnabled(in: profile.presets) {
      enabled.formUnion(linked.themeLinks)
    }
    return EnvironmentManagedEntry.all(homeDirectory: homeDirectory, stateRoot: stateRoot)
      .filter { enabled.contains($0.id) }
  }

  func capture(
    _ url: URL,
    directoryLink: EnvironmentDirectoryLinkKind?
  ) throws -> EnvironmentEntryEvidence {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT {
        return EnvironmentEntryEvidence.absent
      }
      throw EnvironmentLifecycleError.system("inspect provider entry", url, errno)
    }
    return try entryEvidence(
      of: url,
      metadata: metadata,
      directoryLink: directoryLink,
      linkDestination: { try FileManager.default.destinationOfSymbolicLink(atPath: url.path) },
      contents: {
        try BoundedRegularFile.read(at: url, maximumSize: Self.maximumExternalFileSize).data
      },
      digestMetadata: { try metadataDigest(at: url, symbolicLink: $0) }
    )
  }

  func managedEntryIsExact(_ entry: EnvironmentManagedEntry) throws -> Bool {
    let parent: Int32
    do {
      parent = try PinnedFilesystem.openDirectory(at: entry.url.deletingLastPathComponent())
    } catch let error as PinnedFilesystemError where error.code == ENOENT || error.code == ENOTDIR {
      return false
    }
    defer { Darwin.close(parent) }
    return try managedEntryIsExact(entry, parentDescriptor: parent)
  }

  func managedEntryIsExact(
    _ entry: EnvironmentManagedEntry,
    parentDescriptor: Int32
  ) throws -> Bool {
    var metadata = stat()
    let inspected = entry.url.lastPathComponent.withCString {
      Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard inspected == 0 else {
      if errno == ENOENT { return false }
      throw EnvironmentLifecycleError.system("inspect managed provider entry", entry.url, errno)
    }
    switch entry.kind {
    case .symbolicLink:
      guard metadata.st_mode & S_IFMT == S_IFLNK else { return false }
      return try PinnedFilesystem.symlinkDestination(
        parentDescriptor: parentDescriptor,
        name: entry.url.lastPathComponent,
        url: entry.url
      ) == entry.target
    case .kittyDirectory:
      guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
      let directory = try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: entry.url.lastPathComponent,
        url: entry.url
      )
      defer { Darwin.close(directory) }
      let children = try PinnedFilesystem.directoryEntries(
        descriptor: directory,
        url: entry.url,
        limit: 2
      )
      guard !children.truncated, children.entries == ["kitty.conf"] else { return false }
      let configuration = entry.url.appending(path: "kitty.conf")
      return try PinnedFilesystem.symlinkDestination(
        parentDescriptor: directory,
        name: "kitty.conf",
        url: configuration
      ) == entry.target
    }
  }

  func capturePinned(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    directoryLink: EnvironmentDirectoryLinkKind?
  ) throws -> EnvironmentEntryEvidence {
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return EnvironmentEntryEvidence.absent
    }
    return try entryEvidence(
      of: url,
      metadata: metadata,
      directoryLink: directoryLink,
      linkDestination: {
        try PinnedFilesystem.symlinkDestination(
          parentDescriptor: parentDescriptor, name: name, url: url)
      },
      contents: {
        try PinnedFilesystem.readRegularFile(
          parentDescriptor: parentDescriptor,
          name: name,
          url: url,
          maximumSize: Self.maximumExternalFileSize
        ).data
      },
      digestMetadata: {
        try metadataDigest(
          parentDescriptor: parentDescriptor, name: name, url: url, symbolicLink: $0)
      }
    )
  }

  /// Builds an entry's evidence from its metadata; the closures read the link, contents and
  /// metadata digest through the caller's path or pinned parent descriptor.
  private func entryEvidence(
    of url: URL,
    metadata: stat,
    directoryLink: EnvironmentDirectoryLinkKind?,
    linkDestination: () throws -> String,
    contents: () throws -> Data,
    digestMetadata: (_ symbolicLink: Bool) throws -> String
  ) throws -> EnvironmentEntryEvidence {
    let common = (
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      mode: UInt32(metadata.st_mode),
      size: Int64(metadata.st_size)
    )
    switch metadata.st_mode & S_IFMT {
    case S_IFLNK:
      let destination = try linkDestination()
      return EnvironmentEntryEvidence(
        kind: .symbolicLink,
        device: common.device,
        inode: common.inode,
        mode: common.mode,
        size: common.size,
        linkDestination: destination,
        contentDigest: nil,
        metadataDigest: try digestMetadata(true),
        inventory: try directoryLink.map {
          try nativeDirectoryInventory(link: url, destination: destination, kind: $0)
        } ?? []
      )
    case S_IFREG where directoryLink == nil:
      guard metadata.st_nlink == 1 else {
        throw EnvironmentLifecycleError.blocked("\(url.path) is hard-linked")
      }
      let data = try contents()
      return EnvironmentEntryEvidence(
        kind: .regularFile,
        device: common.device,
        inode: common.inode,
        mode: common.mode,
        size: common.size,
        linkDestination: nil,
        contentDigest: sha256Digest(data),
        metadataDigest: try digestMetadata(false),
        inventory: []
      )
    default:
      throw EnvironmentLifecycleError.blocked(
        "\(url.path) has an unsupported provider entry type"
      )
    }
  }

  func managedEntry(from record: EnvironmentOwnershipRecord) -> EnvironmentManagedEntry {
    EnvironmentManagedEntry(
      id: record.id,
      url: URL(filePath: record.publicPath),
      kind: record.managedKind == EnvironmentManagedEntry.ManagedKind.kittyDirectory.rawValue
        ? .kittyDirectory : .symbolicLink,
      target: record.managedTarget
    )
  }

  private func adoptionDigest(
    composition: EnvironmentComposition,
    entries: [EnvironmentEntryInspection],
    selected: [EnvironmentManagedEntry],
    keyOwnedPaths: [EnvironmentKeyOwnedFile: String],
    borders: EnvironmentBordersOwnership?,
    bordersService: BordersServiceInspection?
  ) throws -> String {
    struct Payload: Encodable {
      let schemaVersion: Int
      let inputDigest: String
      let renderedDigest: String
      let providers: [String]
      let entries: [Entry]
      let borders: EnvironmentBordersOwnership?
      let bordersService: BordersServiceInspection?

      struct Entry: Encodable {
        let id: String
        let path: String
        let target: String
        let evidence: EnvironmentEntryEvidence?
      }
    }
    var targets = Dictionary(uniqueKeysWithValues: selected.map { ($0.id.rawValue, $0.target) })
    for (file, path) in keyOwnedPaths {
      targets[file.entryID] = "\(file.adoptionTargetPrefix)\(path)"
    }
    let payload = Payload(
      schemaVersion: 1,
      inputDigest: composition.inputDigest,
      renderedDigest: composition.renderedDigest,
      providers: [
        composition.profile.focusRing.rawValue,
        composition.profile.terminal.rawValue,
        composition.profile.shell.rawValue,
        composition.profile.prompt.rawValue,
        composition.profile.history.rawValue,
        composition.profile.editor.rawValue,
      ]
        + EnvironmentDailyTool.allCases.map {
          $0.isEnabled(in: composition.profile.tools) ? $0.rawValue : "\($0.rawValue)-disabled"
        }
        + EnvironmentPreset.allCases.map {
          $0.isEnabled(in: composition.profile.presets) ? $0.rawValue : "\($0.rawValue)-disabled"
        },
      entries: entries.filter { targets[$0.id] != nil }.map {
        Payload.Entry(
          id: $0.id,
          path: $0.path,
          target: targets[$0.id, default: ""],
          evidence: $0.evidence
        )
      }.sorted { $0.id < $1.id },
      borders: borders,
      bordersService: bordersService
    )
    return try canonicalJSONDigest(payload)
  }

  private func externalEntryIsExact(
    _ entry: EnvironmentManagedEntry,
    evidence: EnvironmentEntryEvidence,
    composition: EnvironmentComposition
  ) throws -> Bool {
    switch entry.id {
    case .atuinTheme, .batTheme, .btopTheme, .codexTheme, .ezaTheme, .piTheme,
      .spicetifyColor, .tuicrTheme,
      .tuicrSyntax,
      .yaziFlavor, .yaziSyntax:
      return evidence.kind == .symbolicLink && evidence.linkDestination == entry.target
    case .batConfiguration:
      guard evidence.kind == .regularFile else { return false }
      let text = try configurationText(at: entry.url, evidence: evidence)
      let directives = text.split(whereSeparator: \Character.isNewline).filter {
        let line = $0.trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("--theme=") || line.hasPrefix("--theme ")
      }
      return directives.map { $0.trimmingCharacters(in: .whitespaces) }
        == [BatAdapter.themeDirective]
    case .yaziConfiguration:
      guard evidence.kind == .regularFile else { return false }
      let text = try configurationText(at: entry.url, evidence: evidence)
      try validateTOML(text, source: entry.url)
      return CanonicalTOMLSelector(
        configuration: text,
        table: "mgr",
        key: "show_hidden"
      ).selectsExactly(String(composition.profile.yazi.showHidden ?? true))
    case .yaziThemeSelection:
      guard evidence.kind == .regularFile else { return false }
      let text = try configurationText(at: entry.url, evidence: evidence)
      try validateTOML(text, source: entry.url)
      return CanonicalTOMLSelector(
        configuration: text,
        table: YaziAdapter.selectionTable,
        key: YaziAdapter.selectionKey
      ).selectsExactly("\"\(YaziAdapter.flavorName)\"")
    default:
      return false
    }
  }

  /// Resolves a native file provider's behavior source and enforces its connection rules.
  private func nativeFileConnection(
    _ migration: EnvironmentNativeFileMigration,
    configured: URL?,
    selected: Bool,
    ownership: EnvironmentOwnership?
  ) throws -> (source: URL?, isStandard: Bool) {
    let provider = migration.provider
    let source = configured ?? migration.nativeTarget(in: ownership)
    let isStandard = source?.path == migration.publicURL.path
    if ownership?.standardNativeEntries?.contains(provider.entryID) == true, !isStandard {
      throw EnvironmentLifecycleError.blocked(
        "\(provider.label) is user-owned at its standard path; changing that connection requires a reviewed migration"
      )
    }
    if selected, let source {
      if !proposedNativeSources.contains(source.path) {
        try migration.validateNativeFile(at: source, userOwnedPublicEntry: isStandard)
      }
      if let record = ownership?.records.first(where: { $0.id == provider.entryID }),
        record.managedTarget != source.path
      {
        throw EnvironmentLifecycleError.blocked(
          "\(provider.label) source changed; review environment migrate-\(provider.rawValue) --source before applying this profile"
        )
      }
    }
    return (source, isStandard)
  }

  /// Inspects the theme links a preset keeps outside environment ownership: its working legacy
  /// setup-owned links, or its exact external tuple while the preset is disabled.
  private func preservedPresetLinks(
    _ linked: EnvironmentLinkedPreset,
    in allowed: [EnvironmentEntryID: EnvironmentManagedEntry],
    legacyOwned: Bool,
    externallyAuthoritative: Bool,
    composition: EnvironmentComposition
  ) throws -> [EnvironmentEntryInspection] {
    let entries = linked.themeLinks.map { allowed[$0]! }
    var inspections = [EnvironmentEntryInspection]()
    if legacyOwned {
      for entry in entries {
        guard try managedEntryIsExact(entry) else {
          throw EnvironmentLifecycleError.drift("legacy setup-owned \(entry.id.rawValue)")
        }
        inspections.append(
          EnvironmentEntryInspection(
            id: entry.id.rawValue,
            path: entry.url.path,
            status: .external,
            ownership: "legacy_setup",
            message:
              "The working legacy setup-owned \(linked.inspectionWording.legacyLink) is preserved.",
            evidence: nil
          )
        )
      }
    }
    if externallyAuthoritative, !linked.preset.isEnabled(in: composition.profile.presets) {
      for entry in entries {
        let captured = try capture(entry.url, directoryLink: nil)
        guard try externalEntryIsExact(entry, evidence: captured, composition: composition) else {
          throw EnvironmentLifecycleError.drift("externally owned \(entry.id.rawValue)")
        }
        inspections.append(
          EnvironmentEntryInspection(
            id: entry.id.rawValue,
            path: entry.url.path,
            status: .external,
            ownership: "external_exact",
            message:
              "The exact \(linked.file.label) tuple remains externally owned until disablement.",
            evidence: captured
          )
        )
      }
    }
    return inspections
  }

  private static func isDailyToolEntry(_ id: EnvironmentEntryID) -> Bool {
    switch id {
    case .batConfiguration, .batTheme, .btopConfiguration, .btopTheme, .codexConfiguration,
      .codexTheme, .ezaTheme,
      .piConfiguration, .piTheme, .spicetifyColor, .tuicrConfiguration, .tuicrTheme,
      .tuicrSyntax,
      .yaziConfiguration, .yaziThemeSelection, .yaziFlavor, .yaziSyntax:
      true
    case .kitty, .zsh, .starship, .atuinConfiguration, .atuinTheme, .neovim,
      .bordersDirectory, .bordersConfiguration:
      false
    }
  }

  typealias KeyOwnedInspection<Ownership> = (
    entry: EnvironmentEntryInspection?,
    proposedOwnership: Ownership?,
    externalEvidence: EnvironmentEntryEvidence?
  )

  /// Inspects a linked preset's key-owned selector file. Legacy setup ownership, Macarchy's own
  /// ownership and an externally authoritative tuple are judged alike for every linked preset;
  /// `inspectUnowned` judges the enabled preset's file when none of those govern it.
  func inspectLinkedSelector<Ownership: EnvironmentStaticPresetFileOwnership>(
    _ linked: EnvironmentLinkedPreset,
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    ownership: Ownership?,
    legacyOwned: Bool,
    externallyAuthoritative: Bool,
    isManaged: (URL, EnvironmentEntryEvidence) throws -> Bool,
    inspectUnowned: (
      _ url: URL, _ evidence: EnvironmentEntryEvidence, _ hasExternalAncestor: Bool
    ) throws -> KeyOwnedInspection<Ownership>
  ) throws -> KeyOwnedInspection<Ownership> {
    let enabled = linked.preset.isEnabled(in: composition.profile.presets)
    guard enabled || ownership != nil || legacyOwned || externallyAuthoritative else {
      return (nil, nil, nil)
    }
    let url = homeDirectory.appending(path: linked.file.configurationPath)
    let wording = linked.inspectionWording
    func entry(
      _ status: EnvironmentInspectionStatus, owner: String, message: String,
      evidence: EnvironmentEntryEvidence?
    ) -> EnvironmentEntryInspection {
      EnvironmentEntryInspection(
        id: linked.file.entryID, path: url.path, status: status, ownership: owner,
        message: message, evidence: evidence)
    }
    if legacyOwned {
      let evidence = try capture(url, directoryLink: nil)
      guard evidence.kind == .regularFile, try isManaged(url, evidence) else {
        throw EnvironmentLifecycleError.drift(wording.legacyDrift)
      }
      return (
        entry(
          .external, owner: "legacy_setup", message: wording.legacyPreserved, evidence: evidence),
        nil, nil
      )
    }
    if let ownership {
      guard ownership.path == url.path,
        try !hasSymlinkAncestor(url, stoppingAt: homeDirectory)
      else {
        throw EnvironmentLifecycleError.blocked("\(linked.file.label) ownership path is invalid")
      }
      let evidence = try capture(url, directoryLink: nil)
      let exact = try evidence.kind == .regularFile && isManaged(url, evidence)
      return (
        entry(
          exact ? (enabled ? .managed : .restorationRequired) : .drifted, owner: "macarchy",
          message: exact ? (enabled ? wording.managed : wording.restored) : wording.drifted,
          evidence: nil),
        enabled ? ownership : nil,
        nil
      )
    }
    if externallyAuthoritative {
      let evidence = try capture(url, directoryLink: nil)
      let exact = try externalTupleIsExact(
        linked, homeDirectory: homeDirectory, stateRoot: stateRoot,
        configurationEvidence: evidence)
      return (
        entry(
          exact ? .external : .drifted, owner: "external_exact",
          message: exact
            ? wording.externalTupleExact
            : "The externally owned \(linked.file.label) tuple drifted.",
          evidence: evidence),
        nil, nil
      )
    }
    guard enabled else { return (nil, nil, nil) }
    let evidence = try capture(url, directoryLink: nil)
    let externalAncestor = try hasSymlinkAncestor(url, stoppingAt: homeDirectory)
    return try inspectUnowned(url, evidence, externalAncestor)
  }

  /// Inspects the Codex, Pi or tuicr selector file through its document rules.
  private func inspectSelector<Ownership: EnvironmentStaticPresetFileOwnership>(
    _ linked: EnvironmentLinkedPreset,
    _ document: EnvironmentSelectorDocument<Ownership>,
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    ownership: Ownership?,
    legacyOwned: Bool,
    externallyAuthoritative: Bool
  ) throws -> KeyOwnedInspection<Ownership> {
    try inspectLinkedSelector(
      linked, composition: composition, homeDirectory: homeDirectory, stateRoot: stateRoot,
      ownership: ownership, legacyOwned: legacyOwned,
      externallyAuthoritative: externallyAuthoritative,
      isManaged: { url, evidence in
        try Ownership.matchesManaged(
          selectorData(document, at: url, evidence: evidence, hasExternalAncestor: false),
          at: url)
      },
      inspectUnowned: { url, evidence, externalAncestor in
        try inspectUnownedSelector(
          linked, document, at: url, evidence: evidence, hasExternalAncestor: externalAncestor,
          homeDirectory: homeDirectory, stateRoot: stateRoot)
      })
  }

  /// An external symlink must carry the exact selector and links, an ordinary file is exact or
  /// adopted, and an absent file is installed.
  private func inspectUnownedSelector<Ownership: EnvironmentStaticPresetFileOwnership>(
    _ linked: EnvironmentLinkedPreset,
    _ document: EnvironmentSelectorDocument<Ownership>,
    at url: URL,
    evidence: EnvironmentEntryEvidence,
    hasExternalAncestor externalAncestor: Bool,
    homeDirectory: URL,
    stateRoot: URL
  ) throws -> KeyOwnedInspection<Ownership> {
    func entry(
      _ status: EnvironmentInspectionStatus, owner: String, message: String
    ) -> EnvironmentEntryInspection {
      EnvironmentEntryInspection(
        id: linked.file.entryID, path: url.path, status: status, ownership: owner,
        message: message, evidence: evidence)
    }
    if evidence.kind == .symbolicLink || externalAncestor {
      let data = try selectorData(
        document, at: url, evidence: evidence, hasExternalAncestor: externalAncestor)
      guard try Ownership.matchesManaged(data, at: url) else {
        return (
          entry(
            .unsupported, owner: "external",
            message:
              "A divergent \(linked.file.label) selector is behind an externally owned symlink."),
          nil, nil
        )
      }
      guard
        try externalLinksAreExact(
          Set(linked.themeLinks), homeDirectory: homeDirectory, stateRoot: stateRoot)
      else {
        return (entry(.unsupported, owner: "external", message: document.linksRequired), nil, nil)
      }
      return (
        entry(.external, owner: "external_exact", message: document.linkedExact), nil, evidence
      )
    }
    if evidence.kind == .regularFile {
      let data = try selectorData(document, at: url, evidence: evidence, hasExternalAncestor: false)
      if try Ownership.matchesManaged(data, at: url) {
        return (
          entry(.external, owner: "external_exact", message: document.selectorExact), nil, nil
        )
      }
      let proposed = try document.adopting(data, url)
      return (
        entry(.adoptionRequired, owner: "external", message: document.adoption), proposed, evidence
      )
    }
    // An external ancestor was judged above, so an absent file has only owned parents.
    if evidence.kind == .absent {
      return (
        entry(.installRequired, owner: "external", message: document.installation),
        document.installing(url), evidence
      )
    }
    return (entry(.unsupported, owner: "external", message: document.unsupported), nil, nil)
  }

  /// Reads a selector file, following an external symlink chain when one owns it. A text
  /// selector must decode as UTF-8, and each read path reports that failure in its own words.
  private func selectorData<Ownership: EnvironmentStaticPresetFileOwnership>(
    _ document: EnvironmentSelectorDocument<Ownership>,
    at url: URL,
    evidence: EnvironmentEntryEvidence,
    hasExternalAncestor: Bool
  ) throws -> Data {
    let label = Ownership.filesystem.configurationLabel
    guard evidence.kind == .symbolicLink || hasExternalAncestor else {
      return document.isText
        ? Data(try configurationText(at: url, evidence: evidence).utf8)
        : try configurationData(at: url, evidence: evidence)
    }
    return document.isText
      ? Data(
        try externalConfigurationText(
          at: url, evidence: evidence, hasExternalAncestor: hasExternalAncestor, label: label
        ).utf8)
      : try externalConfigurationData(
        at: url, evidence: evidence, hasExternalAncestor: hasExternalAncestor, label: label)
  }

  private func selectorTupleIsExact<Ownership: EnvironmentStaticPresetFileOwnership>(
    _ linked: EnvironmentLinkedPreset,
    _ document: EnvironmentSelectorDocument<Ownership>,
    homeDirectory: URL,
    stateRoot: URL,
    configurationEvidence: EnvironmentEntryEvidence?
  ) throws -> Bool {
    let configuration = homeDirectory.appending(path: linked.file.configurationPath)
    return try externalTupleIsExact(
      configuration: configuration,
      links: Set(linked.themeLinks),
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      configurationEvidence: configurationEvidence
    ) { evidence, externalAncestor in
      try Ownership.matchesManaged(
        selectorData(
          document, at: configuration, evidence: evidence, hasExternalAncestor: externalAncestor),
        at: configuration)
    }
  }

  /// Whether the linked preset's configuration and theme links still form its exact external
  /// tuple.
  func externalTupleIsExact(
    _ linked: EnvironmentLinkedPreset,
    homeDirectory: URL,
    stateRoot: URL,
    configurationEvidence: EnvironmentEntryEvidence? = nil
  ) throws -> Bool {
    switch linked {
    case .codex:
      try selectorTupleIsExact(
        linked, EnvironmentSelectorDocument<EnvironmentCodexOwnership>.codex,
        homeDirectory: homeDirectory, stateRoot: stateRoot,
        configurationEvidence: configurationEvidence)
    case .pi:
      try selectorTupleIsExact(
        linked, EnvironmentSelectorDocument<EnvironmentPiOwnership>.pi,
        homeDirectory: homeDirectory, stateRoot: stateRoot,
        configurationEvidence: configurationEvidence)
    case .spicetify:
      try spicetifyExternalTupleIsExact(
        homeDirectory: homeDirectory, stateRoot: stateRoot,
        configurationEvidence: configurationEvidence)
    case .tuicr:
      try selectorTupleIsExact(
        linked, EnvironmentSelectorDocument<EnvironmentTuicrOwnership>.tuicr,
        homeDirectory: homeDirectory, stateRoot: stateRoot,
        configurationEvidence: configurationEvidence)
    }
  }

  func configurationText(
    at url: URL,
    evidence: EnvironmentEntryEvidence
  ) throws -> String {
    let data = try configurationData(at: url, evidence: evidence)
    guard let text = String(data: data, encoding: .utf8)
    else {
      throw EnvironmentLifecycleError.blocked(
        "provider configuration changed during inspection: \(url.path)"
      )
    }
    return text
  }

  private func configurationData(
    at url: URL,
    evidence: EnvironmentEntryEvidence
  ) throws -> Data {
    let data = try BoundedRegularFile.read(at: url).data
    guard sha256Digest(data) == evidence.contentDigest else {
      throw EnvironmentLifecycleError.blocked(
        "provider configuration changed during inspection: \(url.path)"
      )
    }
    return data
  }

  private func validateTOML(_ text: String, source: URL) throws {
    do {
      _ = try TOMLTable(source: text)
    } catch {
      throw EnvironmentLifecycleError.blocked(
        "invalid TOML configuration at \(source.path): \(error)"
      )
    }
  }

  private func inspectExternalEzaEnvironment(
    homeDirectory: URL,
    configurationDirectory: URL
  ) throws -> EnvironmentEntryInspection {
    let shell = homeDirectory.appending(path: ConsumerHomePath.shellConfiguration)
    let evidence = try capture(shell, directoryLink: nil)
    let text: String
    switch evidence.kind {
    case .regularFile:
      text = try configurationText(at: shell, evidence: evidence)
    case .symbolicLink:
      let resolved = shell.resolvingSymlinksInPath()
      let data = try BoundedRegularFile.read(at: resolved).data
      guard let value = String(data: data, encoding: .utf8) else {
        throw EnvironmentLifecycleError.blocked("external zsh configuration is not UTF-8")
      }
      text = value
    case .absent:
      return EnvironmentEntryInspection(
        id: "eza_environment",
        path: shell.path,
        status: .unsupported,
        ownership: "external",
        message: "Eza requires an external EZA_CONFIG_DIR directive when zsh is disabled.",
        evidence: evidence
      )
    }
    let directives = [
      EzaAdapter.environmentDirective(configurationDirectoryURL: configurationDirectory),
      "export EZA_CONFIG_DIR=\"$HOME/.config/eza\"",
    ]
    let exact = directives.contains { directive in
      text.components(separatedBy: .newlines).contains {
        $0.trimmingCharacters(in: .whitespaces) == directive
      }
    }
    return EnvironmentEntryInspection(
      id: "eza_environment",
      path: shell.path,
      status: exact ? .external : .unsupported,
      ownership: "external_exact",
      message: exact
        ? "The external shell selects the managed Eza configuration directory."
        : "Eza requires an exact external EZA_CONFIG_DIR directive when zsh is disabled.",
      evidence: evidence
    )
  }

  private func inspectBtop(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    ownership: EnvironmentBtopOwnership?,
    ownershipGenerationID: String?
  ) throws -> (
    entry: EnvironmentEntryInspection?,
    proposedOwnership: EnvironmentBtopOwnership?,
    externalEvidence: EnvironmentEntryEvidence?
  ) {
    guard composition.profile.tools.btop || ownership != nil else { return (nil, nil, nil) }
    let url = homeDirectory.appending(path: ConsumerHomePath.btopConfiguration)
    if let ownership {
      guard let ownershipGenerationID else {
        throw EnvironmentLifecycleError.blocked("btop ownership has no generation")
      }
      guard ownership.path == url.path,
        try !hasSymlinkAncestor(url, stoppingAt: homeDirectory)
      else {
        throw EnvironmentLifecycleError.blocked("btop ownership path is invalid")
      }
      let evidence = try capture(url, directoryLink: nil)
      let state = try EnvironmentBtopFileTransaction(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ).generationState(ownershipGenerationID)
      let exact: Bool
      if evidence.kind == .regularFile {
        exact = try EnvironmentBtopDocument.matchesManaged(
          configurationText(at: url, evidence: evidence),
          values: state.values,
          source: url
        )
      } else {
        exact = false
      }
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.btopConfiguration.rawValue,
          path: url.path,
          status: exact
            ? (composition.profile.tools.btop ? .managed : .restorationRequired) : .drifted,
          ownership: "macarchy",
          message: exact
            ? (composition.profile.tools.btop
              ? "The owned btop keys are managed."
              : "The disabled btop keys will be restored.")
            : "The owned btop keys drifted.",
          evidence: nil
        ),
        composition.profile.tools.btop ? ownership : nil,
        nil
      )
    }

    guard composition.profile.tools.btop else { return (nil, nil, nil) }
    let artifactURL = StateLayout(root: stateRoot).environmentArtifact("btop/btop.conf")
    guard let artifact = composition.artifacts.first(where: { $0.path == "btop/btop.conf" }) else {
      throw EnvironmentLifecycleError.blocked("missing rendered btop configuration")
    }
    guard let artifactText = artifact.textContents else {
      throw EnvironmentLifecycleError.blocked("rendered btop configuration is not UTF-8")
    }
    let desired = try EnvironmentBtopDocument.desiredValues(
      in: artifactText,
      source: artifactURL
    )
    let evidence = try capture(url, directoryLink: nil)
    let externalAncestor = try hasSymlinkAncestor(url, stoppingAt: homeDirectory)
    if evidence.kind == .regularFile {
      let text = try configurationText(at: url, evidence: evidence)
      if try EnvironmentBtopDocument.matchesManaged(text, values: desired, source: url) {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.btopConfiguration.rawValue,
            path: url.path,
            status: .external,
            ownership: "external_exact",
            message: "The exact btop keys remain externally owned.",
            evidence: evidence
          ), nil, nil
        )
      }
      if externalAncestor {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.btopConfiguration.rawValue,
            path: url.path,
            status: .unsupported,
            ownership: "external",
            message: "Divergent btop keys are below a symlink-owned provider directory.",
            evidence: evidence
          ), nil, nil
        )
      }
      let proposed = EnvironmentBtopOwnership(
        path: url.path,
        originalFileExisted: true,
        originalAssignments: try EnvironmentBtopDocument.originalAssignments(
          in: text,
          source: url
        )
      )
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.btopConfiguration.rawValue,
          path: url.path,
          status: .adoptionRequired,
          ownership: "external",
          message: "The existing btop keys require reviewed adoption.",
          evidence: evidence
        ), proposed, evidence
      )
    }
    if evidence.kind == .absent, !externalAncestor {
      let proposed = EnvironmentBtopOwnership(
        path: url.path,
        originalFileExisted: false,
        originalAssignments: EnvironmentBtopDocument.ownedKeys.map {
          EnvironmentBtopOriginalAssignment(key: $0, line: nil)
        }
      )
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.btopConfiguration.rawValue,
          path: url.path,
          status: .installRequired,
          ownership: "external",
          message: "The btop baseline will be installed.",
          evidence: evidence
        ), proposed, evidence
      )
    }
    return (
      EnvironmentEntryInspection(
        id: EnvironmentEntryID.btopConfiguration.rawValue,
        path: url.path,
        status: .unsupported,
        ownership: "external",
        message: "The btop configuration cannot be safely adopted.",
        evidence: evidence
      ), nil, nil
    )
  }

  /// Whether a key-owned preset's configuration and theme links still form its exact external
  /// tuple; `matches` reads the configuration through any external symlink chain.
  private func externalTupleIsExact(
    configuration: URL,
    links: Set<EnvironmentEntryID>,
    homeDirectory: URL,
    stateRoot: URL,
    configurationEvidence: EnvironmentEntryEvidence?,
    matches: (_ evidence: EnvironmentEntryEvidence, _ hasExternalAncestor: Bool) throws -> Bool
  ) throws -> Bool {
    let evidence = try configurationEvidence ?? capture(configuration, directoryLink: nil)
    let externalAncestor = try hasSymlinkAncestor(configuration, stoppingAt: homeDirectory)
    guard evidence.kind == .regularFile || evidence.kind == .symbolicLink else { return false }
    return try matches(evidence, externalAncestor)
      && externalLinksAreExact(links, homeDirectory: homeDirectory, stateRoot: stateRoot)
  }

  func externalLinksAreExact(
    _ ids: Set<EnvironmentEntryID>,
    homeDirectory: URL,
    stateRoot: URL
  ) throws -> Bool {
    let entries = EnvironmentManagedEntry.all(homeDirectory: homeDirectory, stateRoot: stateRoot)
      .filter { ids.contains($0.id) }
    guard entries.count == ids.count else { return false }
    for entry in entries {
      let evidence = try capture(entry.url, directoryLink: nil)
      guard evidence.kind == .symbolicLink, evidence.linkDestination == entry.target else {
        return false
      }
    }
    return true
  }

  private func externalConfigurationText(
    at url: URL,
    evidence: EnvironmentEntryEvidence,
    hasExternalAncestor: Bool,
    label: String
  ) throws -> String {
    let configuration = try externalConfiguration(
      at: url,
      evidence: evidence,
      hasExternalAncestor: hasExternalAncestor,
      label: label
    )
    guard let text = String(data: configuration.data, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked(
        "\(label) symlink target is not UTF-8: \(configuration.target.path)"
      )
    }
    return text
  }

  private func externalConfigurationData(
    at url: URL,
    evidence: EnvironmentEntryEvidence,
    hasExternalAncestor: Bool,
    label: String
  ) throws -> Data {
    try externalConfiguration(
      at: url,
      evidence: evidence,
      hasExternalAncestor: hasExternalAncestor,
      label: label
    ).data
  }

  private func externalConfiguration(
    at url: URL,
    evidence: EnvironmentEntryEvidence,
    hasExternalAncestor: Bool,
    label: String
  ) throws -> (data: Data, target: URL) {
    guard evidence.kind == .symbolicLink || hasExternalAncestor else {
      return (try configurationData(at: url, evidence: evidence), url)
    }
    let firstTarget = try resolvedExternalTarget(url, label: label)
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: firstTarget).data
    } catch {
      throw EnvironmentLifecycleError.blocked(
        "\(label) symlink target is not a bounded regular file: \(error)"
      )
    }
    let secondTarget = try resolvedExternalTarget(url, label: label)
    guard firstTarget == secondTarget,
      try capture(url, directoryLink: nil) == evidence
    else {
      throw EnvironmentLifecycleError.blocked(
        "\(label) symlink chain changed during inspection"
      )
    }
    return (data, firstTarget)
  }

  private func resolvedExternalTarget(_ url: URL, label: String) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let resolved = url.path.withCString { Darwin.realpath($0, &buffer) }
    guard resolved != nil else {
      throw EnvironmentLifecycleError.system(
        "resolve \(label) symlink chain", url, errno)
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard let path = String(bytes: bytes, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked(
        "\(label) symlink chain is not valid UTF-8"
      )
    }
    return URL(filePath: path).standardizedFileURL
  }

  private func nativeDirectoryInventory(
    link: URL,
    destination: String,
    kind: EnvironmentDirectoryLinkKind
  ) throws -> [String] {
    let root =
      destination.hasPrefix("/")
      ? URL(filePath: destination)
      : link.deletingLastPathComponent().appending(path: destination)
    var rootMetadata = stat()
    guard stat(root.path, &rootMetadata) == 0,
      rootMetadata.st_mode & S_IFMT == S_IFDIR
    else {
      throw EnvironmentLifecycleError.blocked(
        "\(kind.rawValue) directory link target is not a directory"
      )
    }
    let inventoryRoot = root.resolvingSymlinksInPath().standardizedFileURL
    guard
      let enumerator = FileManager.default.enumerator(
        at: inventoryRoot,
        includingPropertiesForKeys: nil,
        options: []
      )
    else {
      throw EnvironmentLifecycleError.blocked(
        "cannot inventory \(kind.rawValue) directory link target"
      )
    }
    var result = [String]()
    var bytes = 0
    let rootPath = inventoryRoot.path + "/"
    for case let item as URL in enumerator {
      guard result.count < kind.maximumEntries else {
        throw EnvironmentLifecycleError.blocked(
          "\(kind.rawValue) directory inventory exceeds \(kind.maximumEntries) entries"
        )
      }
      var metadata = stat()
      guard lstat(item.path, &metadata) == 0 else {
        throw EnvironmentLifecycleError.system("inventory \(kind.rawValue) entry", item, errno)
      }
      let itemPath = item.standardizedFileURL.path
      guard itemPath.hasPrefix(rootPath) else {
        throw EnvironmentLifecycleError.blocked(
          "\(kind.rawValue) directory inventory escaped its root"
        )
      }
      let relative = String(itemPath.dropFirst(rootPath.count))
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR:
        result.append("directory:\(relative)")
      case S_IFLNK:
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
        result.append("symlink:\(relative):\(target)")
      case S_IFREG:
        let data = try BoundedRegularFile.read(
          at: item,
          maximumSize: Self.maximumExternalFileSize
        ).data
        bytes += data.count
        guard bytes <= kind.maximumBytes else {
          throw EnvironmentLifecycleError.blocked(
            "\(kind.rawValue) directory inventory exceeds \(kind.maximumBytes / 1_048_576) MiB"
          )
        }
        result.append("file:\(relative):\(sha256Digest(data))")
      default:
        throw EnvironmentLifecycleError.blocked(
          "\(kind.rawValue) directory contains an unsupported entry"
        )
      }
    }
    return result.sorted()
  }

  func hasSymlinkAncestor(_ url: URL, stoppingAt root: URL) throws -> Bool {
    var parent = url.deletingLastPathComponent()
    while parent.path != root.path, parent.path.hasPrefix(root.path + "/") {
      var metadata = stat()
      if lstat(parent.path, &metadata) == 0 {
        if metadata.st_mode & S_IFMT == S_IFLNK { return true }
      } else if errno != ENOENT {
        throw EnvironmentLifecycleError.system("inspect provider ancestor", parent, errno)
      }
      parent.deleteLastPathComponent()
    }
    return false
  }

  private func metadataDigest(at url: URL, symbolicLink: Bool) throws -> String {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | (symbolicLink ? O_SYMLINK : O_NOFOLLOW))
    }
    guard descriptor >= 0 else {
      throw EnvironmentLifecycleError.system("open provider metadata", url, errno)
    }
    defer { Darwin.close(descriptor) }
    return try SetupOwnershipManager().regularFileSnapshot(
      descriptor: descriptor,
      url: url,
      label: "environment provider entry"
    ).restorableMetadataDigest(excludingExtendedAttribute: "com.apple.provenance")
  }

  private func metadataDigest(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    symbolicLink: Bool
  ) throws -> String {
    let descriptor = name.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_RDONLY | O_CLOEXEC | (symbolicLink ? O_SYMLINK : O_NOFOLLOW)
      )
    }
    guard descriptor >= 0 else {
      throw EnvironmentLifecycleError.system("open provider metadata", url, errno)
    }
    defer { Darwin.close(descriptor) }
    return try SetupOwnershipManager().regularFileSnapshot(
      descriptor: descriptor,
      url: url,
      label: "environment provider entry"
    ).restorableMetadataDigest(excludingExtendedAttribute: "com.apple.provenance")
  }

  private func missingParentDirectories(of url: URL, homeDirectory: URL) throws -> [URL] {
    let home = homeDirectory.standardizedFileURL
    let parent = url.deletingLastPathComponent().standardizedFileURL
    guard parent.path == home.path || parent.path.hasPrefix(home.path + "/") else {
      throw EnvironmentLifecycleError.blocked("provider entry is outside the selected home")
    }
    var current = home
    var missing = [URL]()
    if parent.path != home.path {
      for component in parent.path.dropFirst(home.path.count + 1).split(separator: "/") {
        current.append(path: String(component), directoryHint: .isDirectory)
        var metadata = stat()
        if lstat(current.path, &metadata) == 0 {
          guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw EnvironmentLifecycleError.blocked(
              "provider ancestor is not a real directory: \(current.path)"
            )
          }
        } else if errno == ENOENT {
          missing.append(current)
        } else {
          throw EnvironmentLifecycleError.system("inspect provider directory", current, errno)
        }
      }
    }
    return missing
  }
}
