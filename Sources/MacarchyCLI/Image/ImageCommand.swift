import ArgumentParser
import Foundation
import UniformTypeIdentifiers

struct ImageCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "image",
    abstract: "Prepare a smaller, metadata-free copy of an image to share.",
    discussion: """
      The result is a separate sRGB file with none of the source's EXIF, GPS, TIFF, XMP or IPTC
      metadata and with orientation applied. It is never larger than the source, and the source is only read.
      """,
    subcommands: [Prepare.self, Choose.self])

  struct Prepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Prepare an image file or the clipboard image with a preset.",
      discussion: """
        share: JPEG at quality 0.8, longest edge up to 2048 px.
        small: JPEG at quality 0.7, longest edge up to 1280 px.
        png:   lossless PNG at the original size.
        The result goes beside the source as <name>-<preset>.<ext>, or to ~/Downloads as
        clipboard-<yyyyMMdd-HHmmss>-<preset>.<ext>. An existing file is never replaced; the name
        gains -2, -3 and so on, up to -99. The result is copied to the clipboard unless --no-copy
        is given.
        """)

    @Argument(help: "The image file to prepare.")
    var path: String?

    @Flag(help: "Prepare the image on the clipboard instead of a file.")
    var clipboard = false

    @Option(help: "The conversion preset.")
    var preset: ImagePreset

    @Option(help: "Save to this new file instead. Its folder must exist and it must not.")
    var output: String?

    @Flag(help: "Do not copy the result to the clipboard.")
    var noCopy = false

    @Flag(help: "Show the result in Finder.")
    var reveal = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    var source: ImageSource {
      guard let path else { return .clipboard }
      return .file(URL(filePath: path).standardizedFileURL)
    }

    mutating func validate() throws {
      guard (path == nil) == clipboard else {
        throw ValidationError("Give exactly one source: an image path or --clipboard.")
      }
      if path?.isEmpty == true { throw ValidationError("The image path is empty.") }
      if output?.isEmpty == true { throw ValidationError("--output requires a file path.") }
    }

    @MainActor
    mutating func run() async throws {
      let prepared = try ImagePreparation.live.prepare(
        source, preset: preset, output: output.map { URL(filePath: $0).standardizedFileURL },
        copy: !noCopy, reveal: reveal)
      print(try json ? prepared.renderJSON() : prepared.message(copied: !noCopy))
    }
  }

  struct Choose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Choose a preset and an image in native dialogs, then copy and reveal the result.",
      shouldDisplay: false)

    @Flag(help: .hidden)
    var alertOnError = false

    @MainActor
    mutating func run() async throws {
      do {
        let prepared = try ImagePreparation.live.choose(
          pick: {
            let presets = ImagePreset.allCases
            let sources = ImageSourceChoice.allCases
            guard
              let picked = showNativeChoice(
                title: "Prepare an image",
                message: "Saves a new copy without metadata beside the original, or in Downloads "
                  + "for a clipboard image, then copies it and shows it in Finder.",
                choices: presets.map(\.parameters.title), selected: 0,
                actions: sources.map(\.title))
            else { return nil }
            return (presets[picked.choice], sources[picked.action])
          },
          chooseFile: {
            showNativeOpenPanel(message: "Choose an image to prepare.", types: [.image])
          })
        print(prepared?.message(copied: true) ?? "Image preparation cancelled.")
      } catch {
        if alertOnError {
          showNativeAlert(title: "Prepare an image", message: String(describing: error))
        }
        throw error
      }
    }
  }
}
