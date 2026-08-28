import Darwin
import Foundation

enum PiAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadSettings(URL)
  case controlUnavailable(URL)
  case cannotRefreshThemeLink(URL, code: Int32)
  case wrongThemeSelection(String)

  var description: String {
    switch self {
    case .cannotReadSettings(let url):
      "Cannot read Pi settings at \(url.path)"
    case .controlUnavailable(let url):
      "Pi is not executable at \(url.path)"
    case .cannotRefreshThemeLink(let url, let code):
      "Cannot refresh Pi theme link at \(url.path) (errno \(code))"
    case .wrongThemeSelection(let expected):
      "Pi settings must select theme \"\(expected)\""
    }
  }
}

package struct PiAdapter: Sendable {
  static let id = "pi"
  package static let outputPath = "generated/pi.json"
  static let rendererVersion = 3
  package static let themeName = "macarchy-current"
  package static let selectionKey = "theme"
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/pi")

  let root: URL
  let configurationDirectoryURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool

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
    guard controlIsAvailable() else {
      throw PiAdapterError.controlUnavailable(executableURL)
    }
    try themeLink.validate()
    guard try selectedTheme() == Self.themeName else {
      throw PiAdapterError.wrongThemeSelection(Self.themeName)
    }
  }

  func inspection() -> AdapterInspection {
    do {
      try preflight()
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message: "Pi watches the generated theme and repaints running sessions"
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
        try refreshThemeLink()
      }
      return AdapterOutcome(
        status: .applied,
        message: "Running Pi sessions reloaded the active palette"
      )
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
      "error": semantic.error.rawValue,
      "muted": readableMutedText(
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
      "dim": "overlay",
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

  private static func readableMutedText(
    _ muted: SRGBColor,
    toward text: SRGBColor,
    against backgrounds: [String]
  ) -> String {
    for percentage in 0...100 {
      let candidate = mix(muted, with: text, amount: Double(percentage) / 100)
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
