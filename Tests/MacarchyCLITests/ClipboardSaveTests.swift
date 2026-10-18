import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MacarchyCLI

@MainActor
struct ClipboardSaveTests {
  @Test func aFileInTheClipboardFormatGetsTheClipboardBytesUnchanged() throws {
    let fixture = try ClipboardSaveFixture()
    let cases: [(ClipboardImageFormat, String)] = [
      (.png, "same.png"), (.jpeg, "same.JPG"), (.tiff, "same.tif"),
    ]
    for (format, name) in cases {
      let comment = Comment(rawValue: name)
      // Re-encoding would drop these trailing bytes, so their survival proves the passthrough.
      let original =
        try encodeImages([patternImage(width: 30, height: 20)], as: format.type)
        + Data("macarchy-trailing-bytes".utf8)
      fixture.clipboard = [ClipboardImageData(data: original, format: format)]
      let output = fixture.folder.appending(path: name)
      let saved = try fixture.saver.save(to: .file(output))
      #expect(try Data(contentsOf: output) == original, comment)
      #expect(
        saved == SavedClipboardImage(format: format, bytes: original.count, converted: false),
        comment)
    }
  }

  @Test func otherFormatsAreConvertedAtTheirOwnSize() throws {
    let fixture = try ClipboardSaveFixture()
    let png = try pngData(patternImage(width: 30, height: 20))
    let tiff = try encodeImages([patternImage(width: 40, height: 24)], as: .tiff)
    let cases: [(ClipboardImageData, String, ClipboardImageFormat, [Int])] = [
      (ClipboardImageData(data: png, format: .png), "shot.jpeg", .jpeg, [30, 20]),
      (ClipboardImageData(data: tiff, format: .tiff), "scan.png", .png, [40, 24]),
      (ClipboardImageData(data: png, format: .png), "shot.tiff", .tiff, [30, 20]),
    ]
    for (image, name, format, size) in cases {
      let comment = Comment(rawValue: name)
      fixture.clipboard = [image]
      let output = fixture.folder.appending(path: name)
      let saved = try fixture.saver.save(to: .file(output))
      let written = try Data(contentsOf: output)
      #expect(try formatOf(written) == format.type.identifier, comment)
      #expect(try dimensions(written) == size, comment)
      #expect(
        saved == SavedClipboardImage(format: format, bytes: written.count, converted: true),
        comment)
    }
    #expect(try fixture.files() == ["scan.png", "shot.jpeg", "shot.tiff"])
  }

  @Test func aClipboardWithSeveralFormatsGivesUpTheTargetFormatUnchanged() throws {
    let fixture = try ClipboardSaveFixture()
    let png = try pngData(patternImage(width: 30, height: 20))
    let tiff = try encodeImages([patternImage(width: 40, height: 24)], as: .tiff)
    fixture.clipboard = [
      ClipboardImageData(data: tiff, format: .tiff), ClipboardImageData(data: png, format: .png),
    ]
    let cases: [(String, Data, ClipboardImageFormat)] = [
      ("both.tiff", tiff, .tiff), ("both.png", png, .png),
    ]
    for (name, original, format) in cases {
      let output = fixture.folder.appending(path: name)
      let saved = try fixture.saver.save(to: .file(output))
      #expect(try Data(contentsOf: output) == original, Comment(rawValue: name))
      #expect(
        saved == SavedClipboardImage(format: format, bytes: original.count, converted: false),
        Comment(rawValue: name))
    }
    _ = try fixture.saver.save(to: .standardOutput(.tiff))
    #expect(fixture.standardOutput == [tiff])

    let output = fixture.folder.appending(path: "both.jpg")
    let converted = try fixture.saver.save(to: .file(output))
    #expect(converted.converted)
    #expect(try dimensions(Data(contentsOf: output)) == [30, 20])
  }

  @Test func theClipboardIsReadInTheTargetFormatFirstThenOriginalEncodingsBeforeTIFF() {
    #expect(ClipboardImageData.readingOrder() == [.png, .jpeg, .heic, .tiff])
    #expect(ClipboardImageData.readingOrder(preferring: .tiff) == [.tiff, .png, .jpeg, .heic])
    #expect(ClipboardImageData.readingOrder(preferring: .png) == [.png, .jpeg, .heic, .tiff])
  }

  @Test func conversionKeepsTheColorProfile() throws {
    let fixture = try ClipboardSaveFixture()
    let source = try pngData(patternImage(width: 32, height: 32, space: CGColorSpace.displayP3))
    let profile = try #require(try profileName(source))
    #expect(!profile.contains("sRGB"))
    fixture.clipboard = [ClipboardImageData(data: source, format: .png)]
    let output = fixture.folder.appending(path: "wide.jpg")
    _ = try fixture.saver.save(to: .file(output))
    #expect(try profileName(Data(contentsOf: output)) == profile)
  }

  @Test func jpegFlattensTransparencyOntoWhite() throws {
    let fixture = try ClipboardSaveFixture()
    let source = try pngData(halfTransparentImage(width: 40, height: 20))
    fixture.clipboard = [ClipboardImageData(data: source, format: .png)]
    let output = fixture.folder.appending(path: "window.jpg")
    _ = try fixture.saver.save(to: .file(output))
    let written = try Data(contentsOf: output)
    let left = try pixel(written, x: 5, y: 10)
    let right = try pixel(written, x: 35, y: 10)
    #expect(left.allSatisfy { $0 >= 250 })
    #expect(right[0] >= 200 && right[1] <= 60 && right[2] <= 60)
  }

  @Test(.enabled(if: imageIOEncodes(.heic), "ImageIO on this Mac cannot encode HEIC"))
  func heicIsEncodedWhereImageIOSupportsIt() throws {
    let fixture = try ClipboardSaveFixture()
    let png = try pngData(patternImage(width: 64, height: 48))
    fixture.clipboard = [ClipboardImageData(data: png, format: .png)]
    let output = fixture.folder.appending(path: "shot.HEIC")
    let saved = try fixture.saver.save(to: .file(output))
    let written = try Data(contentsOf: output)
    #expect(try formatOf(written) == UTType.heic.identifier)
    #expect(try dimensions(written) == [64, 48])
    #expect(saved == SavedClipboardImage(format: .heic, bytes: written.count, converted: true))
  }

  @Test func theFileMustBeNewInAnExistingFolderWithASupportedExtension() throws {
    let fixture = try ClipboardSaveFixture()
    let png = try pngData(patternImage(width: 30, height: 20))
    fixture.clipboard = [ClipboardImageData(data: png, format: .png)]
    let taken = Data("taken".utf8)
    let existing = fixture.folder.appending(path: "taken.png")
    try taken.write(to: existing, options: .withoutOverwriting)
    let noFolder = fixture.root.appending(path: "missing/out.png")
    let pathFailures: [(URL, ImagePreparationError)] = [
      (existing, .outputExists(existing.path)),
      (noFolder, .outputParent(noFolder.deletingLastPathComponent().path)),
    ]
    for (output, error) in pathFailures {
      #expect(throws: error) { try fixture.saver.save(to: .file(output)) }
    }
    for name in ["clip.gif", "clip.heif", "clip"] {
      let output = fixture.folder.appending(path: name)
      #expect(throws: ClipboardSaveError.unsupportedExtension(output.path)) {
        try fixture.saver.save(to: .file(output))
      }
    }
    #expect(try Data(contentsOf: existing) == taken)
    #expect(try fixture.files() == ["taken.png"])
    #expect(!FileManager.default.fileExists(atPath: noFolder.deletingLastPathComponent().path))
  }

  @Test func undecodableClipboardDataFailsConversionAndWritesNothing() throws {
    let fixture = try ClipboardSaveFixture()
    fixture.clipboard = [ClipboardImageData(data: Data("not an image".utf8), format: .png)]
    let output = fixture.folder.appending(path: "broken.jpg")
    #expect(throws: ClipboardSaveError.conversionFailed(.jpeg)) {
      try fixture.saver.save(to: .file(output))
    }
    #expect(throws: ClipboardSaveError.conversionFailed(.tiff)) {
      try fixture.saver.save(to: .standardOutput(.tiff))
    }
    #expect(
      String(describing: ClipboardSaveError.conversionFailed(.jpeg))
        == "Could not convert the clipboard image to JPEG. Nothing was written.")
    #expect(try fixture.files() == [])
    #expect(fixture.standardOutput.isEmpty)
  }

  @Test func aClipboardWithoutAnImagePointsToPbpasteAndWritesNothing() throws {
    let fixture = try ClipboardSaveFixture()
    #expect(throws: ClipboardSaveError.noImage) {
      try fixture.saver.save(to: .file(fixture.folder.appending(path: "shot.png")))
    }
    #expect(throws: ClipboardSaveError.noImage) {
      try fixture.saver.save(to: .standardOutput(.png))
    }
    #expect(
      String(describing: ClipboardSaveError.noImage)
        == "The clipboard has no image. For text, use pbpaste.")
    #expect(try fixture.files() == [])
    #expect(fixture.standardOutput.isEmpty)
  }

  @Test func standardOutputRefusesATerminal() throws {
    let fixture = try ClipboardSaveFixture()
    let png = try pngData(patternImage(width: 30, height: 20))
    fixture.clipboard = [ClipboardImageData(data: png, format: .png)]
    fixture.terminal = true
    #expect(throws: ClipboardSaveError.terminal) {
      try fixture.saver.save(to: .standardOutput(.png))
    }
    #expect(
      String(describing: ClipboardSaveError.terminal)
        == "Refusing to write image data to a terminal. Redirect it, for example: "
        + "macarchy clipboard save - > image.png")
    #expect(fixture.standardOutput.isEmpty)

    let output = fixture.folder.appending(path: "shot.png")
    _ = try fixture.saver.save(to: .file(output))
    #expect(try fixture.files() == ["shot.png"])
    #expect(fixture.standardOutput.isEmpty)
  }

  @Test func standardOutputGetsOnlyTheImageInTheChosenFormat() throws {
    let fixture = try ClipboardSaveFixture()
    let png = try pngData(patternImage(width: 30, height: 20))
    fixture.clipboard = [ClipboardImageData(data: png, format: .png)]
    let same = try fixture.saver.save(to: .standardOutput(.png))
    #expect(fixture.standardOutput == [png])
    #expect(same == SavedClipboardImage(format: .png, bytes: png.count, converted: false))

    let converted = try fixture.saver.save(to: .standardOutput(.jpeg))
    #expect(fixture.standardOutput.count == 2)
    let jpeg = try #require(fixture.standardOutput.last)
    #expect(try formatOf(jpeg) == UTType.jpeg.identifier)
    #expect(try dimensions(jpeg) == [30, 20])
    #expect(converted == SavedClipboardImage(format: .jpeg, bytes: jpeg.count, converted: true))
    #expect(try fixture.files() == [])
  }

  @Test func outputLineAndJSONDescribeTheSavedFile() throws {
    let saved = SavedClipboardImage(format: .png, bytes: 412_300, converted: true)
    let output = URL(filePath: "/tmp/macarchy/shot.png")
    #expect(
      saved.message(savedTo: output)
        == "Saved the clipboard image to /tmp/macarchy/shot.png (PNG, 412 KB).")
    let desktop = URL(filePath: NSHomeDirectory()).appending(path: "Desktop/shot.heic")
    let heic = SavedClipboardImage(format: .heic, bytes: 900, converted: false)
    #expect(
      heic.message(savedTo: desktop)
        == "Saved the clipboard image to ~/Desktop/shot.heic (HEIC, 900 bytes).")

    let text = try saved.renderJSON(savedTo: output)
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(Set(json.keys) == ["status", "output", "format", "bytes", "converted"])
    #expect((json["status"] as? String) == "saved")
    #expect((json["output"] as? String) == "/tmp/macarchy/shot.png")
    #expect((json["format"] as? String) == "public.png")
    #expect((json["bytes"] as? Int) == 412_300)
    #expect((json["converted"] as? Bool) == true)
  }

  @Test func commandLineChoosesAFileOrStandardOutput() throws {
    let piped = try #require(
      Macarchy.parseAsRoot(["clipboard", "save", "-"]) as? ClipboardCommand.Save)
    #expect(piped.destination == .standardOutput(.png))
    #expect(!piped.json)

    let heic = try #require(
      Macarchy.parseAsRoot(["clipboard", "save", "-", "--format", "heic"])
        as? ClipboardCommand.Save)
    #expect(heic.destination == .standardOutput(.heic))

    let file = try #require(
      Macarchy.parseAsRoot(["clipboard", "save", "/tmp/shot.PNG", "--json"])
        as? ClipboardCommand.Save)
    #expect(file.destination == .file(URL(filePath: "/tmp/shot.PNG").standardizedFileURL))
    #expect(file.json)

    for arguments in [
      ["clipboard", "save"],
      ["clipboard", "save", ""],
      ["clipboard", "save", "-", "--json"],
      ["clipboard", "save", "/tmp/shot.png", "--format", "png"],
      ["clipboard", "save", "-", "--format", "webp"],
    ] {
      #expect(throws: (any Error).self, Comment(rawValue: arguments.joined(separator: " "))) {
        try Macarchy.parseAsRoot(arguments)
      }
    }
  }
}

