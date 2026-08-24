import Foundation

package struct ThemeConsumerPaths: Sendable {
  package let kittyConfigurationURL: URL
  package let sketchyBarConfigurationURL: URL
  package let shellConfigurationURL: URL
  package let ezaConfigurationDirectoryURL: URL
  package let batConfigurationDirectoryURL: URL
  package let batCacheDirectoryURL: URL

  package init(
    kittyConfigurationURL: URL,
    sketchyBarConfigurationURL: URL,
    shellConfigurationURL: URL,
    ezaConfigurationDirectoryURL: URL,
    batConfigurationDirectoryURL: URL,
    batCacheDirectoryURL: URL
  ) {
    self.kittyConfigurationURL = kittyConfigurationURL.standardizedFileURL
    self.sketchyBarConfigurationURL = sketchyBarConfigurationURL.standardizedFileURL
    self.shellConfigurationURL = shellConfigurationURL.standardizedFileURL
    self.ezaConfigurationDirectoryURL = ezaConfigurationDirectoryURL.standardizedFileURL
    self.batConfigurationDirectoryURL = batConfigurationDirectoryURL.standardizedFileURL
    self.batCacheDirectoryURL = batCacheDirectoryURL.standardizedFileURL
  }
}
