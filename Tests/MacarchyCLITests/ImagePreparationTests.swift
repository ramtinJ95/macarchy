import AppKit
import ArgumentParser
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MacarchyCLI

@MainActor
struct ImagePreparationTests {
  @Test func presetsMatchTheDocumentedTable() {
    #expect(ImagePreset.allCases == [.share, .small, .png])
    #expect(
      ImagePreset.share.parameters
        == ImagePreset.Parameters(
          format: .jpeg, fileExtension: "jpg", quality: 0.8, maxEdge: 2048,
          title: "Share — JPEG, up to 2048 px"))
    #expect(
      ImagePreset.small.parameters
        == ImagePreset.Parameters(
          format: .jpeg, fileExtension: "jpg", quality: 0.7, maxEdge: 1280,
          title: "Small — JPEG, up to 1280 px"))
    #expect(
      ImagePreset.png.parameters
        == ImagePreset.Parameters(
          format: .png, fileExtension: "png", quality: nil, maxEdge: nil,
          title: "PNG — lossless, original size"))
  }

  @Test func presetsCapTheLongestEdgeAndNeverUpscale() throws {
    let large = try jpegData(patternImage(width: 2560, height: 1280))
    let tiny = try jpegData(patternImage(width: 30, height: 20))
    let expected: [(ImagePreset, [Int])] = [
      (.share, [2048, 1024]), (.small, [1280, 640]), (.png, [2560, 1280]),
    ]
    var sizes: [ImagePreset: Int] = [:]
    for (preset, size) in expected {
      let comment = Comment(rawValue: preset.rawValue)
      let encoded = try ImagePreparation.encode(large, preset: preset, subject: "large")
      #expect(try dimensions(encoded.data) == size, comment)
      #expect([encoded.pixelWidth, encoded.pixelHeight] == size, comment)
      #expect(try formatOf(encoded.data) == preset.parameters.format.identifier, comment)
      sizes[preset] = encoded.data.count
      let uncapped = try ImagePreparation.encode(tiny, preset: preset, subject: "tiny")
      #expect(try dimensions(uncapped.data) == [30, 20], comment)
    }
    let share = try #require(sizes[.share])
    let small = try #require(sizes[.small])
    #expect(small <= share)
  }

  @Test func orientationIsAppliedToThePixels() throws {
    let rotated = try jpegData(
      patternImage(width: 40, height: 20), properties: [kCGImagePropertyOrientation: 6])
    #expect(try orientation(rotated) == 6)
    for preset in ImagePreset.allCases {
      let comment = Comment(rawValue: preset.rawValue)
      let encoded = try ImagePreparation.encode(rotated, preset: preset, subject: "rotated")
      #expect(try dimensions(encoded.data) == [20, 40], comment)
      #expect(try orientation(encoded.data) == 1, comment)
    }
  }

  @Test func outputIsSRGBAndCarriesNoSourceMetadata() throws {
    let marker = "macarchy-private-marker"
    let taken = "2001:02:03 04:05:06"
    let metadata: [CFString: Any] = [
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifUserComment: marker, kCGImagePropertyExifLensModel: marker,
        kCGImagePropertyExifDateTimeOriginal: taken,
      ] as [CFString: Any],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: marker, kCGImagePropertyTIFFModel: marker,
        kCGImagePropertyTIFFSoftware: marker,
      ] as [CFString: Any],
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 52.37, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 4.89, kCGImagePropertyGPSLongitudeRef: "E",
      ] as [CFString: Any],
      kCGImagePropertyIPTCDictionary: [
        kCGImagePropertyIPTCCaptionAbstract: marker
      ] as [CFString: Any],
    ]
    let source = try jpegData(
      patternImage(width: 64, height: 48, space: CGColorSpace.displayP3), properties: metadata)
    #expect(try properties(of: source).keys.contains(kCGImagePropertyGPSDictionary))
    #expect(source.range(of: Data(marker.utf8)) != nil)
    #expect(try profileName(source)?.contains("sRGB") == false)
    for preset in ImagePreset.allCases {
      let comment = Comment(rawValue: preset.rawValue)
      let output = try ImagePreparation.encode(source, preset: preset, subject: "tagged").data
      let written = try properties(of: output)
      let keys = written.keys
      #expect(!keys.contains(kCGImagePropertyGPSDictionary), comment)
      #expect(!keys.contains(kCGImagePropertyIPTCDictionary), comment)
      #expect(!keys.contains(kCGImagePropertyTIFFDictionary), comment)
      // ImageIO itself describes the new file; nothing else may survive.
      let exif = written[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
      let describing: Set<CFString> = [
        kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension,
        kCGImagePropertyExifPixelYDimension,
      ]
      #expect(Set(exif.keys).isSubset(of: describing), comment)
      for text in [marker, taken, "x:xmpmeta"] {
        #expect(output.range(of: Data(text.utf8)) == nil, Comment(rawValue: "\(preset) \(text)"))
      }
      #expect(try profileName(output)?.contains("sRGB") == true, comment)
    }
  }

  @Test func pngKeepsTransparencyAndJPEGFlattensItOntoWhite() throws {
    let source = try pngData(halfTransparentImage(width: 40, height: 20))
    let png = try ImagePreparation.encode(source, preset: .png, subject: "alpha").data
    #expect(try pixel(png, x: 5, y: 10)[3] == 0)
    #expect(try pixel(png, x: 35, y: 10)[3] == 255)
    let pngAlpha = try properties(of: png)[kCGImagePropertyHasAlpha] as? Bool
    #expect(pngAlpha == true)

    let jpeg = try ImagePreparation.encode(source, preset: .share, subject: "alpha").data
    let left = try pixel(jpeg, x: 5, y: 10)
    let right = try pixel(jpeg, x: 35, y: 10)
    #expect(left.allSatisfy { $0 >= 250 })
    #expect(right[0] >= 200 && right[1] <= 60 && right[2] <= 60 && right[3] == 255)
    let jpegAlpha = try properties(of: jpeg)[kCGImagePropertyHasAlpha] as? Bool
    #expect(jpegAlpha != true)
  }

  @Test func multiFrameSourcesUseThePrimaryFrameAndSaySo() throws {
    let fixture = try ImageFixture()
    let gif = try fixture.file(
      "animation.gif",
      encodeImages(
        [patternImage(width: 8, height: 6), halfTransparentImage(width: 8, height: 6)],
        as: .gif))
    let still = try fixture.file("still.png", pngData(patternImage(width: 8, height: 6)))
    let animated = try fixture.engine.prepare(.file(gif), preset: .png, copy: false, reveal: false)
    #expect(animated.primaryFrameOnly)
    #expect(animated.pixelWidth == 8 && animated.pixelHeight == 6)
    #expect(try dimensions(Data(contentsOf: animated.output)) == [8, 6])
    #expect(animated.message(copied: false).contains("primary frame only"))
    let single = try fixture.engine.prepare(.file(still), preset: .png, copy: false, reveal: false)
    #expect(!single.primaryFrameOnly)
    #expect(!single.message(copied: false).contains("primary frame only"))
  }

  @Test func unreadableSourcesFailWithoutWritingAnything() throws {
    let fixture = try ImageFixture()
    let text = try fixture.file("notes.jpg", Data("not an image".utf8))
    let empty = try fixture.file("empty.png", Data())
    let missing = fixture.pictures.appending(path: "missing.png")
    let failures: [(URL, ImagePreparationError)] = [
      (text, .notAnImage(text.path)), (empty, .empty(empty.path)),
      (missing, .missing(missing.path)),
    ]
    for (url, error) in failures {
      #expect(throws: error) {
        try fixture.engine.prepare(.file(url), preset: .share, copy: true, reveal: true)
      }
    }
    #expect(try fixture.files() == ["empty.png", "notes.jpg"])
    #expect(fixture.copies.isEmpty)
    #expect(fixture.revealed.isEmpty)
  }

  @Test func resultGoesBesideTheSourceAndStepsPastExistingNames() throws {
    let fixture = try ImageFixture()
    let source = try fixture.file("photo.jpeg", jpegData(patternImage(width: 30, height: 20)))
    let first = try fixture.engine.prepare(
      .file(source), preset: .share, copy: false, reveal: false)
    #expect(first.output.path == fixture.pictures.appending(path: "photo-share.jpg").path)
    let taken = Data("taken".utf8)
    _ = try fixture.file("photo-small.jpg", taken)
    _ = try fixture.file("photo-small-2.jpg", taken)
    let third = try fixture.engine.prepare(
      .file(source), preset: .small, copy: false, reveal: false)
    #expect(third.output.path == fixture.pictures.appending(path: "photo-small-3.jpg").path)
    #expect(try Data(contentsOf: fixture.pictures.appending(path: "photo-small.jpg")) == taken)
    #expect(try Data(contentsOf: fixture.pictures.appending(path: "photo-small-2.jpg")) == taken)
    let saved = try Data(contentsOf: third.output)
    #expect(saved.count == third.bytes)
    #expect(try dimensions(saved) == [30, 20])
  }

  @Test func exhaustedNamesFailExplicitly() throws {
    let fixture = try ImageFixture()
    let source = try fixture.file("photo.png", pngData(patternImage(width: 4, height: 4)))
    for attempt in 1...ImagePreparation.maximumNameAttempts {
      let suffix = attempt == 1 ? "" : "-\(attempt)"
      _ = try fixture.file("photo-png\(suffix).png", Data("taken".utf8))
    }
    let before = try fixture.files()
    #expect(before.count == ImagePreparation.maximumNameAttempts + 1)
    let first = fixture.pictures.appending(path: "photo-png.png").path
    #expect(throws: ImagePreparationError.namesExhausted(first)) {
      try fixture.engine.prepare(.file(source), preset: .png, copy: true, reveal: true)
    }
    #expect(try fixture.files() == before)
    #expect(fixture.copies.isEmpty)
    #expect(fixture.revealed.isEmpty)
  }

  @Test func explicitOutputMustBeNewInAnExistingFolderWithThePresetExtension() throws {
    let fixture = try ImageFixture()
    let source = try fixture.file("photo.png", pngData(patternImage(width: 30, height: 20)))
    let taken = Data("taken".utf8)
    let existing = try fixture.file("taken.jpg", taken)
    let wrongExtension = fixture.pictures.appending(path: "out.png")
    let noFolder = fixture.root.appending(path: "missing/out.jpg")
    let failures: [(URL, ImagePreparationError)] = [
      (existing, .outputExists(existing.path)),
      (wrongExtension, .outputExtension(wrongExtension.path, .share)),
      (noFolder, .outputParent(noFolder.deletingLastPathComponent().path)),
    ]
    for (output, error) in failures {
      #expect(throws: error) {
        try fixture.engine.prepare(
          .file(source), preset: .share, output: output, copy: true, reveal: true)
      }
    }
    #expect(try Data(contentsOf: existing) == taken)
    #expect(try fixture.files() == ["photo.png", "taken.jpg"])
    #expect(fixture.copies.isEmpty)

    let chosen = fixture.pictures.appending(path: "chosen.JPEG")
    let prepared = try fixture.engine.prepare(
      .file(source), preset: .share, output: chosen, copy: false, reveal: false)
    #expect(prepared.output == chosen)
    #expect(try fixture.files() == ["chosen.JPEG", "photo.png", "taken.jpg"])
  }

  @Test func sourceBytesAndModificationDateStayUnchanged() throws {
    let fixture = try ImageFixture()
    let source = try fixture.file("photo.jpg", jpegData(patternImage(width: 64, height: 48)))
    let date = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
    let bytes = try Data(contentsOf: source)
    for preset in ImagePreset.allCases {
      _ = try fixture.engine.prepare(.file(source), preset: preset, copy: true, reveal: true)
    }
    #expect(try Data(contentsOf: source) == bytes)
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    #expect((attributes[.modificationDate] as? Date) == date)
    #expect(
      try fixture.files() == ["photo-png.png", "photo-share.jpg", "photo-small.jpg", "photo.jpg"])
  }

  @Test func clipboardImageGoesToDownloadsWithATimestampAndIsCopied() throws {
    let fixture = try ImageFixture()
    fixture.clipboard = try pngData(patternImage(width: 30, height: 20))
    fixture.now = try #require(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 10, day: 18, hour: 11, minute: 30, second: 5)))
    let prepared = try fixture.engine.prepare(.clipboard, preset: .share, copy: true, reveal: false)
    #expect(
      prepared.output.path
        == fixture.downloads.appending(path: "clipboard-20261018-113005-share.jpg").path)
    let saved = try Data(contentsOf: prepared.output)
    #expect(
      fixture.copies == [ImageFixture.Copy(file: prepared.output, data: saved, format: .jpeg)])
    #expect(fixture.revealed.isEmpty)
    #expect(try dimensions(saved) == [30, 20])

    let again = try fixture.engine.prepare(.clipboard, preset: .share, copy: false, reveal: true)
    #expect(again.output.lastPathComponent == "clipboard-20261018-113005-share-2.jpg")
    #expect(fixture.revealed == [again.output])
    #expect(fixture.copies.count == 1)
    #expect(fixture.clipboardReads == 2)
    #expect(try fixture.files() == [])
  }

  @Test func clipboardWithoutAnImageFailsWithoutWriting() throws {
    let fixture = try ImageFixture()
    #expect(throws: ImagePreparationError.noClipboardImage) {
      try fixture.engine.prepare(.clipboard, preset: .share, copy: true, reveal: true)
    }
    #expect(
      String(describing: ImagePreparationError.noClipboardImage) == "The clipboard has no image.")
    #expect(fixture.clipboardReads == 1)
    #expect(try fixture.files(fixture.downloads) == [])
    #expect(fixture.copies.isEmpty)
    #expect(fixture.revealed.isEmpty)
  }

  @Test func copyFailureAfterSavingIsReportedAndKeepsTheFile() throws {
    let fixture = try ImageFixture()
    let source = try fixture.file("photo.png", pngData(patternImage(width: 30, height: 20)))
    let saved = fixture.pictures.appending(path: "photo-small.jpg")
    fixture.failCopy = true
    do {
      _ = try fixture.engine.prepare(.file(source), preset: .small, copy: true, reveal: true)
      Issue.record("A failed clipboard copy was reported as success")
    } catch let error as ImagePreparationError {
      let detail = String(describing: ImagePreparationError.clipboardWrite)
      #expect(error == .savedButNotCopied(saved.path, detail))
      #expect(
        String(describing: error)
          == "Saved \(saved.path), but copying it to the clipboard failed: \(detail)")
    }
    #expect(try dimensions(Data(contentsOf: saved)) == [30, 20])
    #expect(fixture.revealed.map(\.path) == [saved.path])
  }

  @Test func clipboardIsTouchedOnlyWhenCopyingAndFinderOnlyWhenRevealing() throws {
    let fixture = try ImageFixture()
    let source = try fixture.file("photo.png", pngData(patternImage(width: 30, height: 20)))
    let quiet = try fixture.engine.prepare(.file(source), preset: .png, copy: false, reveal: false)
    #expect(quiet.output.lastPathComponent == "photo-png.png")
    #expect(fixture.copies.isEmpty)
    #expect(fixture.revealed.isEmpty)

    let shown = try fixture.engine.prepare(.file(source), preset: .png, copy: true, reveal: true)
    #expect(shown.output.lastPathComponent == "photo-png-2.png")
    #expect(fixture.copies.map(\.file) == [shown.output])
    #expect(fixture.copies.map(\.format) == [UTType.png])
    #expect(fixture.revealed == [shown.output])
    #expect(fixture.clipboardReads == 0)
  }

  @Test func cancellingTheDialogOrTheFilePanelWritesNothing() throws {
    let fixture = try ImageFixture()
    fixture.clipboard = try pngData(patternImage(width: 30, height: 20))
    let dismissed = try fixture.engine.choose(
      pick: { nil },
      chooseFile: {
        Issue.record("The file panel opened after the dialog was cancelled")
        return nil
      })
    #expect(dismissed == nil)
    let noFile = try fixture.engine.choose(
      pick: { (ImagePreset.png, ImageSourceChoice.file) }, chooseFile: { nil })
    #expect(noFile == nil)
    #expect(try fixture.files() == [])
    #expect(try fixture.files(fixture.downloads) == [])
    #expect(fixture.copies.isEmpty)
    #expect(fixture.revealed.isEmpty)
    #expect(fixture.clipboardReads == 0)
  }

  @Test func menuChoicePreparesCopiesAndRevealsTheResult() throws {
    let fixture = try ImageFixture()
    let source = try fixture.file("photo.png", pngData(patternImage(width: 30, height: 20)))
    let chosen = try fixture.engine.choose(
      pick: { (ImagePreset.small, ImageSourceChoice.file) }, chooseFile: { source })
    let fromFile = try #require(chosen)
    #expect(fromFile.output.path == fixture.pictures.appending(path: "photo-small.jpg").path)

    fixture.clipboard = try pngData(patternImage(width: 30, height: 20))
    let pasted = try fixture.engine.choose(
      pick: { (ImagePreset.png, ImageSourceChoice.clipboard) },
      chooseFile: {
        Issue.record("The file panel opened for a clipboard image")
        return nil
      })
    let fromClipboard = try #require(pasted)
    #expect(try fixture.files(fixture.downloads) == [fromClipboard.output.lastPathComponent])
    #expect(fromClipboard.output.pathExtension == "png")
    #expect(fixture.copies.map(\.file) == [fromFile.output, fromClipboard.output])
    #expect(fixture.revealed == [fromFile.output, fromClipboard.output])
    #expect(ImageSourceChoice.allCases.map(\.title) == ["Use clipboard image", "Choose file…"])
  }

  @Test func outputLineAndJSONDescribeTheResult() throws {
    let prepared = PreparedImage(
      output: URL(filePath: "/tmp/macarchy/photo-share.jpg"), pixelWidth: 2048,
      pixelHeight: 1365, bytes: 412_300, primaryFrameOnly: false)
    #expect(
      prepared.message(copied: true)
        == "Prepared photo-share.jpg (2048×1365, 412 KB) in /tmp/macarchy, copied to the clipboard."
    )
    #expect(
      prepared.message(copied: false)
        == "Prepared photo-share.jpg (2048×1365, 412 KB) in /tmp/macarchy.")
    #expect(PreparedImage.size(2_500_000) == "2.5 MB")

    let animated = PreparedImage(
      output: URL(filePath: "/tmp/macarchy/a-png.png"), pixelWidth: 8, pixelHeight: 6,
      bytes: 900, primaryFrameOnly: true)
    #expect(
      animated.message(copied: false)
        == "Prepared a-png.png (8×6, 900 bytes, primary frame only) in /tmp/macarchy.")
    let text = try animated.renderJSON()
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(Set(json.keys) == ["status", "output", "width", "height", "bytes", "primaryFrameOnly"])
    #expect((json["status"] as? String) == "prepared")
    #expect((json["output"] as? String) == "/tmp/macarchy/a-png.png")
    #expect((json["width"] as? Int) == 8)
    #expect((json["height"] as? Int) == 6)
    #expect((json["bytes"] as? Int) == 900)
    #expect((json["primaryFrameOnly"] as? Bool) == true)
  }

  @Test func commandLineNeedsExactlyOneSourceAndAPreset() throws {
    let file = try #require(
      Macarchy.parseAsRoot(["image", "prepare", "/tmp/photo.heic", "--preset", "small"])
        as? ImageCommand.Prepare)
    #expect(file.path == "/tmp/photo.heic")
    #expect(file.source != .clipboard)
    #expect(file.preset == .small)
    #expect(!file.noCopy && !file.reveal && !file.json && file.output == nil)

    let clipboard = try #require(
      Macarchy.parseAsRoot([
        "image", "prepare", "--clipboard", "--preset", "png", "--no-copy", "--reveal", "--json",
        "--output", "/tmp/out.png",
      ]) as? ImageCommand.Prepare)
    #expect(clipboard.source == .clipboard)
    #expect(clipboard.preset == .png)
    #expect(clipboard.noCopy && clipboard.reveal && clipboard.json)
    #expect(clipboard.output == "/tmp/out.png")

    let choose = try #require(
      Macarchy.parseAsRoot(["image", "choose", "--alert-on-error"]) as? ImageCommand.Choose)
    #expect(choose.alertOnError)

    for arguments in [
      ["image", "prepare", "--preset", "share"],
      ["image", "prepare", "/tmp/photo.png", "--clipboard", "--preset", "share"],
      ["image", "prepare", "/tmp/photo.png"],
      ["image", "prepare", "/tmp/photo.png", "--preset", "webp"],
      ["image", "prepare", "/tmp/photo.png", "--preset", "share", "--output", ""],
    ] {
      #expect(throws: (any Error).self, Comment(rawValue: arguments.joined(separator: " "))) {
        try Macarchy.parseAsRoot(arguments)
      }
    }
  }
}