/// ImageIO may list a type that this machine cannot actually encode, for example HEIC without
/// a hardware encoder, so this also encodes a small image.
func imageIOEncodes(_ format: ClipboardImageFormat) -> Bool {
  guard
    (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(format.type.identifier),
    let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
    let image = context.makeImage()
  else { return false }
  let data = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      data, format.type.identifier as CFString, 1, nil)
  else { return false }
  CGImageDestinationAddImage(destination, image, nil)
  return CGImageDestinationFinalize(destination)
}

@MainActor
private final class ClipboardSaveFixture {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-clipboard-save-test-\(UUID())")
  /// The image formats the clipboard holds, in any order.
  var clipboard: [ClipboardImageData] = []
  var terminal = false
  var standardOutput: [Data] = []

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var folder: URL { root.appending(path: "Desktop", directoryHint: .isDirectory) }

  var saver: ClipboardImageSaver {
    ClipboardImageSaver(
      clipboardImage: { [self] preferred in
        for format in ClipboardImageData.readingOrder(preferring: preferred) {
          if let image = clipboard.first(where: { $0.format == format }) { return image }
        }
        return nil
      },
      writeStandardOutput: { [self] in standardOutput.append($0) },
      standardOutputIsTerminal: { [self] in terminal })
  }

  func files() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
  }
}
