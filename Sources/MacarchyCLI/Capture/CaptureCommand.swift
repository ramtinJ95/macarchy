import AppKit
import ArgumentParser
import Foundation

struct CaptureCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture",
    abstract: "Capture screenshots, recognize text or annotate with Flameshot.",
    subcommands: [Screenshot.self, Annotate.self, OCR.self])

  struct OCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "ocr", abstract: "Select a region and copy English text using on-device Vision.",
      discussion: """
        Escape cancels. Do not hold Control: it redirects the native capture to an image copy.
        The private temporary PNG is deleted before recognition; recognized text is never printed.
        """)

    @Flag(help: "Emit status only as JSON, never recognized text.")
    var json = false

    @Flag(help: .hidden)
    var alertOnError = false

    @MainActor
    mutating func run() async throws {
      do {
        let outcome = try RegionTextCapture.live.execute()
        print(try outcome.render(json: json))
        if alertOnError && outcome == .noText {
          CaptureCommand.showAlert(try outcome.render(json: false), style: .informational)
        }
      } catch {
        if alertOnError { CaptureCommand.showAlert(String(describing: error)) }
        throw error
      }
    }
  }

  struct Annotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Select, annotate and copy a screenshot using Flameshot.")

    @Flag(help: "Emit the outcome as JSON, without image or clipboard contents.")
    var json = false

    @Flag(help: .hidden)
    var alertOnError = false

    @MainActor
    mutating func run() async throws {
      do {
        print(try FlameshotCapture.live.execute().render(json: json))
      } catch {
        if alertOnError { CaptureCommand.showAlert(String(describing: error)) }
        throw error
      }
    }
  }

  struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Select a region or window and copy its image to the clipboard.",
      discussion: "Space switches between region and window selection; Escape cancels.")

    @Flag(help: "Start in window-selection mode.")
    var window = false

    @Option(help: "Also save a PNG at this path. Its parent must exist; never overwrites a file.")
    var save: String?

    @Flag(help: "Emit the outcome as JSON, without image or clipboard contents.")
    var json = false

    @Flag(help: .hidden)
    var alertOnError = false

    mutating func validate() throws {
      if let save, save.isEmpty || URL(filePath: save).pathExtension.lowercased() != "png" {
        throw ValidationError("--save requires a nonempty PNG file path")
      }
    }

    @MainActor
    mutating func run() async throws {
      do {
        let outcome = try ScreenshotCapture.live.execute(
          window: window, saveURL: save.map { URL(filePath: $0).standardizedFileURL })
        print(try outcome.render(json: json))
      } catch {
        if alertOnError { CaptureCommand.showAlert(String(describing: error)) }
        throw error
      }
    }

  }

  @MainActor
  static func showAlert(_ message: String, style: NSAlert.Style = .critical) {
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let alert = NSAlert()
    alert.messageText = "Capture not completed"
    alert.informativeText = message
    alert.alertStyle = style
    app.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
