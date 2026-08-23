import ArgumentParser
import Foundation
import ThemeCore

@main
struct Macarchy: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "macarchy",
    abstract: "A native, theme-driven macOS desktop shell.",
    version: "0.1.0-dev",
    subcommands: [Theme.self]
  )
}

struct Theme: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect or select themes.",
    subcommands: [List.self, Set.self]
  )
}

extension Theme {
  struct ThemeRootOptions: ParsableArguments {
    @Option(help: "Built-in theme package directory.")
    var themesRoot = "Themes"

    func repository() -> ThemeRepository {
      ThemeRepository(
        builtInRoot: URL(filePath: themesRoot, directoryHint: .isDirectory)
          .standardizedFileURL
      )
    }
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List valid available themes.")

    @OptionGroup var roots: ThemeRootOptions

    mutating func run() throws {
      for package in try roots.repository().packages() {
        print("\(package.id)\t\(package.appearance.rawValue)\t\(package.displayName)")
      }
    }
  }

  struct Set: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Validate a theme selection without activating it during M1."
    )

    @OptionGroup var roots: ThemeRootOptions

    @Argument(help: "Theme package identifier.")
    var themeID: String

    @Flag(help: "Validate and describe outputs without writing files.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      guard dryRun else {
        throw ValidationError("Canonical activation begins in M2; use --dry-run during M1.")
      }

      let package = try roots.repository().package(id: themeID)
      _ = try ThemeRenderer().render(package: package, generationID: "dry-run-\(package.id)")

      if json {
        let output = DryRunOutput(
          themeID: package.id,
          valid: true,
          wouldWrite: ["theme.json", "generated/kitty.conf"],
          wroteFiles: false
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        print(String(decoding: data, as: UTF8.self))
      } else {
        print("Theme \(package.id) is valid.")
        print("Would render:")
        print("- theme.json")
        print("- generated/kitty.conf")
        print("No files written.")
      }
    }
  }
}

private struct DryRunOutput: Encodable {
  let themeID: String
  let valid: Bool
  let wouldWrite: [String]
  let wroteFiles: Bool
}
