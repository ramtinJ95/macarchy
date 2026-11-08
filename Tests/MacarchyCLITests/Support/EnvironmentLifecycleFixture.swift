import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentLifecycleFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL
  let kittyEntry: URL
  let zshEntry: URL
  let starshipEntry: URL
  let atuinConfigEntry: URL
  let atuinThemeEntry: URL
  let atuinHistory: URL
  let kittyTarget: String
  let zshTarget: String
  let starshipTarget: String
  let atuinTarget: String

  private let prerequisites = EnvironmentPrerequisiteInspector.assumed

  init(disabled: Bool = false, externalEntries: Bool = true) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-environment-lifecycle-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = root.appending(path: "profile.toml")
    kittyEntry = home.appending(path: ".config/kitty", directoryHint: .isDirectory)
    zshEntry = home.appending(path: ".zshrc")
    starshipEntry = home.appending(path: ".config/starship.toml")
    atuinConfigEntry = home.appending(path: ".config/atuin/config.toml")
    atuinThemeEntry = home.appending(path: ".config/atuin/themes/macarchy-current.toml")
    atuinHistory = home.appending(path: ".config/atuin/history.db")
    kittyTarget = "../../dotfiles/kitty"
    zshTarget = "../dotfiles/zshrc"
    starshipTarget = "../../dotfiles/starship.toml"
    atuinTarget = "../../../dotfiles/atuin.toml"

    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    if disabled {
      try """
      schema_version = 1
      [focus_ring]
      provider = "disabled"
      [terminal]
      provider = "disabled"
      [shell]
      provider = "disabled"
      [editor]
      provider = "disabled"
      [tools]
      bat = false
      eza = false
      btop = false
      yazi = false
      """.write(to: profile, atomically: true, encoding: .utf8)
      return
    }

    if !externalEntries {
      try
        "schema_version = 1\n[focus_ring]\nprovider = \"disabled\"\n[editor]\nprovider = \"disabled\"\n"
        .write(
          to: profile,
          atomically: true,
          encoding: .utf8
        )
      return
    }

    let dotfiles = root.appending(path: "dotfiles", directoryHint: .isDirectory)
    let kitty = dotfiles.appending(path: "kitty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: kitty, withIntermediateDirectories: true)
    try "font_size 12\n".write(
      to: kitty.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    try "export PERSONAL=1\n".write(
      to: dotfiles.appending(path: "zshrc"),
      atomically: true,
      encoding: .utf8
    )
    try "format = \"$directory\"\n".write(
      to: dotfiles.appending(path: "starship.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "search_mode = \"fuzzy\"\n".write(
      to: dotfiles.appending(path: "atuin.toml"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createDirectory(
      at: home.appending(path: ".config/atuin/themes"),
      withIntermediateDirectories: true
    )
    try "history\n".write(to: atuinHistory, atomically: true, encoding: .utf8)
    try symlink(kittyTarget, kittyEntry.path).requireZero()
    try symlink(zshTarget, zshEntry.path).requireZero()
    try symlink(starshipTarget, starshipEntry.path).requireZero()
    try symlink(atuinTarget, atuinConfigEntry.path).requireZero()
    try
      "schema_version = 1\n[focus_ring]\nprovider = \"disabled\"\n[editor]\nprovider = \"disabled\"\n"
      .write(
        to: profile,
        atomically: true,
        encoding: .utf8
      )
  }

  func plan() throws -> (output: String, succeeded: Bool) {
    try EnvironmentPlanCommandRunner(prerequisites: prerequisites).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
  }

  func apply(
    adopt: String?,
    theme: DesktopThemeController? = nil,
    verifier: EnvironmentSessionVerifier = .assumed,
    neovim: EnvironmentNeovimPreparer = .assumed,
    enabledThemeAdapterIDs: [String]? = nil,
    withinUnifiedSetup: Bool = false,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
  ) async throws -> (output: String, succeeded: Bool) {
    try await EnvironmentApplyCommandRunner(
      prerequisites: prerequisites,
      theme: theme,
      verifier: verifier,
      neovim: neovim,
      transactionFaultInjector: faultInjector
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: testConsumerPaths(),
      adopt: adopt,
      json: true,
      withinUnifiedSetup: withinUnifiedSetup,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs
    )
  }

  func status(theme: DesktopThemeController? = nil) throws -> (output: String, succeeded: Bool) {
    try EnvironmentStatusCommandRunner(
      prerequisites: prerequisites,
      theme: theme
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: testConsumerPaths(),
      json: true
    )
  }

  func teardown(
    dryRun: Bool = false,
    theme: DesktopThemeController? = nil,
    withinUnifiedSetup: Bool = false
  ) async throws -> (output: String, succeeded: Bool) {
    try await EnvironmentTeardownCommandRunner(theme: theme).execute(
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: testConsumerPaths(),
      dryRun: dryRun,
      json: true,
      withinUnifiedSetup: withinUnifiedSetup
    )
  }

  func isManaged() throws -> Bool {
    let inspector = EnvironmentProviderInspector()
    let profile = try PortableProfileLoader().load(at: profile, required: true)
    let staticEntries = try inspector.desiredEntries(
      profile: profile.environment,
      homeDirectory: home,
      stateRoot: state
    ).allSatisfy { try inspector.managedEntryIsExact($0) }
    let btop = home.appending(path: ".config/btop/btop.conf")
    let generation = try #require(
      try EnvironmentGenerationStore(stateRoot: state).currentManifest()
    )
    let expected = try EnvironmentBtopFileTransaction(
      homeDirectory: home,
      stateRoot: state
    ).generationState(generation.generationID)
    let actual = try String(contentsOf: btop, encoding: .utf8)
    let btopManaged = try EnvironmentBtopDocument.matchesManaged(
      actual,
      values: expected.values,
      source: btop
    )
    return staticEntries && btopManaged
  }

  func entryEvidence() throws -> [EnvironmentEntryID: EnvironmentEntryEvidence] {
    let inspector = EnvironmentProviderInspector()
    return [
      .kitty: try inspector.capture(kittyEntry, directoryLink: .kitty),
      .zsh: try inspector.capture(zshEntry, directoryLink: nil),
      .starship: try inspector.capture(starshipEntry, directoryLink: nil),
      .atuinConfiguration: try inspector.capture(atuinConfigEntry, directoryLink: nil),
      .atuinTheme: try inspector.capture(atuinThemeEntry, directoryLink: nil),
      .batConfiguration: try inspector.capture(
        home.appending(path: ".config/bat/config"), directoryLink: nil),
      .batTheme: try inspector.capture(
        home.appending(path: ".config/bat/themes/Macarchy Current.tmTheme"),
        directoryLink: nil
      ),
      .btopConfiguration: try inspector.capture(
        home.appending(path: ".config/btop/btop.conf"), directoryLink: nil),
      .btopTheme: try inspector.capture(
        home.appending(path: ".config/btop/themes/macarchy-current.theme"),
        directoryLink: nil
      ),
      .ezaTheme: try inspector.capture(
        home.appending(path: ".config/eza/theme.yml"), directoryLink: nil),
      .yaziConfiguration: try inspector.capture(
        home.appending(path: ".config/yazi/yazi.toml"), directoryLink: nil),
      .yaziThemeSelection: try inspector.capture(
        home.appending(path: ".config/yazi/theme.toml"), directoryLink: nil),
      .yaziFlavor: try inspector.capture(
        home.appending(path: ".config/yazi/flavors/macarchy-current.yazi/flavor.toml"),
        directoryLink: nil
      ),
      .yaziSyntax: try inspector.capture(
        home.appending(path: ".config/yazi/flavors/macarchy-current.yazi/tmtheme.xml"),
        directoryLink: nil
      ),
    ]
  }

  func activateTheme() throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
    _ = try ThemeActivator(root: state).activate(package: package)
  }
}

extension Int32 {
  func requireZero() throws {
    guard self == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
