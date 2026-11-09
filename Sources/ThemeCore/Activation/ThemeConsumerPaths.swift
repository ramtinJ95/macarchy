import Foundation

/// Every path is stored standardized, whether set by the initializer or assigned later.
package struct ThemeConsumerPaths: Sendable {
  package var zedValidateOwnership: @Sendable (URL) throws -> Void = { _ in
    throw ZedAdapter.Failure.drift
  }
  package static func zedConfigurationDirectory(home: URL) -> URL {
    home.appending(path: ".config/zed").standardizedFileURL
  }
  package var alacrittyOwnedConfigurationURL: URL?
  package var alacrittyOwnedImportEdit: AlacrittyImportEdit?
  package var alacrittyConfigurationFiles: [URL] {
    Self.alacrittyConfigurationFiles(home: piDerivedHomeDirectoryURL)
  }
  package static func alacrittyConfigurationFiles(
    home: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    AlacrittyConfiguration.files(home: home, environment: environment)
  }
  package var ghosttyOwnedConfigurationURL: URL?
  package var ghosttyOwnedLineIndex: Int?
  package var ghosttyConfigurationFiles: [URL] {
    Self.ghosttyConfigurationFiles(home: piDerivedHomeDirectoryURL)
  }

  /// Like the other consumer paths, resolve against the selected home, not Foundation's
  /// process-global home. A GUI app can see a different launchd XDG environment.
  package static func ghosttyConfigurationFiles(
    home: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    let xdg =
      environment["XDG_CONFIG_HOME"].flatMap { value in
        value.hasPrefix("/") ? URL(filePath: value).standardizedFileURL : nil
      } ?? home.appending(path: ".config")
    return GhosttyConfiguration.files(home: home, xdgConfigurationHome: xdg)
  }

  package var kittyConfigurationURL: URL {
    didSet { kittyConfigurationURL = kittyConfigurationURL.standardizedFileURL }
  }
  package var sketchyBarConfigurationURL: URL {
    didSet { sketchyBarConfigurationURL = sketchyBarConfigurationURL.standardizedFileURL }
  }
  package var shellConfigurationURL: URL {
    didSet { shellConfigurationURL = shellConfigurationURL.standardizedFileURL }
  }
  package var ezaConfigurationDirectoryURL: URL {
    didSet { ezaConfigurationDirectoryURL = ezaConfigurationDirectoryURL.standardizedFileURL }
  }
  package var batConfigurationDirectoryURL: URL {
    didSet { batConfigurationDirectoryURL = batConfigurationDirectoryURL.standardizedFileURL }
  }
  package var batCacheDirectoryURL: URL {
    didSet { batCacheDirectoryURL = batCacheDirectoryURL.standardizedFileURL }
  }
  package var btopConfigurationDirectoryURL: URL {
    didSet { btopConfigurationDirectoryURL = btopConfigurationDirectoryURL.standardizedFileURL }
  }
  package var yaziConfigurationDirectoryURL: URL {
    didSet { yaziConfigurationDirectoryURL = yaziConfigurationDirectoryURL.standardizedFileURL }
  }
  package var atuinConfigurationDirectoryURL: URL {
    didSet { atuinConfigurationDirectoryURL = atuinConfigurationDirectoryURL.standardizedFileURL }
  }
  package var neovimConfigurationDirectoryURL: URL {
    didSet { neovimConfigurationDirectoryURL = neovimConfigurationDirectoryURL.standardizedFileURL }
  }
  package var starshipConfigurationURL: URL {
    didSet { starshipConfigurationURL = starshipConfigurationURL.standardizedFileURL }
  }
  package var starshipBehaviorURL: URL {
    didSet { starshipBehaviorURL = starshipBehaviorURL.standardizedFileURL }
  }
  package var piConfigurationDirectoryURL: URL {
    didSet { piConfigurationDirectoryURL = piConfigurationDirectoryURL.standardizedFileURL }
  }
  package var herdrConfigurationURL: URL {
    didSet { herdrConfigurationURL = herdrConfigurationURL.standardizedFileURL }
  }
  package var tuicrConfigurationDirectoryURL: URL {
    didSet { tuicrConfigurationDirectoryURL = tuicrConfigurationDirectoryURL.standardizedFileURL }
  }
  package var codexConfigurationDirectoryURL: URL {
    didSet { codexConfigurationDirectoryURL = codexConfigurationDirectoryURL.standardizedFileURL }
  }
  package var spicetifyConfigurationDirectoryURL: URL {
    didSet {
      spicetifyConfigurationDirectoryURL = spicetifyConfigurationDirectoryURL.standardizedFileURL
    }
  }

  package init(
    kittyConfigurationURL: URL,
    sketchyBarConfigurationURL: URL,
    shellConfigurationURL: URL,
    ezaConfigurationDirectoryURL: URL,
    batConfigurationDirectoryURL: URL,
    batCacheDirectoryURL: URL,
    btopConfigurationDirectoryURL: URL,
    yaziConfigurationDirectoryURL: URL,
    atuinConfigurationDirectoryURL: URL,
    neovimConfigurationDirectoryURL: URL,
    starshipConfigurationURL: URL,
    starshipBehaviorURL: URL,
    piConfigurationDirectoryURL: URL,
    herdrConfigurationURL: URL,
    tuicrConfigurationDirectoryURL: URL,
    codexConfigurationDirectoryURL: URL,
    spicetifyConfigurationDirectoryURL: URL
  ) {
    self.kittyConfigurationURL = kittyConfigurationURL.standardizedFileURL
    self.sketchyBarConfigurationURL = sketchyBarConfigurationURL.standardizedFileURL
    self.shellConfigurationURL = shellConfigurationURL.standardizedFileURL
    self.ezaConfigurationDirectoryURL = ezaConfigurationDirectoryURL.standardizedFileURL
    self.batConfigurationDirectoryURL = batConfigurationDirectoryURL.standardizedFileURL
    self.batCacheDirectoryURL = batCacheDirectoryURL.standardizedFileURL
    self.btopConfigurationDirectoryURL = btopConfigurationDirectoryURL.standardizedFileURL
    self.yaziConfigurationDirectoryURL = yaziConfigurationDirectoryURL.standardizedFileURL
    self.atuinConfigurationDirectoryURL = atuinConfigurationDirectoryURL.standardizedFileURL
    self.neovimConfigurationDirectoryURL = neovimConfigurationDirectoryURL.standardizedFileURL
    self.starshipConfigurationURL = starshipConfigurationURL.standardizedFileURL
    self.starshipBehaviorURL = starshipBehaviorURL.standardizedFileURL
    self.piConfigurationDirectoryURL = piConfigurationDirectoryURL.standardizedFileURL
    self.herdrConfigurationURL = herdrConfigurationURL.standardizedFileURL
    self.tuicrConfigurationDirectoryURL = tuicrConfigurationDirectoryURL.standardizedFileURL
    self.codexConfigurationDirectoryURL = codexConfigurationDirectoryURL.standardizedFileURL
    self.spicetifyConfigurationDirectoryURL =
      spicetifyConfigurationDirectoryURL.standardizedFileURL
  }

  /// The home directory implied by the Pi configuration directory (`<home>/.pi/agent`), found by
  /// stripping its last two components. An overridden Pi directory moves this home with it.
  package var piDerivedHomeDirectoryURL: URL {
    piConfigurationDirectoryURL.deletingLastPathComponent().deletingLastPathComponent()
  }
}
