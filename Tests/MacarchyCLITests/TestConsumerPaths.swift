import Foundation
import ThemeCore

func testConsumerPaths() -> ThemeConsumerPaths {
  let root = URL(filePath: "/test", directoryHint: .isDirectory)
  return ThemeConsumerPaths(
    kittyConfigurationURL: root.appending(path: "kitty.conf"),
    sketchyBarConfigurationURL: root.appending(path: "sketchybarrc"),
    shellConfigurationURL: root.appending(path: ".zshrc"),
    ezaConfigurationDirectoryURL: root.appending(path: "eza", directoryHint: .isDirectory),
    batConfigurationDirectoryURL: root.appending(path: "bat", directoryHint: .isDirectory),
    batCacheDirectoryURL: root.appending(path: "bat-cache", directoryHint: .isDirectory)
  )
}