@MainActor
private final class ImageFixture {
  struct Copy: Equatable {
    let file: URL
    let data: Data
    let format: UTType
  }

  let root = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-image-test-\(UUID())")
  var clipboard: Data?
  var clipboardReads = 0
  var copies: [Copy] = []
  var revealed: [URL] = []
  var failCopy = false
  var now = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    for folder in [pictures, downloads] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var pictures: URL { root.appending(path: "Pictures", directoryHint: .isDirectory) }
  var downloads: URL { root.appending(path: "Downloads", directoryHint: .isDirectory) }

  var engine: ImagePreparation {
    ImagePreparation(
      clipboardImage: { [self] in
        clipboardReads += 1
        return clipboard
      },
      copyToClipboard: { [self] file, data, format in
        if failCopy { throw ImagePreparationError.clipboardWrite }
        copies.append(Copy(file: file, data: data, format: format))
      },
      showInFinder: { [self] in revealed.append($0) },
      now: { [self] in now },
      downloads: downloads)
  }

  func file(_ name: String, _ data: Data) throws -> URL {
    let url = pictures.appending(path: name)
    try data.write(to: url, options: .withoutOverwriting)
    return url
  }

  func files(_ folder: URL? = nil) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: (folder ?? pictures).path).sorted()
  }
}
