import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct RuntimeEnvironmentTests {
  @Test
  func sourceVersionMatchesReleaseVersionFile() throws {
    let version = try String(
      contentsOf: repositoryRoot.appending(path: "VERSION.txt"),
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(version == RuntimeEnvironment.sourceVersion)
  }

  @Test
  func developmentBuildFindsCheckoutResourcesFromExecutableLocation() throws {
    let checkout = repositoryRoot
    let executable = checkout.appending(
      path: ".build/arm64-apple-macosx/debug/macarchy"
    )
    let runtime = RuntimeEnvironment(executableURL: executable)

    #expect(runtime.builtInThemesURL.path == checkout.appending(path: "Themes").path)
    #expect(runtime.builtInKeybindingsURL.path == checkout.appending(path: "Keybindings").path)
    #expect(runtime.builtInDesktopURL.path == checkout.appending(path: "Desktop").path)
    #expect(
      try runtime.buildInformation()
        == MacarchyBuildInformation(
          version: "0.6.2-dev",
          revision: "unknown",
          platform: "macos-arm64",
          installation: .development
        )
    )
  }

  @Test
  func packagedLayoutLoadsThemesAndDetectsInstallationOwnership() throws {
    let root = try temporaryDirectory(under: repositoryRoot.appending(path: ".build"))
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = try packagedLayout(at: root)
    let runtime = RuntimeEnvironment(executableURL: layout.executable)
    let packages = try Theme.ThemeRootOptions.parse([]).repository(runtime: runtime).packages()

    #expect(runtime.builtInThemesURL.path == layout.themes.path)
    #expect(runtime.builtInKeybindingsURL.path == layout.keybindings.path)
    #expect(runtime.builtInDesktopURL.path == layout.desktop.path)
    #expect(packages.map(\.id) == ["catppuccin-mocha", "kanagawa-wave", "tokyo-night"])
    #expect(try runtime.buildInformation().installation == .unmanaged)

    let receipt = root.appending(path: "INSTALL_RECEIPT.json")
    try FileManager.default.createDirectory(
      at: receipt,
      withIntermediateDirectories: false
    )
    #expect(try runtime.buildInformation().installation == .unmanaged)
    try FileManager.default.removeItem(at: receipt)
    let receiptTarget = root.appending(path: "receipt-target.json")
    try "{}\n".write(to: receiptTarget, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: receipt,
      withDestinationURL: receiptTarget
    )
    #expect(try runtime.buildInformation().installation == .unmanaged)
    try FileManager.default.removeItem(at: receipt)

    try "{}\n".write(
      to: receipt,
      atomically: true,
      encoding: .utf8
    )
    #expect(try runtime.buildInformation().installation == .homebrew)

    let explicit = root.appending(path: "explicit-themes", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory),
      to: explicit
    )
    let explicitOptions = try Theme.ThemeRootOptions.parse([
      "--themes-root", explicit.path,
    ])
    #expect(
      try explicitOptions.repository(runtime: runtime).packages().map(\.id)
        == ["catppuccin-mocha", "kanagawa-wave", "tokyo-night"]
    )
  }

  @Test
  func packagedMetadataPreventsCheckoutFallbackWhenThemesAreMissing() throws {
    let root = try temporaryDirectory(under: repositoryRoot.appending(path: ".build"))
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = try packagedLayout(at: root, includeThemes: false)
    let runtime = RuntimeEnvironment(executableURL: layout.executable)

    #expect(runtime.builtInThemesURL.path == layout.themes.path)
    #expect(throws: ThemeDiagnostic.self) {
      _ = try Theme.ThemeRootOptions.parse([]).repository(runtime: runtime).packages()
    }
  }

  @Test
  func invalidPackagedMetadataFailsVisibly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid =
      "{\"schema_version\":1,\"version\":\"9.0.0\",\"revision\":\"\(revision)\"}\n"
    let layout = try packagedLayout(at: root, buildInformation: invalid)

    let runtime = RuntimeEnvironment(executableURL: layout.executable)
    #expect(throws: InvalidBuildInformationError.self) {
      _ = try runtime.buildInformation()
    }
    #expect(throws: InvalidBuildInformationError.self) {
      _ = try VersionCommandRunner(buildInformation: runtime.buildInformation).executeConcise()
    }

    let metadata = root.appending(path: "share/macarchy/build-info.json")
    try FileManager.default.removeItem(at: metadata)
    let target = root.appending(path: "build-info-target.json")
    try packagedBuildInformation.write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)
    #expect(throws: InvalidBuildInformationError.self) {
      _ = try runtime.buildInformation()
    }
  }

  @Test
  func versionCommandHasStableHumanAndJSONContracts() throws {
    let information = MacarchyBuildInformation(
      version: "0.6.2",
      revision: revision,
      platform: "macos-arm64",
      installation: .unmanaged
    )
    let runner = VersionCommandRunner(buildInformation: { information })

    #expect(try runner.executeConcise() == "0.6.2")
    #expect(
      try runner.execute(json: false)
        == "Macarchy 0.6.2 (\(revision), macos-arm64, unmanaged)"
    )
    let json = try runner.execute(json: true)
    let object = try jsonObject(json)
    #expect(object["schema_version"] as? Int == 1)
    #expect(object["version"] as? String == "0.6.2")
    #expect(object["revision"] as? String == revision)
    #expect(object["platform"] as? String == "macos-arm64")
    #expect(object["installation"] as? String == "unmanaged")
  }

  private var revision: String {
    "0123456789abcdef0123456789abcdef01234567"
  }

  private var packagedBuildInformation: String {
    "{\"schema_version\":1,\"version\":\"0.6.2\",\"revision\":\"\(revision)\"}\n"
  }

  private func packagedLayout(
    at root: URL,
    includeThemes: Bool = true,
    buildInformation: String? = nil
  ) throws -> (executable: URL, themes: URL, keybindings: URL, desktop: URL) {
    let executable = root.appending(path: "bin/macarchy")
    let resources = root.appending(path: "share/macarchy", directoryHint: .isDirectory)
    let themes = resources.appending(path: "themes", directoryHint: .isDirectory)
    let keybindings = resources.appending(path: "keybindings", directoryHint: .isDirectory)
    let desktop = resources.appending(path: "desktop", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Data().write(to: executable)
    try (buildInformation ?? packagedBuildInformation).write(
      to: resources.appending(path: "build-info.json"),
      atomically: true,
      encoding: .utf8
    )
    if includeThemes {
      try FileManager.default.copyItem(
        at: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory),
        to: themes
      )
    }
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Keybindings", directoryHint: .isDirectory),
      to: keybindings
    )
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Desktop", directoryHint: .isDirectory),
      to: desktop
    )
    return (executable, themes, keybindings, desktop)
  }

  private func temporaryDirectory(
    under parent: URL = FileManager.default.temporaryDirectory
  ) throws -> URL {
    let root = parent.appending(
      path: "macarchy-runtime-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
