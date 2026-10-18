import Foundation
import Testing

@testable import MacarchyCLI

// Saver tests drive every process, panel, signal and terminal through injected seams: they never
// start Kitty, open, ttfx or a shell, never signal a real process and never change the test
// process's terminal. Files are regular files and directories in a temporary directory.

struct SaverInstallationTests {
  @Test(arguments: ["present", "absent", "directory", "not-executable"])
  func engineMustBeARegularExecutableBesideTheBinDirectory(layout: String) throws {
    try withTemporaryDirectory { root in
      let prefix = root.appending(path: "Cellar/macarchy/0.14.0", directoryHint: .isDirectory)
      let binary = prefix.appending(path: "bin/macarchy")
      let engine = prefix.appending(path: "libexec/ttfx")
      try writeFile("", to: binary, permissions: 0o755)
      switch layout {
      case "present": try writeFile("", to: engine, permissions: 0o755)
      case "directory":
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
      case "not-executable": try writeFile("", to: engine, permissions: 0o644)
      default: break
      }

      let located = SaverEngine.locate(executable: binary, resolve: { $0 })

      let expected: SaverEngineDefect? =
        switch layout {
        case "absent": .absent
        case "directory": .notRegularFile
        case "not-executable": .notExecutable
        default: nil
        }
      #expect(located.url.path == engine.path)
      #expect(located.defect == expected)
    }
  }

  @Test func symlinkedEntryPointFindsTheEngineBesideThePhysicalBinary() throws {
    try withTemporaryDirectory { root in
      let physical = root.appending(path: "Cellar/macarchy/0.14.0/bin/macarchy")
      let engine = root.appending(path: "Cellar/macarchy/0.14.0/libexec/ttfx")
      try writeFile("", to: physical, permissions: 0o755)
      try writeFile("", to: engine, permissions: 0o755)
      let link = URL(filePath: "/opt/homebrew/bin/macarchy")

      let located = SaverEngine.locate(executable: link) { $0 == link ? physical : $0 }

      #expect(located.url.path == engine.path)
      #expect(located.defect == nil)
    }
  }

  @Test func kittyIsPresentOnlyWithItsExecutableAndReportsItsVersion() throws {
    try withTemporaryDirectory { root in
      let application = root.appending(path: "kitty.app", directoryHint: .isDirectory)
      #expect(SaverKitty.inspect(application: application) == .missing)

      try writeFile("", to: application.appending(path: "Contents/MacOS/kitty"), permissions: 0o755)
      #expect(SaverKitty.inspect(application: application) == .present(version: nil))

      let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": "0.49.0"], format: .xml, options: 0)
      try info.write(to: application.appending(path: "Contents/Info.plist"))
      #expect(SaverKitty.inspect(application: application) == .present(version: "0.49.0"))
    }
  }

  @Test func statusNamesTheEngineKittyAndTheirRemedies() throws {
    let engine = URL(filePath: "/opt/homebrew/Cellar/macarchy/0.14.0/libexec/ttfx")
    let ready = SaverStatus(
      engine: SaverEngine(url: engine, defect: nil), kitty: .present(version: "0.49.0"))
    let missing = SaverStatus(
      engine: SaverEngine(url: engine, defect: .absent), kitty: .missing)

    #expect(
      try ready.renderJSON()
        == #"{"engine":{"path":"/opt/homebrew/Cellar/macarchy/0.14.0/libexec/ttfx","reason":null,"#
        + #""remedy":null,"state":"present"},"kitty":{"path":"/Applications/kitty.app","#
        + #""remedy":null,"state":"present","version":"0.49.0"},"running":false,"sessions":[]}"#)
    let document = try jsonObject(try missing.renderJSON())
    let engineDocument = try #require(document["engine"] as? [String: Any])
    let kittyDocument = try #require(document["kitty"] as? [String: Any])
    #expect(engineDocument["state"] as? String == "missing")
    #expect(engineDocument["reason"] as? String == "absent")
    #expect(engineDocument["remedy"] as? String == SaverEngine.remedy)
    #expect(kittyDocument["state"] as? String == "missing")
    #expect(kittyDocument["version"] is NSNull)
    #expect(kittyDocument["remedy"] as? String == SaverKitty.remedy)
    #expect(document["running"] as? Bool == false)

    #expect(
      ready.message
        == """
        ttfx engine: present at \(engine.path)
        Kitty: 0.49.0 at /Applications/kitty.app
        Screensaver: not running
        """)
    #expect(missing.message.contains("missing at \(engine.path) (not found)"))
    #expect(missing.message.contains("brew reinstall ramtinj95/tap/macarchy"))
    #expect(missing.message.contains("brew install --cask kitty"))
  }
}

