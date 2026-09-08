import Foundation
import Testing

@testable import ThemeCore

struct ZshIntegrationTests {
  @Test(arguments: [
    "none", "autosuggestions", "fzf-keys", "fzf-completion", "zoxide-command", "zoxide-eval",
    "highlighting",
  ])
  func interactiveIntegrationsMustSucceedBeforePublishingSessionMarker(failure: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-zsh-integrations-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Environment")
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [prompt]
      provider = "disabled"
      [history]
      provider = "disabled"
      """, source: root.appending(path: "profile.toml")
    )
    let composition = try EnvironmentConfigurationComposer().compose(
      resourcesRoot: resources, profile: profile, stateRoot: root.appending(path: "state")
    )
    let configuration = try #require(composition.artifacts.first { $0.path == "zsh/.zshrc" })
    let prefix = root.appending(path: "brew")
    for (name, path) in [
      ("autosuggestions", "share/zsh-autosuggestions/zsh-autosuggestions.zsh"),
      ("fzf-keys", "opt/fzf/shell/key-bindings.zsh"),
      ("fzf-completion", "opt/fzf/shell/completion.zsh"),
      ("highlighting", "share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"),
    ] {
      try write(
        "print -r -- \(name)\n" + (failure == name ? "return 19\n" : "true\n"),
        at: prefix.appending(path: path)
      )
    }
    let zoxide = prefix.appending(path: "bin/zoxide")
    try write(
      "#!/bin/sh\n"
        + (failure == "zoxide-command"
          ? "exit 19\n"
          : "printf '%s\\n' '\(failure == "zoxide-eval" ? "return 19" : "function z() { :; }")'\n"),
      at: zoxide
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zoxide.path)
    let entry = root.appending(path: "managed.zsh")
    try write(
      try #require(configuration.textContents).replacingOccurrences(
        of: "/opt/homebrew", with: prefix.path), at: entry)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = [
      "-dfi", "-c",
      """
      source "$1"
      result=$?
      print -r -- "marker=${MACARCHY_MANAGED_SESSION-unset}"
      if (( result == 0 )); then
        bindkey '^y'
        (( ${+functions[z]} )) || exit 20
      fi
      exit $result
      """, "test", entry.path,
    ]
    process.environment = [
      "HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin", "TERM": "dumb",
    ]
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if failure == "none" {
      #expect(process.terminationStatus == 0, Comment(rawValue: text))
      #expect(text.contains("autosuggestions\nfzf-keys\nfzf-completion\nhighlighting\nmarker=1\n"))
      #expect(text.contains("autosuggest-accept"))
    } else {
      #expect(process.terminationStatus != 0)
      #expect(text.contains("marker=unset\n"))
      #expect(!text.contains("marker=1\n"))
    }
  }

  private func write(_ contents: String, at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }
}
