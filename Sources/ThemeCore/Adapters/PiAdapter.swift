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

struct PiAdapter: Sendable {
  static let id = "pi"
  static let outputPath = "generated/pi.json"
  static let rendererVersion = 2
  static let themeName = "macarchy-current"
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
    let vars: [String: String] = [
      "accent": semantic.accent.rawValue,
      "background": semantic.background.rawValue,
      "border": semantic.border.rawValue,
      "error": semantic.error.rawValue,
      "muted": semantic.mutedText.rawValue,
      "overlay": semantic.overlay.rawValue,
      "selection": semantic.selection.rawValue,
      "success": semantic.success.rawValue,
      "surface": semantic.surface.rawValue,
      "text": semantic.text.rawValue,
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
      "userMessageBg": "surface",
      "userMessageText": "text",
      "customMessageBg": "surface",
      "customMessageText": "text",
      "customMessageLabel": "accent",
      "toolPendingBg": "surface",
      "toolSuccessBg": "surface",
      "toolErrorBg": "overlay",
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
        "cardBg": "surface",
        "infoBg": "selection",
      ],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: document,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self) + "\n"
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
