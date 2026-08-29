import Foundation
import ImageIO
import Testing

@testable import ThemeCore

struct BackgroundInventoryTests {
  @Test
  func zeroBackgroundPackageIsValidAndProducesAnUnmanagedGeneration() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let packageURL = try copyCatppuccin(to: root)
    try replaceBackgroundContract(in: packageURL, with: "")
    try FileManager.default.removeItem(at: packageURL.appending(path: "LICENSES/wallpaper.md"))
    let package = try ThemePackageLoader().load(packageURL: packageURL)
    #expect(package.backgrounds.isEmpty)
    #expect(throws: BackgroundSelectionError.noBackgrounds(themeID: package.id)) {
      _ = try BackgroundSelectionResolver.resolve(
        package: package,
        requestedBackgroundID: "missing",
        preferences: [:],
        overrideData: nil
      )
    }
    let rendered = try ThemeRenderer().render(package: package, generationID: "zero-background")
    #expect(rendered.wallpaper == nil)

    let stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    let manifest = try ThemeActivator(root: stateRoot).activate(package: package)
    #expect(manifest.background == nil)
    #expect(manifest.artifacts[WallpaperAdapter.outputPath] == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: stateRoot.appending(
          path: "generations/\(manifest.generationID)/\(WallpaperAdapter.outputPath)"
        ).path
      )
    )
    try manifest.validateArtifacts(
      at: stateRoot.appending(path: "generations/\(manifest.generationID)")
    )
  }

  @Test
  func olderWallpaperContractRequiresReinstallation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root)
    try replaceBackgroundContract(
      in: packageURL,
      with: """
        [wallpaper]
        path = "wallpapers/default.png"
        source = "Original Macarchy palette artwork"
        author = "Ramtin Javanmardi"
        license = "MIT"
        """
    )
    let rejection = try diagnostic {
      _ = try ThemePackageLoader().load(packageURL: packageURL)
    }
    #expect(rejection.field == "wallpaper")
    #expect(rejection.message.contains("must be reinstalled"))
    #expect(rejection.message.contains("[[backgrounds]]"))
  }

  @Test
  func canonicalInventoryPreservesDeclaredOrderAndExplicitIdentity() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = try copyCatppuccin(to: root)
    let firstDirectory = packageURL.appending(
      path: "backgrounds/day", directoryHint: .isDirectory)
    let secondDirectory = packageURL.appending(
      path: "backgrounds/night", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    let png = try Data(contentsOf: packageURL.appending(path: "wallpapers/default.png"))
    try png.write(to: firstDirectory.appending(path: "default.png"))
    try jpegData(from: png).write(to: secondDirectory.appending(path: "default.jpg"))
    try replaceBackgroundContract(
      in: packageURL,
      with: """
        [[backgrounds]]
        id = "day"
        path = "backgrounds/day/default.png"
        source = "Fixture day"
        author = "Fixture author"
        license = "MIT"

        [[backgrounds]]
        id = "night"
        path = "backgrounds/night/default.jpg"
        source = "Fixture night"
        author = "Fixture author"
        license = "MIT"
        """
    )

    let package = try ThemePackageLoader().load(packageURL: packageURL)

    #expect(package.backgrounds.map(\.id) == ["day", "night"])
    #expect(package.backgrounds.map(\.format) == [.png, .jpeg])
    #expect(
      package.backgrounds.map(\.path)
        == ["backgrounds/day/default.png", "backgrounds/night/default.jpg"])
    #expect(
      throws: BackgroundSelectionError.unknownBackground(
        themeID: package.id,
        backgroundID: "missing"
      )
    ) {
      _ = try BackgroundSelectionResolver.resolve(
        package: package,
        requestedBackgroundID: "missing",
        preferences: [:],
        overrideData: nil
      )
    }
  }

  @Test
  func inventoryRejectsDuplicateIDsAndUnsupportedImages() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let duplicate = try copyCatppuccin(to: root, name: "duplicate")
    try replaceBackgroundContract(
      in: duplicate,
      with: """
        [[backgrounds]]
        id = "same"
        path = "wallpapers/default.png"
        source = "Fixture"
        author = "Fixture"
        license = "MIT"

        [[backgrounds]]
        id = "same"
        path = "wallpapers/default.png"
        source = "Fixture"
        author = "Fixture"
        license = "MIT"
        """
    )
    let duplicateDiagnostic = try diagnostic {
      _ = try ThemePackageLoader().load(packageURL: duplicate)
    }
    #expect(duplicateDiagnostic.field == "backgrounds.id")
    #expect(duplicateDiagnostic.message.contains("Duplicate background identifier 'same'"))

    let unsupported = try copyCatppuccin(to: root, name: "unsupported")
    try replaceBackgroundContract(
      in: unsupported,
      with: """
        [[backgrounds]]
        id = "vector"
        path = "backgrounds/vector.svg"
        source = "Fixture"
        author = "Fixture"
        license = "MIT"
        """
    )
    let unsupportedDiagnostic = try diagnostic {
      _ = try ThemePackageLoader().load(packageURL: unsupported)
    }
    #expect(unsupportedDiagnostic.field == "backgrounds.path")
    #expect(unsupportedDiagnostic.message.contains("unsupported image extension"))
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-background-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeWritableForRemoval(_ root: URL) {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return }
    var directories = [root]
    for case let item as URL in enumerator {
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(item)
      }
    }
    for directory in directories.reversed() {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }

  private func copyCatppuccin(to root: URL, name: String = "theme") throws -> URL {
    let source = repositoryRoot.appending(
      path: "Themes/catppuccin-mocha", directoryHint: .isDirectory)
    let destination = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  private func replaceBackgroundContract(in packageURL: URL, with replacement: String) throws {
    let manifest = packageURL.appending(path: "theme.toml")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let canonical = """
      [[backgrounds]]
      id = "default"
      path = "wallpapers/default.png"
      source = "Original Macarchy palette artwork"
      author = "Ramtin Javanmardi"
      license = "MIT"
      """
    let updated = original.replacingOccurrences(of: canonical, with: replacement)
    try #require(updated != original)
    try updated.write(to: manifest, atomically: true, encoding: .utf8)
  }

  private func jpegData(from png: Data) throws -> Data {
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func diagnostic(_ operation: () throws -> Void) throws -> ThemeDiagnostic {
    do {
      try operation()
    } catch let diagnostic as ThemeDiagnostic {
      return diagnostic
    }
    throw TestError.expectedDiagnostic
  }

  private enum TestError: Error {
    case expectedDiagnostic
  }
}
