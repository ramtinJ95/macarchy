import Foundation
import TOMLDecoder

enum HerdrAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case cannotReadDesiredTheme(URL)
  case controlUnavailable(URL)
  case invalidThemeConfiguration
  case automaticThemeSwitching
  case unsupportedTheme(String)
  case wrongThemeSelection(expected: String, actual: String?)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read Herdr configuration at \(url.path)"
    case .cannotReadDesiredTheme(let url):
      "Cannot read generated Herdr theme at \(url.path)"
    case .controlUnavailable(let url):
      "Herdr is not executable at \(url.path)"
    case .invalidThemeConfiguration:
      "Herdr configuration must contain one [theme] table and at most one quoted name key"
    case .automaticThemeSwitching:
      "Herdr theme.auto_switch must remain false while Macarchy owns theme.name"
    case .unsupportedTheme(let name):
      "Herdr 0.8 theme \"\(name)\" is not allowlisted"
    case .wrongThemeSelection(let expected, let actual):
      "Herdr theme is \(actual.map { "\"\($0)\"" } ?? "unset"); expected \"\(expected)\""
    }
  }
}

package struct HerdrAdapter: Sendable {
  static let id = "herdr"
  static let outputPath = "generated/herdr.txt"
  static let rendererVersion = 1
  static var liveExecutableURL: URL {
    preferredExternalOrHomebrewExecutableURL(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      externalRelativePath: ".local/bin/herdr",
      homebrewExecutableName: "herdr"
    )
  }

  private static let supportedThemes = Set([
    "catppuccin", "tokyo-night", "kanagawa",
  ])

  let root: URL
  let configurationURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner

  private var desiredThemeURL: URL {
    root.appending(path: "current/\(Self.outputPath)")
  }

  private var backupURL: URL {
    root.appending(path: "state/adapters/herdr-config.toml.backup")
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw HerdrAdapterError.controlUnavailable(executableURL)
    }
    try Self.validateConfiguration(try readConfiguration())
  }

  func preflight(package: ThemePackage) throws {
    try preflight()
    _ = try Self.mapping(for: package)
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      guard let desired = try currentDesiredTheme() else {
        return AdapterInspection(
          adapterID: Self.id,
          requirement: .required,
          message: "Herdr configuration is ready for a mapped built-in theme"
        )
      }
      let actual = try Self.parseConfiguration(try readConfiguration()).selection
      guard actual == desired else {
        throw HerdrAdapterError.wrongThemeSelection(expected: desired, actual: actual)
      }
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message: "Herdr uses the active mapped theme and supports live config reload"
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

      try ActivationLock(root: root).withLock {
        guard let desired = try currentDesiredTheme() else {
          throw HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
        }
        try writeTheme(desired)
      }

      let reload = try processRunner.run(
        ProcessRequest(
          executableURL: executableURL,
          arguments: ["server", "reload-config"],
          timeout: 2
        )
      )
      if reload.terminationStatus == 0 {
        return AdapterOutcome(status: .applied, message: "Herdr reloaded the active theme")
      }

      let status = try processRunner.run(
        ProcessRequest(executableURL: executableURL, arguments: ["status", "server"], timeout: 1)
      )
      if status.terminationStatus == 0,
        status.output.split(separator: "\n").contains("status: stopped")
      {
        return AdapterOutcome(
          status: .applied,
          message: "Herdr will use the active theme on next launch"
        )
      }
      return AdapterOutcome(
        status: .failed,
        message: reload.output.isEmpty ? "Herdr rejected its config reload" : reload.output
      )
    }
  }

  static func render(package: ThemePackage) throws -> String {
    try mapping(for: package) + "\n"
  }

  package static func validateConfiguration(_ configuration: String) throws {
    _ = try parseConfiguration(configuration)
  }

  private static func mapping(for package: ThemePackage) throws -> String {
    guard let mapping = package.mappings[id], supportedThemes.contains(mapping) else {
      throw HerdrAdapterError.unsupportedTheme(package.mappings[id] ?? "<missing>")
    }
    return mapping
  }

  private func currentDesiredTheme() throws -> String? {
    guard FileManager.default.fileExists(atPath: root.appending(path: "current").path) else {
      return nil
    }
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: desiredThemeURL.resolvingSymlinksInPath()).data
    } catch {
      throw HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
    }
    guard
      let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      Self.supportedThemes.contains(value)
    else {
      throw HerdrAdapterError.cannotReadDesiredTheme(desiredThemeURL)
    }
    return value
  }

  private func readConfiguration() throws -> String {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: configurationURL.resolvingSymlinksInPath()).data
    } catch {
      throw HerdrAdapterError.cannotReadConfiguration(configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw HerdrAdapterError.cannotReadConfiguration(configurationURL)
    }
    return configuration
  }

  private func writeTheme(_ desired: String) throws {
    let current = try readConfiguration()
    let parsed = try Self.parseConfiguration(current)
    guard parsed.selection != desired else { return }

    let updated = Self.replacingTheme(in: current, parsed: parsed, with: desired)
    guard try Self.parseConfiguration(updated).selection == desired else {
      throw HerdrAdapterError.invalidThemeConfiguration
    }
    let target = configurationURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: backupURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(current.utf8).write(to: backupURL, options: .atomic)
    try Data(updated.utf8).write(to: target, options: .atomic)
  }

  private struct ParsedConfiguration {
    let themeHeaderIndex: Int
    let nameIndex: Int?
    let selection: String?
  }

  private struct ConfigurationDocument: Decodable {
    let theme: ThemeConfiguration
  }

  private struct ThemeConfiguration: Decodable {
    let name: String?
    let autoSwitch: Bool?

    enum CodingKeys: String, CodingKey {
      case name
      case autoSwitch = "auto_switch"
    }
  }

  private static func parseConfiguration(_ configuration: String) throws -> ParsedConfiguration {
    let document: ConfigurationDocument
    do {
      document = try TOMLDecoder().decode(ConfigurationDocument.self, from: configuration)
    } catch {
      throw HerdrAdapterError.invalidThemeConfiguration
    }
    guard document.theme.autoSwitch != true else {
      throw HerdrAdapterError.automaticThemeSwitching
    }

    let lines = configuration.components(separatedBy: "\n")
    var themeHeaders = [Int]()
    var nameIndices = [Int]()
    var inTheme = false

    for (index, rawLine) in lines.enumerated() {
      let line =
        rawLine.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(
          in: .whitespaces) ?? ""
      if line.hasPrefix("[") {
        inTheme = line == "[theme]"
        if inTheme { themeHeaders.append(index) }
      } else if inTheme {
        let parts = line.split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.first == "name" {
          guard isEditableNameLine(rawLine) else {
            throw HerdrAdapterError.invalidThemeConfiguration
          }
          nameIndices.append(index)
        }
      }
    }
    guard
      themeHeaders.count == 1,
      nameIndices.count <= 1,
      document.theme.name == nil || nameIndices.count == 1
    else {
      throw HerdrAdapterError.invalidThemeConfiguration
    }
    return ParsedConfiguration(
      themeHeaderIndex: themeHeaders[0],
      nameIndex: nameIndices.first,
      selection: document.theme.name
    )
  }

  private static func isEditableNameLine(_ line: String) -> Bool {
    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts[0].trimmingCharacters(in: .whitespaces) == "name"
    else { return false }

    let value = parts[1].trimmingCharacters(in: .whitespaces)
    guard value.first == "\"" else { return false }
    let contentAndTail = value.dropFirst()
    guard let closingQuote = contentAndTail.firstIndex(of: "\"") else { return false }
    let content = contentAndTail[..<closingQuote]
    guard !content.contains("\\") else { return false }
    let tail = contentAndTail[contentAndTail.index(after: closingQuote)...]
      .trimmingCharacters(in: .whitespaces)
    return tail.isEmpty || tail.hasPrefix("#")
  }

  private static func replacingTheme(
    in configuration: String,
    parsed: ParsedConfiguration,
    with desired: String
  ) -> String {
    var lines = configuration.components(separatedBy: "\n")
    let replacement = "name = \"\(desired)\""
    if let nameIndex = parsed.nameIndex {
      let current = lines[nameIndex]
      let indentation = current.prefix { $0 == " " || $0 == "\t" }
      let comment = current.firstIndex(of: "#").map { " " + current[$0...] } ?? ""
      lines[nameIndex] = String(indentation) + replacement + comment
    } else {
      lines.insert(replacement, at: parsed.themeHeaderIndex + 1)
    }
    return lines.joined(separator: "\n")
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case HerdrAdapterError.automaticThemeSwitching,
      HerdrAdapterError.wrongThemeSelection:
      true
    default:
      false
    }
  }
}
