import AppKit
import Foundation
import ImageIO
import ThemeCore
import UniformTypeIdentifiers

struct ScreenshotOutcome: Encodable, Equatable {
  enum Status: String, Encodable { case copied, cancelled }
  let status: Status
  let savedPath: String?

  static let cancelled = Self(status: .cancelled, savedPath: nil)

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    if status == .cancelled { return "Screenshot cancelled." }
    return "Screenshot copied to clipboard."
      + (savedPath.map { " Saved PNG: \($0)" } ?? "")
  }
}

/// Only the current board's change counter/types are inspected for a direct
/// capture. Never read or retain its previous contents, including on failure.
@MainActor
struct ScreenshotClipboard {
  let changeCount: () -> Int
  let containsImage: () -> Bool
  let copyPNG: (Data) throws -> Void

  static let live = Self(
    changeCount: { NSPasteboard.general.changeCount },
    containsImage: {
      NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
    },
    copyPNG: { data in
      guard let representation = NSBitmapImageRep(data: data),
        let tiff = representation.tiffRepresentation
      else { throw ScreenshotError.invalidImage }
      let item = NSPasteboardItem()
      guard item.setData(data, forType: .png), item.setData(tiff, forType: .tiff) else {
        throw ScreenshotError.clipboardWrite
      }
      let board = NSPasteboard.general
      board.clearContents()
      guard board.writeObjects([item]) else { throw ScreenshotError.clipboardWrite }
    })
}

/// The OS executable owns capture/selection. Macarchy does not call Screen
/// Recording APIs, enumerate windows, request TCC or install a capture daemon.
@MainActor
struct ScreenshotCapture {
  let executableURL: URL
  let run: (ProcessRequest) throws -> ProcessResult
  let clipboard: ScreenshotClipboard
  let temporaryRoot: URL

  static var live: Self {
    Self(
      executableURL: URL(filePath: "/usr/sbin/screencapture"), run: ProcessRunner.live.run,
      clipboard: .live, temporaryRoot: FileManager.default.temporaryDirectory)
  }

  func execute(window: Bool = false, saveURL: URL? = nil) throws -> ScreenshotOutcome {
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw ScreenshotError.missingProvider(executableURL.path)
    }
    let arguments = ["-i", "-t", "png"] + (window ? ["-W"] : [])
    if let saveURL {
      try validateDestination(saveURL)
      return try captureAndSave(arguments: arguments, destination: saveURL)
    }

    let before = clipboard.changeCount()
    try capture(arguments + ["-c"])
    guard clipboard.changeCount() != before else { return .cancelled }
    guard clipboard.containsImage() else { throw ScreenshotError.clipboardChanged }
    return ScreenshotOutcome(status: .copied, savedPath: nil)
  }

  private func capture(_ arguments: [String]) throws {
    // Selection is user-paced: no timer that could publish/kill a capture while
    // the user is still choosing. Nonzero/diagnostic results are never hidden as
    // cancellation, even if no new image was produced.
    let result = try run(ProcessRequest(executableURL: executableURL, arguments: arguments))
    guard result.terminationStatus == 0, result.output.isEmpty else {
      throw ScreenshotError.nativeFailure(result.terminationStatus, result.output)
    }
  }

  private func validateDestination(_ destination: URL) throws {
    guard destination.isFileURL, destination.pathExtension.lowercased() == "png" else {
      throw ScreenshotError.destination("Use a PNG file path.")
    }
    // Includes dangling links; the final exclusive write also rechecks existence.
    if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
      throw ScreenshotError.destination("Already exists: \(destination.path)")
    }
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: destination.deletingLastPathComponent().path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ScreenshotError.destination("The destination's parent directory must exist.") }
  }

  private func captureAndSave(arguments: [String], destination: URL) throws -> ScreenshotOutcome {
    // Only --save stages on disk. A private per-attempt file avoids exporting
    // an unrelated copy if another application changes the shared clipboard.
    let folder = temporaryRoot.appending(
      path: "macarchy-capture-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let result = Result { () throws -> ScreenshotOutcome in
      let captured = folder.appending(path: "capture.png")
      let before = clipboard.changeCount()
      try capture(arguments + [captured.path])
      guard FileManager.default.fileExists(atPath: captured.path) else {
        guard clipboard.changeCount() == before else { throw ScreenshotError.missingSavedImage }
        return .cancelled
      }
      let data = try BoundedRegularFile.read(at: captured, maximumSize: 128 * 1_048_576).data
      guard let image = CGImageSourceCreateWithData(data as CFData, nil),
        CGImageSourceGetType(image) as String? == UTType.png.identifier,
        CGImageSourceGetStatus(image) == .statusComplete,
        CGImageSourceGetCount(image) == 1,
        CGImageSourceCreateImageAtIndex(image, 0, nil) != nil
      else { throw ScreenshotError.invalidImage }
      // Do not combine .atomic with .withoutOverwriting: the latter is the
      // explicit no-clobber contract, including a destination created mid-picker.
      try data.write(to: destination, options: .withoutOverwriting)
      do { try clipboard.copyPNG(data) } catch {
        throw ScreenshotError.savedButNotCopied(destination.path, String(describing: error))
      }
      return ScreenshotOutcome(status: .copied, savedPath: destination.path)
    }
    do { try FileManager.default.removeItem(at: folder) } catch {
      let preceding: String
      switch result {
      case .success(let outcome): preceding = try outcome.render(json: false)
      case .failure(let failure): preceding = String(describing: failure)
      }
      throw ScreenshotError.cleanup(folder.path, preceding, String(describing: error))
    }
    return try result.get()
  }
}

enum ScreenshotError: Error, CustomStringConvertible {
  case missingProvider(String)
  case nativeFailure(Int32, String)
  case clipboardChanged
  case clipboardWrite
  case destination(String)
  case invalidImage
  case missingSavedImage
  case savedButNotCopied(String, String)
  case cleanup(String, String, String)

  var description: String {
    switch self {
    case .missingProvider(let path): "Native screenshot provider is not executable: \(path)"
    case .nativeFailure(let code, let detail):
      "Native screenshot failed (exit \(code))."
        + (detail.isEmpty ? " No diagnostic was returned." : " \(detail)")
        + " If macOS denied screen access, review Screen & System Audio Recording permission for the launching app/process in System Settings. Macarchy does not grant permissions or retry automatically."
    case .clipboardChanged:
      "The clipboard changed but contains no image. It may have been replaced by another app; no previous clipboard contents were restored."
    case .clipboardWrite: "Could not copy the screenshot to the clipboard."
    case .destination(let detail): "Cannot save screenshot. \(detail)"
    case .invalidImage: "The native capture did not produce a complete PNG image."
    case .missingSavedImage:
      "The clipboard changed but the native picker produced no file. Nothing was saved; retry without holding Control during file capture."
    case .savedButNotCopied(let path, let detail):
      "Screenshot saved to \(path), but clipboard copying failed: \(detail)"
    case .cleanup(let path, let preceding, let detail):
      "\(preceding) Could not remove private screenshot staging at \(path): \(detail)"
    }
  }
}
