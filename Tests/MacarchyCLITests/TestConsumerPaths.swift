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
    batCacheDirectoryURL: root.appending(path: "bat-cache", directoryHint: .isDirectory),
    btopConfigurationDirectoryURL: root.appending(path: "btop", directoryHint: .isDirectory),
    yaziConfigurationDirectoryURL: root.appending(path: "yazi", directoryHint: .isDirectory),
    atuinConfigurationDirectoryURL: root.appending(path: "atuin", directoryHint: .isDirectory),
    neovimConfigurationDirectoryURL: root.appending(path: "nvim", directoryHint: .isDirectory),
    starshipConfigurationURL: root.appending(path: "starship.toml"),
    starshipBehaviorURL: root.appending(path: "starship/behavior.toml")
  )
}
