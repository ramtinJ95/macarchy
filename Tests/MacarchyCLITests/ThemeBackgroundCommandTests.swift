import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeBackgroundCommandTests {
  @Test
  func currentReportsCanonicalSelectionAndUnmanagedState() throws {
    let selected = runner(
      manifest: backgroundManifest(background: GenerationBackground(id: "night", format: .jpeg))
    )
    #expect(
      try selected.current(stateRoot: URL(filePath: "/test/state")) == "night\tjpeg"
    )

    let unmanaged = runner(manifest: backgroundManifest(background: nil))
    #expect(try unmanaged.current(stateRoot: URL(filePath: "/test/state")) == "unmanaged")
  }

  @Test
  func concurrentNextCallsAdvanceInOneLinearOrderAndWrap() async throws {
    let fixture = try multiBackgroundRepository()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let stateRoot = fixture.root.appending(path: "state", directoryHint: .isDirectory)
    let canonical = Mutex(
      backgroundManifest(
        generationID: "g-initial",
        background: GenerationBackground(id: "default", format: .webp)
      )
    )
    let selected = Mutex([String]())
    let runner = ThemeBackgroundCommandRunner(
      activeManifest: { _ in canonical.withLock { $0 } },
      preflight: { _, _, _, _ in },
      activate: { package, backgroundID, _, _, expectedGenerationID in
        let manifest = try canonical.withLock { current -> GenerationManifest in
          guard current.generationID == expectedGenerationID else {
            throw ThemeActivationError.activeGenerationChanged(
              expected: expectedGenerationID,
              active: current.generationID
            )
          }
          let format = try #require(package.background(id: backgroundID)?.format)
          let next = backgroundManifest(
            generationID: "g-\(UUID().uuidString.lowercased())",
            background: GenerationBackground(id: backgroundID, format: format)
          )
          current = next
          selected.withLock { $0.append(backgroundID) }
          return next
        }
        return ThemeActivationResult(
          manifest: manifest,
          reconciliation: try ReconciliationRecord(manifest: manifest, results: [])
        )
      }
    )

    async let first = runner.next(
      repository: fixture.repository,
      stateRoot: stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: false
    )
    async let second = runner.next(
      repository: fixture.repository,
      stateRoot: stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: false
    )
    let results = try await [first, second]

    #expect(results.allSatisfy { $0.succeeded })
    #expect(selected.withLock { $0 } == ["second", "default"])
    #expect(canonical.withLock { $0.background?.id } == "default")
  }

  private func runner(manifest: GenerationManifest) -> ThemeBackgroundCommandRunner {
    ThemeBackgroundCommandRunner(
      activeManifest: { _ in manifest },
      preflight: { _, _, _, _ in },
      activate: { _, _, _, _, _ in throw BackgroundCommandTestError.unexpectedActivation }
    )
  }

  private func multiBackgroundRepository() throws -> (
    root: URL,
    repository: ThemeRepository
  ) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-background-command-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let themes = root.appending(path: "themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    let package = themes.appending(path: "catppuccin-mocha", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Themes/catppuccin-mocha"),
      to: package
    )
    try FileManager.default.copyItem(
      at: package.appending(path: "wallpapers/1-totoro.webp"),
      to: package.appending(path: "wallpapers/second.webp")
    )
    let manifestURL = package.appending(path: "theme.toml")
    var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    manifest += """

      [[backgrounds]]
      id = "second"
      path = "wallpapers/second.webp"
      source = "Command fixture"
      author = "Fixture author"
      license = "MIT"
      """
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
    return (root, ThemeRepository(builtInRoot: themes))
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private enum BackgroundCommandTestError: Error {
  case unexpectedActivation
}

private func backgroundManifest(
  generationID: String = "g-background-test",
  background: GenerationBackground?
) -> GenerationManifest {
  GenerationManifest(
    generationID: generationID,
    themeID: "catppuccin-mocha",
    themeSchemaVersion: 1,
    inputDigest: "sha256:input",
    themeDigest: "sha256:theme",
    background: background,
    rendererVersions: [:],
    artifacts: [:]
  )
}
