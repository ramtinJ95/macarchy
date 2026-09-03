import Darwin
import Foundation

enum PiAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadSettings(URL)
  case controlUnavailable(URL)
  case cannotRefreshThemeLink(URL, code: Int32)
  case invalidVersion(String)
  case noLongerSelected
  case unsupportedVersion(String)
  case wrongThemeSelection(String)

  var description: String {
    switch self {
    case .cannotReadSettings(let url):
      "Cannot read Pi settings at \(url.path)"
    case .controlUnavailable(let url):
      "Pi is not executable at \(url.path)"
    case .cannotRefreshThemeLink(let url, let code):
      "Cannot refresh Pi theme link at \(url.path) (errno \(code))"
    case .invalidVersion(let value):
      "Pi returned an unparseable version: \(value)"
    case .noLongerSelected:
      "Pi is no longer enabled in the applied environment"
    case .unsupportedVersion(let value):
      "Pi \(value) is unsupported; version \(PiAdapter.minimumVersion) or newer is required"
    case .wrongThemeSelection(let expected):
      "Pi settings must select theme \"\(expected)\""
    }
  }
}

package struct PiAdapter: Sendable {
  package static let id = "pi"
  package static let outputPath = "generated/pi.json"
  static let rendererVersion = 4
  package static let themeName = "macarchy-current"
  package static let selectionKey = "theme"
  package static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/pi")
  package static let minimumVersion = "0.84.3"

  let root: URL
  let configurationDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner
  let selectionIsApplied: @Sendable () throws -> Bool
  let themeLinkRefreshIsAllowed: @Sendable () throws -> Bool

  package init(
    root: URL,
    configurationDirectoryURL: URL,
    executableURL: URL,
    controlIsAvailable: @escaping @Sendable () -> Bool,
    processRunner: ProcessRunner = ProcessRunner { _ in
      ProcessResult(terminationStatus: 0, output: PiAdapter.minimumVersion)
    },
    selectionIsApplied: @escaping @Sendable () throws -> Bool = { true },
    themeLinkRefreshIsAllowed: @escaping @Sendable () throws -> Bool = { true }
  ) {
    self.root = root
    self.configurationDirectoryURL = configurationDirectoryURL
    self.executableURL = executableURL
    self.controlIsAvailable = controlIsAvailable
    self.processRunner = processRunner
    self.selectionIsApplied = selectionIsApplied
    self.themeLinkRefreshIsAllowed = themeLinkRefreshIsAllowed
  }

  private var settingsURL: URL {
    configurationDirectoryURL.appending(path: "settings.json")
  }

  private var themeLink: CanonicalThemeLink {
    CanonicalThemeLink(
      url: configurationDirectoryURL.appending(path: "themes/\(Self.themeName).json"),
      destination: root.appending(path: "current/\(Self.outputPath)")
    )
  }

  func preflight() throws {
    try requireControl()
    _ = try supportedVersion()
    try validateManagedSeams()
  }

  private func integrationPreflight() throws {
    try requireControl()
    try validateManagedSeams()
  }

  private func requireControl() throws {
    guard controlIsAvailable() else {
      throw PiAdapterError.controlUnavailable(executableURL)
    }
  }

  private func validateManagedSeams() throws {
    guard try selectedTheme() == Self.themeName else {
      throw PiAdapterError.wrongThemeSelection(Self.themeName)
    }
    try themeLink.validate()
  }

  private var runtime: OrdinaryAdapterRuntime {
    OrdinaryAdapterRuntime(
      adapterID: Self.id,
      requirement: .required,
      preflight: preflight,
      isIntegrationDrift: Self.isIntegrationDrift
    )
  }

  func inspection(includeRuntimeChecks: Bool = false) -> AdapterInspection {
    OrdinaryAdapterRuntime(
      adapterID: Self.id,
      requirement: .required,
      preflight: includeRuntimeChecks ? preflight : integrationPreflight,
      isIntegrationDrift: Self.isIntegrationDrift
    ).inspection(
      readyMessage: "Pi watches the generated theme and repaints running sessions"
    )
  }

  func reconciliation() -> AdapterReconciliation {
    runtime.reconciliation {
      try ActivationLock(root: root).withLock {
        guard try selectionIsApplied() else { throw PiAdapterError.noLongerSelected }
        try preflight()
        guard try themeLinkRefreshIsAllowed() else {
          return AdapterOutcome(
            status: .restartRequired,
            message:
              "Pi's externally owned watched theme link was preserved; existing sessions need /reload or a new launch to use the active palette"
          )
        }
        try refreshThemeLink()
        return AdapterOutcome(
          status: .applied,
          message: "Running Pi sessions reloaded the active palette"
        )
      }
    }
  }

  static func render(package: ThemePackage) throws -> String {
    let semantic = package.semantic
    let ansi = package.terminal.ansi
    let userMessageBackground = mix(semantic.background, with: semantic.accent, amount: 0.18)
    let customMessageBackground = mix(semantic.background, with: semantic.info, amount: 0.14)
    let toolPendingBackground = mix(semantic.background, with: semantic.warning, amount: 0.10)
    let toolSuccessBackground = mix(semantic.background, with: semantic.success, amount: 0.12)
    let toolErrorBackground = mix(semantic.background, with: semantic.error, amount: 0.14)
    let conversationBackgrounds = [
      semantic.background.rawValue,
      userMessageBackground,
      customMessageBackground,
      toolPendingBackground,
      toolSuccessBackground,
      toolErrorBackground,
    ]
    let vars: [String: String] = [
      "accent": semantic.accent.rawValue,
      "background": semantic.background.rawValue,
      "border": semantic.border.rawValue,
      "customMessageBg": customMessageBackground,
      "dim": readableForeground(
        semantic.overlay,
        toward: semantic.text,
        against: conversationBackgrounds
      ),
      "error": semantic.error.rawValue,
      "muted": readableForeground(
        semantic.mutedText,
        toward: semantic.text,
        against: conversationBackgrounds
      ),
      "overlay": semantic.overlay.rawValue,
      "selection": semantic.selection.rawValue,
      "success": semantic.success.rawValue,
      "surface": semantic.surface.rawValue,
      "text": semantic.text.rawValue,
      "toolErrorBg": toolErrorBackground,
      "toolPendingBg": toolPendingBackground,
      "toolSuccessBg": toolSuccessBackground,
      "userMessageBg": userMessageBackground,
      "warning": semantic.warning.rawValue,
      "blue": ansi[4].rawValue,
      "cyan": ansi[6].rawValue,
    ]
    let colors: [String: String] = [
      "accent": "accent",
      "border": "border",
      "borderAccent": "accent",
      "borderMuted": "overlay",
      "success": "success",
      "error": "error",
      "warning": "warning",
      "muted": "muted",
      "dim": "dim",
      "text": "text",
      "thinkingText": "muted",
      "selectedBg": "selection",
      "userMessageBg": "userMessageBg",
      "userMessageText": "text",
      "customMessageBg": "customMessageBg",
      "customMessageText": "text",
      "customMessageLabel": "accent",
      "toolPendingBg": "toolPendingBg",
      "toolSuccessBg": "toolSuccessBg",
      "toolErrorBg": "toolErrorBg",
      "toolTitle": "accent",
      "toolOutput": "muted",
      "mdHeading": "accent",
      "mdLink": "blue",
      "mdLinkUrl": "muted",
      "mdCode": "warning",
      "mdCodeBlock": "text",
      "mdCodeBlockBorder": "border",
      "mdQuote": "muted",
      "mdQuoteBorder": "border",
      "mdHr": "border",
      "mdListBullet": "accent",
      "toolDiffAdded": "success",
      "toolDiffRemoved": "error",
      "toolDiffContext": "muted",
      "syntaxComment": "muted",
      "syntaxKeyword": "accent",
      "syntaxFunction": "blue",
      "syntaxVariable": "text",
      "syntaxString": "success",
      "syntaxNumber": "cyan",
      "syntaxType": "warning",
      "syntaxOperator": "cyan",
      "syntaxPunctuation": "muted",
      "thinkingOff": "border",
      "thinkingMinimal": "muted",
      "thinkingLow": "blue",
      "thinkingMedium": "cyan",
      "thinkingHigh": "accent",
      "thinkingXhigh": "warning",
      "thinkingMax": "error",
      "bashMode": "warning",
    ]
    let document: [String: Any] = [
      "$schema":
        "https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json",
      "name": themeName,
      "vars": vars,
      "colors": colors,
      "export": [
        "pageBg": "background",
        "cardBg": "userMessageBg",
        "infoBg": "toolPendingBg",
      ],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: document,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  private static func mix(_ start: SRGBColor, with end: SRGBColor, amount: Double) -> String {
    let startComponents = components(start.rawValue)
    let endComponents = components(end.rawValue)
    let mixed = zip(startComponents, endComponents).map { start, end in
      Int((Double(start) * (1 - amount) + Double(end) * amount).rounded())
    }
    return String(format: "#%02x%02x%02x", mixed[0], mixed[1], mixed[2])
  }

  private static func readableForeground(
    _ foreground: SRGBColor,
    toward text: SRGBColor,
    against backgrounds: [String]
  ) -> String {
    for percentage in 0...100 {
      let candidate = mix(foreground, with: text, amount: Double(percentage) / 100)
      if backgrounds.allSatisfy({ contrast(candidate, $0) >= 4.5 }) {
        return candidate
      }
    }
    return text.rawValue
  }

  private static func contrast(_ first: String, _ second: String) -> Double {
    let firstLuminance = relativeLuminance(first)
    let secondLuminance = relativeLuminance(second)
    return (max(firstLuminance, secondLuminance) + 0.05)
      / (min(firstLuminance, secondLuminance) + 0.05)
  }

  private static func relativeLuminance(_ color: String) -> Double {
    let linear = components(color).map { component in
      let value = Double(component) / 255
      return value <= 0.04045
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
  }

  private static func components(_ color: String) -> [Int] {
    let value = Int(color.dropFirst(), radix: 16)!
    return [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff]
  }

  private func selectedTheme() throws -> String? {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: settingsURL.resolvingSymlinksInPath()).data
    } catch {
      throw PiAdapterError.cannotReadSettings(settingsURL)
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["theme"] == nil || object["theme"] is String
    else {
      throw PiAdapterError.cannotReadSettings(settingsURL)
    }
    return object["theme"] as? String
  }

  package static func parseVersion(_ output: String) -> [Int]? {
    guard let token = output.split(whereSeparator: \Character.isWhitespace).last else {
      return nil
    }
    let value = token.first == "v" ? token.dropFirst() : token[...]
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    else { return nil }
    var parsed: [Int] = []
    for component in components {
      guard let number = Int(component) else { return nil }
      parsed.append(number)
    }
    return parsed
  }

  package func supportedVersion() throws -> String {
    let result = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: ["--version"], timeout: 2)
    )
    guard result.terminationStatus == 0, let version = Self.parseVersion(result.output) else {
      throw PiAdapterError.invalidVersion(result.output)
    }
    let minimum = Self.parseVersion(Self.minimumVersion)!
    guard version.lexicographicallyPrecedes(minimum) == false else {
      throw PiAdapterError.unsupportedVersion(result.output)
    }
    return result.output
  }

  private func refreshThemeLink() throws {
    let temporary = themeLink.url.deletingLastPathComponent().appending(
      path: ".\(Self.themeName)-\(UUID().uuidString).json")
    try FileManager.default.createSymbolicLink(
      atPath: temporary.path,
      withDestinationPath: themeLink.destination.path
    )
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard Darwin.rename(temporary.path, themeLink.url.path) == 0 else {
      throw PiAdapterError.cannotRefreshThemeLink(themeLink.url, code: errno)
    }
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case is CanonicalThemeLinkError, PiAdapterError.wrongThemeSelection:
      true
    default:
      false
    }
  }
}
