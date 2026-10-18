import Foundation
import Testing

@testable import MacarchyCLI

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

func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
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
