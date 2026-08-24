import Foundation

enum BatAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case configurationTooLarge(URL)
  case controlUnavailable(URL)
  case missingThemeDirective(String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read bat configuration at \(url.path)"
    case .configurationTooLarge(let url):
      "bat configuration at \(url.path) exceeds 1 MiB"
    case .controlUnavailable(let url):
      "bat is not executable at \(url.path)"
    case .missingThemeDirective(let directive):
      "bat configuration must contain '\(directive)'"
    }
  }
}

struct BatAdapter: Sendable {
  static let id = "bat"
  static let outputPath = "generated/bat.tmTheme"
  static let rendererVersion = 1
  static let themeName = "Macarchy Current"
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/bat")

  let root: URL
  let configurationDirectoryURL: URL
  let cacheDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner

  private var configurationURL: URL {
    configurationDirectoryURL.appending(path: "config")
  }

  private var themeDirective: String {
    "--theme=\"\(Self.themeName)\""
  }

  private var themeLink: CanonicalThemeLink {
    CanonicalThemeLink(
      url: configurationDirectoryURL.appending(path: "themes/\(Self.themeName).tmTheme"),
      destination: root.appending(path: "current/\(Self.outputPath)")
    )
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw BatAdapterError.controlUnavailable(executableURL)
    }
    try themeLink.validate()

    let configuration = try readConfiguration()
    guard Self.containsLine(themeDirective, in: configuration) else {
      throw BatAdapterError.missingThemeDirective(themeDirective)
    }
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message: "Fresh bat invocations select the Macarchy-managed theme"
      )
    } catch {
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        status: Self.isIntegrationDrift(error) ? .drifted : .failed,
        message: String(describing: error)
      )
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .required) {
      do {
        try preflight()
      } catch {
        return AdapterOutcome(
          status: Self.isIntegrationDrift(error) ? .drifted : .failed,
          message: String(describing: error)
        )
      }

      let result = try processRunner.run(
        ProcessRequest(
          executableURL: executableURL,
          arguments: ["cache", "--build"],
          timeout: 5,
          environmentOverrides: [
            "BAT_CACHE_PATH": cacheDirectoryURL.path,
            "BAT_CONFIG_DIR": configurationDirectoryURL.path,
          ]
        )
      )
      guard result.terminationStatus == 0 else {
        return AdapterOutcome(
          status: .failed,
          message: result.output.isEmpty ? "bat rejected the generated theme" : result.output
        )
      }
      return AdapterOutcome(
        status: .applied,
        message: "bat rebuilt its cache for the active palette"
      )
    }
  }

  static func render(package: ThemePackage) -> String {
    let semantic = package.semantic
    let ansi = package.terminal.ansi

    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>name</key>
        <string>\(themeName)</string>
        <key>semanticClass</key>
        <string>theme.\(package.appearance.rawValue).macarchy-current</string>
        <key>uuid</key>
        <string>7f833cb6-f61d-4da1-902c-018674a54d53</string>
        <key>settings</key>
        <array>
          <dict>
            <key>settings</key>
            <dict>
              <key>background</key><string>\(semantic.background.rawValue)</string>
              <key>foreground</key><string>\(semantic.text.rawValue)</string>
              <key>caret</key><string>\(package.terminal.cursor.rawValue)</string>
              <key>selection</key><string>\(semantic.selection.rawValue)80</string>
              <key>lineHighlight</key><string>\(semantic.surface.rawValue)</string>
              <key>invisibles</key><string>\(semantic.overlay.rawValue)</string>
            </dict>
          </dict>
          <dict>
            <key>name</key><string>Comments</string>
            <key>scope</key><string>comment</string>
            <key>settings</key>
            <dict>
              <key>foreground</key><string>\(semantic.mutedText.rawValue)</string>
              <key>fontStyle</key><string>italic</string>
            </dict>
          </dict>
      \(scope("Strings", "string", ansi[2]))
      \(scope("Numbers and constants", "constant.numeric, constant.language", ansi[6]))
      \(scope("Keywords", "keyword, storage.type, storage.modifier", semantic.accent))
      \(scope("Functions", "entity.name.function, support.function", ansi[4]))
      \(scope("Types", "entity.name.type, entity.name.class, support.type", semantic.info))
      \(scope("Variables", "variable, variable.other", semantic.text))
      \(scope("Parameters", "variable.parameter", semantic.warning))
      \(scope("Tags", "entity.name.tag", semantic.error))
      \(scope("Attributes", "entity.other.attribute-name", semantic.warning))
      \(scope("Invalid", "invalid, invalid.illegal", semantic.error))
        </array>
      </dict>
      </plist>

      """
  }

  private func readConfiguration() throws -> String {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: configurationURL).data
    } catch BoundedRegularFileError.tooLarge {
      throw BatAdapterError.configurationTooLarge(configurationURL)
    } catch {
      throw BatAdapterError.cannotReadConfiguration(configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw BatAdapterError.cannotReadConfiguration(configurationURL)
    }
    return configuration
  }

  private static func scope(
    _ name: String,
    _ selector: String,
    _ color: SRGBColor
  ) -> String {
    return """
          <dict>
            <key>name</key><string>\(name)</string>
            <key>scope</key><string>\(selector)</string>
            <key>settings</key>
            <dict>
              <key>foreground</key><string>\(color.rawValue)</string>
            </dict>
          </dict>
      """
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case is CanonicalThemeLinkError, BatAdapterError.missingThemeDirective:
      true
    default:
      false
    }
  }

  private static func containsLine(_ expected: String, in text: String) -> Bool {
    text.split(separator: "\n").contains { line in
      line.trimmingCharacters(in: .whitespaces) == expected
    }
  }
}
