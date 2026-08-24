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
    starshipBehaviorURL: URL
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
  }
}
