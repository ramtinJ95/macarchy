import Darwin
import Foundation
import ImageIO
import Testing

@testable import ThemeCore

struct OmarchyThemeConverterTests {
  @Test
  func convertsOnlyValidatedInertInputsIntoALoadablePackage() throws {
    let fixture = try ConversionFixture()
    defer { fixture.remove() }
    try fixture.addValidInputs()
    let executable = fixture.checkout.appending(path: "injected.bin")
    try "touch /tmp/must-not-run\n".write(
      to: executable,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    try "vim.cmd('colorscheme remote')\n".write(
      to: fixture.checkout.appending(path: "neovim.lua"),
      atomically: true,
      encoding: .utf8
    )
    for path in [
      "README.md", "gtk.css", "icons.theme", "install.sh", "qt6ct.conf", "settings.toml",
    ] {
      try "ignored\n".write(
        to: fixture.checkout.appending(path: path),
        atomically: true,
        encoding: .utf8
      )
    }
    try FileManager.default.createDirectory(
      at: fixture.checkout.appending(path: "hooks"),
      withIntermediateDirectories: false
    )
    try "ignored\n".write(
      to: fixture.checkout.appending(path: "hooks/post-install"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createDirectory(
      at: fixture.checkout.appending(path: "backgrounds/nested"),
      withIntermediateDirectories: true
    )
    try fixture.pngData.write(
      to: fixture.checkout.appending(path: "backgrounds/nested/ignored.png"))

    let converted = try fixture.convert()

    #expect(converted.package.id == "purple-dream")
    #expect(converted.package.appearance == .dark)
    #expect(converted.package.semantic.background.rawValue == "#1a0d2e")
    #expect(converted.package.mappings.isEmpty)
    #expect(converted.report.sourceURL == "https://github.com/example/purple-dream")
    #expect(converted.report.resolvedCommit == ConversionFixture.commit)
    #expect(
      converted.report.defaultBackground
        == "backgrounds/1-scenery-pink-lakeside-sunset-lake-landscape-scenic-panorama-7680x3215-144.png"
    )
    #expect(
      converted.report.backgrounds.map(\.sourcePath)
        == [
          "backgrounds/1-scenery-pink-lakeside-sunset-lake-landscape-scenic-panorama-7680x3215-144.png",
          "backgrounds/digital-mountain.jpg",
          "backgrounds/shiny_purple.png",
        ])
    #expect(
      converted.package.backgrounds.map(\.path) == converted.report.backgrounds.map(\.packagePath))
    #expect(converted.package.backgrounds.map(\.format) == [.png, .jpeg, .png])
    #expect(
      converted.package.backgrounds.map(\.id)
        == [
          "background-1-scenery-pink-lakeside-sunset-lake-landscape-scenic-panorama-7680x3215-144-png-a4883efe",
          "digital-mountain-jpg-b5291928",
          "shiny-purple-png-01e119c2",
        ])
    #expect(
      converted.report.previews.map(\.sourcePath)
        == [
          "preview.png", "preview/preview-0.png", "preview/preview-1.png",
          "preview/preview-2.png",
        ])
    let importedPreviews = try ImportedThemePreviewLoader().load(package: converted.package)
    #expect(
      importedPreviews.map(\.sourcePath) == converted.report.previews.map(\.sourcePath))
    #expect(
      importedPreviews.map(\.packagePath) == converted.report.previews.map(\.packagePath))
    #expect(importedPreviews.map(\.format) == [.png, .png, .png, .png])
    #expect(importedPreviews.allSatisfy { $0.data == fixture.pngData })
    #expect(converted.report.warnings == [.missingAssetProvenance])
    #expect(converted.report.paletteFile == "colors.toml")
    #expect(converted.report.appearanceMarker == nil)

    let ignored = Dictionary(
      uniqueKeysWithValues: converted.report.ignoredFiles.map { ($0.path, $0.reason) })
    #expect(ignored["backgrounds/nested/ignored.png"] == .nestedBackgroundFile)
    #expect(ignored["injected.bin"] == .executableFile)
    #expect(ignored["install.sh"] == .scriptFile)
    #expect(ignored["hooks/post-install"] == .hookFile)
    #expect(ignored["neovim.lua"] == .luaConfiguration)
    #expect(ignored["settings.toml"] == .unknownActiveConfiguration)
    #expect(ignored["README.md"] == .unrecognizedInertFile)
    for path in ["gtk.css", "icons.theme", "qt6ct.conf"] {
      #expect(ignored[path] == .applicationOverride)
    }

    let packageURL = converted.package.packageURL
    for path in [
      "backgrounds/1-scenery-pink-lakeside-sunset-lake-landscape-scenic-panorama-7680x3215-144.png",
      "backgrounds/digital-mountain.jpg",
      "backgrounds/shiny_purple.png",
      "previews/preview.png",
      "previews/preview-0.png",
      "sources/colors.toml",
    ] {
      #expect(
        FileManager.default.fileExists(
          atPath: packageURL.appending(path: path).path))
    }
    for path in ["injected.bin", "install.sh", "neovim.lua", "gtk.css", "settings.toml"] {
      #expect(
        !FileManager.default.fileExists(
          atPath: packageURL.appending(path: path).path))
    }

    let persisted = try JSONDecoder().decode(
      OmarchyThemeConversionReport.self,
      from: Data(contentsOf: packageURL.appending(path: "import.json"))
    )
    #expect(persisted.resolvedCommit == ConversionFixture.commit)
  }

  @Test
  func keepsAJPEGDefaultAsTheCanonicalBackgroundBytes() throws {
    let fixture = try ConversionFixture()
    defer { fixture.remove() }
    try fixture.addValidInputs()
    for path in [
      "backgrounds/1-scenery-pink-lakeside-sunset-lake-landscape-scenic-panorama-7680x3215-144.png",
      "backgrounds/shiny_purple.png",
    ] {
      try FileManager.default.removeItem(at: fixture.checkout.appending(path: path))
    }

    let converted = try fixture.convert()
    #expect(converted.report.defaultBackground == "backgrounds/digital-mountain.jpg")
    #expect(converted.package.backgrounds.map(\.format) == [.jpeg])
    #expect(
      converted.package.defaultBackgroundData
        == (try Data(
          contentsOf: converted.package.packageURL.appending(
            path: "backgrounds/digital-mountain.jpg")))
    )
  }

  @Test
  func packageReloadRejectsTamperedImportedPreviewBytes() throws {
    let fixture = try ConversionFixture()
    defer { fixture.remove() }
    try fixture.addValidInputs()
    let converted = try fixture.convert()
    let preview = try #require(
      ImportedThemePreviewLoader().load(package: converted.package).first
    )
    try Data("not an image".utf8).write(
      to: converted.package.packageURL.appending(path: preview.packagePath)
    )

    let ordinaryReload = try ThemePackageLoader().load(packageURL: converted.package.packageURL)
    #expect(ordinaryReload.id == converted.package.id)

    do {
      _ = try ImportedThemePreviewLoader().load(package: converted.package)
      Issue.record("Expected imported preview validation to fail")
    } catch let diagnostic as ThemeDiagnostic {
      #expect(diagnostic.field == "previews.package_path")
      #expect(diagnostic.description.contains(preview.packagePath))
    }
  }

  @Test
  func importedGallerySupportsJPEGAndEnforcesResourceLimits() throws {
    let fixture = try ConversionFixture()
    defer { fixture.remove() }
    try fixture.addValidInputs()
    try fixture.addJPEGPreview()
    let converted = try fixture.convert()
    let previews = try ImportedThemePreviewLoader().load(package: converted.package)

    #expect(previews.map(\.format) == [.png, .png, .png, .png, .jpeg])
    let countDiagnostic = try previewDiagnostic {
      _ = try ImportedThemePreviewLoader(
        maximumPreviewCount: previews.count - 1,
        maximumTotalBytes: Int64.max
      ).load(package: converted.package)
    }
    #expect(countDiagnostic.field == "previews")

    let totalBytes = previews.reduce(Int64(0)) { $0 + Int64($1.data.count) }
    let bytesDiagnostic = try previewDiagnostic {
      _ = try ImportedThemePreviewLoader(
        maximumPreviewCount: previews.count,
        maximumTotalBytes: totalBytes - 1
      ).load(package: converted.package)
    }
    #expect(bytesDiagnostic.field == "previews")
  }

  @Test
  func importedGalleryRequiresMatchingSafeReportPathsAndOrdinaryDirectories() throws {
    let fixture = try ConversionFixture()
    defer { fixture.remove() }
    try fixture.addValidInputs()
    let converted = try fixture.convert()
    let reportURL = converted.package.packageURL.appending(path: "import.json")
    let originalReport = try Data(contentsOf: reportURL)
    defer { try? originalReport.write(to: reportURL) }

    let schemaDiagnostic = try mutatedReportDiagnostic(
      package: converted.package,
      original: originalReport
    ) { $0["schema_version"] = 2 }
    #expect(schemaDiagnostic.field == "schema_version")

    let themeDiagnostic = try mutatedReportDiagnostic(
      package: converted.package,
      original: originalReport
    ) { $0["theme_id"] = "other-theme" }
    #expect(themeDiagnostic.field == "theme_id")

    let sourceDiagnostic = try mutatedReportDiagnostic(
      package: converted.package,
      original: originalReport
    ) { document in
      var previews = try #require(document["previews"] as? [[String: Any]])
      previews[0]["source_path"] = "../preview.png"
      document["previews"] = previews
    }
    #expect(sourceDiagnostic.field == "previews.source_path")

    let packagePathDiagnostic = try mutatedReportDiagnostic(
      package: converted.package,
      original: originalReport
    ) { document in
      var previews = try #require(document["previews"] as? [[String: Any]])
      previews[0]["package_path"] = "../preview.png"
      document["previews"] = previews
    }
    #expect(packagePathDiagnostic.field == "previews.package_path")

    let nulDiagnostic = try mutatedReportDiagnostic(
      package: converted.package,
      original: originalReport
    ) { document in
      var previews = try #require(document["previews"] as? [[String: Any]])
      previews[0]["package_path"] = "previews/preview.png\u{0}.png"
      document["previews"] = previews
    }
    #expect(nulDiagnostic.field == "previews.package_path")

    let mappingDiagnostic = try mutatedReportDiagnostic(
      package: converted.package,
      original: originalReport
    ) { document in
      var previews = try #require(document["previews"] as? [[String: Any]])
      previews[0]["source_path"] = "preview/other.png"
      document["previews"] = previews
    }
    #expect(mappingDiagnostic.field == "previews.source_path")

    try originalReport.write(to: reportURL)
    let reportHandle = try FileHandle(forWritingTo: reportURL)
    try reportHandle.truncate(
      atOffset: UInt64(OmarchyThemeConversionReport.maximumEncodedSize + 1)
    )
    try reportHandle.close()
    let sizeDiagnostic = try previewDiagnostic {
      _ = try ImportedThemePreviewLoader().load(package: converted.package)
    }
    #expect(sizeDiagnostic.description.contains("32 MiB"))

    try originalReport.write(to: reportURL)
    let previewsURL = converted.package.packageURL.appending(
      path: "previews",
      directoryHint: .isDirectory
    )
    let fifoURL = previewsURL.appending(path: "preview.png")
    try FileManager.default.removeItem(at: fifoURL)
    try #require(mkfifo(fifoURL.path, 0o600) == 0)
    let fifoDiagnostic = try previewDiagnostic {
      _ = try ImportedThemePreviewLoader().load(package: converted.package)
    }
    #expect(fifoDiagnostic.field == "previews.package_path")
    try FileManager.default.removeItem(at: fifoURL)
    try fixture.pngData.write(to: fifoURL)

    let displaced = converted.package.packageURL.appending(
      path: "displaced-previews",
      directoryHint: .isDirectory
    )
    try FileManager.default.moveItem(at: previewsURL, to: displaced)
    try FileManager.default.createSymbolicLink(at: previewsURL, withDestinationURL: displaced)
    let symlinkDiagnostic = try previewDiagnostic {
      _ = try ImportedThemePreviewLoader().load(package: converted.package)
    }
    #expect(symlinkDiagnostic.field == "previews.package_path")
  }

  @Test
  func stagingAndConversionRemainScopedAndRecordTheResolvedSource() throws {
    let fixture = try ConversionFixture()
    defer { fixture.remove() }
    try fixture.addValidInputs()
    let checkout = fixture.checkout
    let stager = OmarchyThemeStager(
      temporaryRoot: fixture.staging,
      processRunner: ProcessRunner { request in
        if request.arguments.contains("clone") {
          let destination = URL(
            filePath: try #require(request.arguments.last),
            directoryHint: .isDirectory
          )
          try FileManager.default.copyItem(at: checkout, to: destination)
          return ProcessResult(terminationStatus: 0, output: "")
        }
        return ProcessResult(terminationStatus: 0, output: ConversionFixture.commit)
      }
    )
    let converter = OmarchyThemeConverter(stager: stager)
    var scopedPackage: URL?

    let evidence = try converter.withConvertedPackage(
      from: "https://github.com/example/omarchy-purple-dream-theme.git"
    ) { converted in
      scopedPackage = converted.package.packageURL
      #expect(FileManager.default.fileExists(atPath: converted.package.packageURL.path))
      return (
        converted.package.id,
        converted.report.sourceURL,
        converted.report.resolvedCommit
      )
    }

    #expect(evidence.0 == "purple-dream")
    #expect(evidence.1 == "https://github.com/example/omarchy-purple-dream-theme")
    #expect(evidence.2 == ConversionFixture.commit)
    #expect(scopedPackage.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: fixture.staging,
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  @Test
  func rejectsAnySourceSymlinkWithoutPublishingAPackage() throws {
    let fixture = try ConversionFixture()
    defer { fixture.remove() }
    try fixture.addValidInputs()
    try FileManager.default.createSymbolicLink(
      at: fixture.checkout.appending(path: "neovim.lua"),
      withDestinationURL: fixture.checkout.appending(path: "colors.toml")
    )

    do {
      _ = try fixture.convert()
      Issue.record("Expected source symlink rejection")
    } catch let error as OmarchyThemeConversionError {
      #expect(
        error
          == .unsafeEntry(
            path: "neovim.lua",
            reason: "symbolic links are not accepted"
          ))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func rejectsInvalidOrOversizedSupportedImages() throws {
    let invalid = try ConversionFixture()
    defer { invalid.remove() }
    try invalid.addPalette()
    try FileManager.default.createDirectory(
      at: invalid.checkout.appending(path: "backgrounds"),
      withIntermediateDirectories: true
    )
    let corrupt = invalid.checkout.appending(path: "backgrounds/corrupt.png")
    try Data("not an image".utf8).write(
      to: corrupt)
    let corruptError = try conversionError { _ = try invalid.convert() }
    guard case .invalidAsset(let corruptPath, _) = corruptError else {
      Issue.record("Expected corrupt asset error, got \(corruptError)")
      return
    }
    #expect(corruptPath == "backgrounds/corrupt.png")

    try FileManager.default.removeItem(at: corrupt)
    let mismatch = invalid.checkout.appending(path: "backgrounds/mismatch.jpg")
    try invalid.pngData.write(to: mismatch)
    let mismatchError = try conversionError { _ = try invalid.convert() }
    guard case .invalidAsset(let mismatchPath, let mismatchReason) = mismatchError else {
      Issue.record("Expected media mismatch, got \(mismatchError)")
      return
    }
    #expect(mismatchPath == "backgrounds/mismatch.jpg")
    #expect(mismatchReason.contains("filename's PNG, JPEG, or WebP type"))
    #expect(!FileManager.default.fileExists(atPath: invalid.destination.path))

    let oversized = try ConversionFixture()
    defer { oversized.remove() }
    try oversized.addPalette()
    try FileManager.default.createDirectory(
      at: oversized.checkout.appending(path: "backgrounds"),
      withIntermediateDirectories: true
    )
    let file = oversized.checkout.appending(path: "backgrounds/oversized.png")
    _ = FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(32 * 1_048_576 + 1))
    try handle.close()

    let oversizedError = try conversionError { _ = try oversized.convert() }
    guard case .invalidAsset(let path, let reason) = oversizedError else {
      Issue.record("Expected oversized asset error, got \(oversizedError)")
      return
    }
    #expect(path == "backgrounds/oversized.png")
    #expect(reason.contains("32 MiB"))
    #expect(!FileManager.default.fileExists(atPath: oversized.destination.path))
  }

  @Test
  func nestedOrUnsupportedBackgroundsDoNotSatisfyTheRequiredInventory() throws {
    let fixture = try ConversionFixture()
    defer { fixture.remove() }
    try fixture.addPalette()
    try FileManager.default.createDirectory(
      at: fixture.checkout.appending(path: "backgrounds/nested"),
      withIntermediateDirectories: true
    )
    try fixture.pngData.write(
      to: fixture.checkout.appending(path: "backgrounds/nested/image.png"))
    try Data("svg".utf8).write(
      to: fixture.checkout.appending(path: "backgrounds/image.svg"))

    do {
      _ = try fixture.convert()
      Issue.record("Expected missing-background evidence")
    } catch let error as OmarchyThemeConversionError {
      guard case .missingBackgrounds(let ignored) = error else {
        Issue.record("Expected missing backgrounds, got \(error)")
        return
      }
      #expect(
        ignored
          == [
            OmarchyIgnoredFile(
              path: "backgrounds/image.svg",
              reason: .unsupportedImageType
            ),
            OmarchyIgnoredFile(
              path: "backgrounds/nested/image.png",
              reason: .nestedBackgroundFile
            ),
          ])
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  private func conversionError(_ operation: () throws -> Void) throws
    -> OmarchyThemeConversionError
  {
    do {
      try operation()
    } catch let error as OmarchyThemeConversionError {
      return error
    }
    throw ConversionTestError.expectedFailure
  }

  private func previewDiagnostic(_ operation: () throws -> Void) throws -> ThemeDiagnostic {
    do {
      try operation()
    } catch let diagnostic as ThemeDiagnostic {
      return diagnostic
    }
    throw ConversionTestError.expectedFailure
  }

  private func mutatedReportDiagnostic(
    package: ThemePackage,
    original: Data,
    update: (inout [String: Any]) throws -> Void
  ) throws -> ThemeDiagnostic {
    var document = try jsonObject(original)
    try update(&document)
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    try data.write(to: package.packageURL.appending(path: "import.json"))
    return try previewDiagnostic {
      _ = try ImportedThemePreviewLoader().load(package: package)
    }
  }

}

private enum ConversionTestError: Error {
  case expectedFailure
}

private final class ConversionFixture {
  static let commit = String(repeating: "a", count: 40)

  let root: URL
  let checkout: URL
  let staging: URL
  let destination: URL
  let pngData: Data

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-omarchy-converter-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    checkout = root.appending(path: "checkout", directoryHint: .isDirectory)
    staging = root.appending(path: "staging", directoryHint: .isDirectory)
    destination = root.appending(path: "converted", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    pngData = try Data(
      contentsOf: repositoryRoot.appending(
        path: "Tests/Fixtures/Images/test-wallpaper.png"))
  }

  func addPalette() throws {
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(
        path: "Tests/Fixtures/Omarchy/purple-dream/colors.toml"),
      to: checkout.appending(path: "colors.toml")
    )
  }

  func addValidInputs() throws {
    try addPalette()
    try FileManager.default.createDirectory(
      at: checkout.appending(path: "backgrounds"),
      withIntermediateDirectories: true
    )
    try pngData.write(
      to: checkout.appending(
        path:
          "backgrounds/1-scenery-pink-lakeside-sunset-lake-landscape-scenic-panorama-7680x3215-144.png"
      ))
    try jpegData(from: pngData).write(
      to: checkout.appending(path: "backgrounds/digital-mountain.jpg"))
    try pngData.write(to: checkout.appending(path: "backgrounds/shiny_purple.png"))
    try pngData.write(to: checkout.appending(path: "preview.png"))
    try FileManager.default.createDirectory(
      at: checkout.appending(path: "preview"),
      withIntermediateDirectories: true
    )
    for name in ["preview-0.png", "preview-1.png", "preview-2.png"] {
      try pngData.write(to: checkout.appending(path: "preview/\(name)"))
    }
  }

  func addJPEGPreview() throws {
    try jpegData(from: pngData).write(
      to: checkout.appending(path: "preview/preview-3.jpg")
    )
  }

  func convert() throws -> ConvertedOmarchyTheme {
    try OmarchyThemeConverter().convert(
      staged: StagedOmarchyTheme(
        themeID: "purple-dream",
        sourceURL: URL(string: "https://github.com/example/purple-dream")!,
        resolvedCommit: Self.commit,
        checkoutURL: checkout
      ),
      to: destination
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
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

}