struct SaverTextTests {
  @Test func missingFileShowsTheBannerWithoutANotice() throws {
    try withTemporaryDirectory { root in
      let file = SaverText.fileURL(stateRoot: root)
      #expect(file.path == root.appending(path: "screensaver.txt").path)
      #expect(SaverText.read(file) == .absent)
      #expect(SaverText.read(root.appending(path: "missing/screensaver.txt")) == .absent)

      let text = SaverText.choose(.absent)
      #expect(text == .banner(rejected: nil))
      #expect(text.content == SaverText.bannerText)
      #expect(text.notice(textFile: file) == nil)
    }
  }

  @Test func customTextKeepsNewlinesAndTabsAndDropsOtherControlCharacters() throws {
    try withTemporaryDirectory { root in
      let file = SaverText.fileURL(stateRoot: root)
      let contents = Data("Back at\t3 pm\r\n\u{1B}[31mbye\u{7}".utf8)
      try contents.write(to: file)

      let found = SaverText.read(file)

      #expect(found == .contents(contents))
      #expect(SaverText.choose(found) == .custom("Back at\t3 pm\n[31mbye"))
      #expect(SaverText.choose(found).notice(textFile: file) == nil)
    }
  }

  @Test func textUpToTheLimitIsUsed() throws {
    try withTemporaryDirectory { root in
      let file = SaverText.fileURL(stateRoot: root)
      try Data(repeating: 0x61, count: SaverText.maximumSize).write(to: file)

      let text = SaverText.choose(SaverText.read(file))

      #expect(text.content.count == SaverText.maximumSize)
    }
  }

  @Test(arguments: [
    "symbolic-link", "directory", "too-large", "invalid-utf8", "blank", "unreadable",
  ])
  func unusableFileFallsBackToTheBannerAndSaysWhy(kind: String) throws {
    try withTemporaryDirectory { root in
      let file = SaverText.fileURL(stateRoot: root)
      let found: SaverTextFile
      switch kind {
      // The reader opens without following links; tests never create one.
      case "symbolic-link": found = .symbolicLink
      case "directory":
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        found = SaverText.read(file)
        #expect(found == .notRegularFile)
      case "too-large":
        try Data(repeating: 0x61, count: SaverText.maximumSize + 1).write(to: file)
        found = SaverText.read(file)
        #expect(found == .tooLarge)
      case "invalid-utf8": found = .contents(Data([0x48, 0xFF, 0xFE]))
      case "blank": found = .contents(Data(" \n\t\u{7}".utf8))
      default: found = .unreadable("errno 13")
      }
      let reason =
        switch kind {
        case "symbolic-link": "it is a symbolic link"
        case "directory": "it is not a regular file"
        case "too-large": "it is larger than 64 KiB"
        case "invalid-utf8": "it is not valid UTF-8"
        case "blank": "it contains no visible text"
        default: "it cannot be read (errno 13)"
        }

      let text = SaverText.choose(found)

      #expect(text == .banner(rejected: reason))
      #expect(text.content == SaverText.bannerText)
      #expect(
        text.notice(textFile: file)
          == "Showing the Macarchy banner: \(file.path) is not used because \(reason).")
    }
  }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-saver-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

private func writeFile(_ contents: String, to url: URL, permissions: Int) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(contents.utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}
