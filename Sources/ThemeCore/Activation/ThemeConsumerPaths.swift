import Foundation

package struct ThemeConsumerPaths: Sendable {
  package let kittyConfigurationURL: URL
  package let sketchyBarConfigurationURL: URL
  package let shellConfigurationURL: URL
  package let ezaConfigurationDirectoryURL: URL
  package let batConfigurationDirectoryURL: URL
  package let batCacheDirectoryURL: URL
  package let btopConfigurationDirectoryURL: URL
  package let yaziConfigurationDirectoryURL: URL
  package let atuinConfigurationDirectoryURL: URL
  package let neovimConfigurationDirectoryURL: URL
  package let starshipConfigurationURL: URL
  package let starshipBehaviorURL: URL
  package let piConfigurationDirectoryURL: URL
  package let herdrConfigurationURL: URL
  package let tuicrConfigurationDirectoryURL: URL
  package let codexConfigurationDirectoryURL: URL

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
    codexConfigurationDirectoryURL: URL
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
  }
}
