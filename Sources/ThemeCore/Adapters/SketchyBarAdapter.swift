import Foundation

enum SketchyBarAdapterError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL)
  case configurationTooLarge(URL)
  case missingInitImport(String)
  case missingPaletteImport(String)
  case missingReadyMarker(String)
  case controlUnavailable(URL)
  case queryRejected(String)
  case invalidQuery(String)

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read SketchyBar configuration at \(url.path)"
    case .configurationTooLarge(let url):
      "SketchyBar configuration at \(url.path) exceeds 1 MiB"
    case .missingInitImport(let importLine):
      "SketchyBar entry configuration must contain '\(importLine)'"
    case .missingPaletteImport(let importLine):
      "SketchyBar colors module must contain '\(importLine)'"
    case .missingReadyMarker(let declaration):
      "SketchyBar init module must contain '\(declaration)'"
    case .controlUnavailable(let url):
      "SketchyBar control is not executable at \(url.path)"
    case .queryRejected(let message):
      message
    case .invalidQuery(let cause):
      "Cannot read SketchyBar state: \(cause)"
    }
  }
}

struct SketchyBarAdapter: Sendable {
  static let id = "sketchybar"
  static let outputPath = "generated/sketchybar.lua"
  static let shellOutputPath = SketchyBarConfigurationComposer.paletteArtifactPath
  static let rendererVersion = 2
  static let liveExecutableURL = URL(filePath: "/opt/homebrew/bin/sketchybar")
  static let initImport = "require(\"init\")"
  static let readyItem = "macarchy.theme.ready"
  static let readyMarkerDeclaration =
    "sbar.add(\"item\", \"\(readyItem)\", { drawing = false })"

  let root: URL
  let configurationURL: URL
  let executableURL: URL
  let controlIsAvailable: @Sendable () -> Bool
  let processRunner: ProcessRunner
  let waitForSettle: @Sendable () async throws -> Void
  let waitForPresentation: @Sendable () async throws -> Void

  private var initURL: URL {
    configurationURL.deletingLastPathComponent().appending(path: "init.lua")
  }

  private var colorsURL: URL {
    configurationURL.deletingLastPathComponent().appending(path: "colors.lua")
  }

  private var paletteImport: String {
    Self.paletteImport(root: root)
  }

  init(
    root: URL,
    configurationURL: URL,
    executableURL: URL,
    controlIsAvailable: @escaping @Sendable () -> Bool,
    processRunner: ProcessRunner,
    waitForSettle: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(50))
    },
    waitForPresentation: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(250))
    }
  ) {
    self.root = root
    self.configurationURL = configurationURL
    self.executableURL = executableURL
    self.controlIsAvailable = controlIsAvailable
    self.processRunner = processRunner
    self.waitForSettle = waitForSettle
    self.waitForPresentation = waitForPresentation
  }

  func preflight() throws {
    guard controlIsAvailable() else {
      throw SketchyBarAdapterError.controlUnavailable(executableURL)
    }

    let entry = try readConfigurationText(configurationURL)
    guard containsExactLine(Self.initImport, in: entry) else {
      throw SketchyBarAdapterError.missingInitImport(Self.initImport)
    }

    let configuration = try readConfigurationText(initURL)
    guard containsExactLine(Self.readyMarkerDeclaration, in: configuration) else {
      throw SketchyBarAdapterError.missingReadyMarker(Self.readyMarkerDeclaration)
    }

    let colors = try readConfigurationText(colorsURL)
    guard containsExactLine(paletteImport, in: colors) else {
      throw SketchyBarAdapterError.missingPaletteImport(paletteImport)
    }
  }

  func inspection(includeRuntimeChecks: Bool = false) -> AdapterInspection {
    do {
      try preflight()
      guard includeRuntimeChecks else {
        return AdapterInspection(adapterID: Self.id, requirement: .required)
      }
      let expectedColor: String
      do {
        expectedColor = try activeBarColor()
      } catch ReconciliationStatusError.noActiveGeneration {
        return AdapterInspection(adapterID: Self.id, requirement: .required)
      }
      let state = try queryState(timeout: 0.2)
      guard matchesActivePalette(state, expectedColor: expectedColor) else {
        return AdapterInspection(
          adapterID: Self.id,
          requirement: .required,
          status: .drifted,
          message: "Running SketchyBar does not match the active palette"
        )
      }
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message: "Running SketchyBar matches the active palette"
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

      let reload = try processRunner.run(
        ProcessRequest(
          executableURL: executableURL,
          arguments: ["--reload", configurationURL.path],
          timeout: 2
        )
      )
      guard reload.terminationStatus == 0 else {
        return AdapterOutcome(
          status: .failed,
          message: reload.output.isEmpty ? "SketchyBar rejected its reload request" : reload.output
        )
      }

      let expectedColor = try activeBarColor()
      var lastTimeout: ProcessRunnerError?
      var observedState = false
      for attempt in 0..<11 {
        try Task.checkCancellation()
        do {
          let state = try queryState(timeout: 0.1)
          observedState = true
          if matchesActivePalette(state, expectedColor: expectedColor) {
            // SketchyBar publishes query state before the compositor presents the completed batch.
            try await waitForPresentation()
            return AdapterOutcome(status: .applied)
          }
        } catch let error as ProcessRunnerError {
          lastTimeout = error
        }
        if attempt < 10 { try await waitForSettle() }
      }
      if !observedState, let lastTimeout {
        return AdapterOutcome(
          status: .failed,
          message: "SketchyBar queries timed out through the bounded settle window: \(lastTimeout)"
        )
      }
      return AdapterOutcome(
        status: .drifted,
        message: "SketchyBar did not repaint within the bounded settle window"
      )
    }
  }

  static func render(package: ThemePackage) -> String {
    let colors = package.semantic
    let terminal = package.terminal.ansi
    // Existing bar thresholds use warning, orange, and error as three distinct levels.
    return """
      -- Generated by Macarchy. Do not edit.
      return {
        black = \(argb(colors.background)),
        white = \(argb(colors.text)),
        red = \(argb(colors.error)),
        green = \(argb(colors.success)),
        blue = \(argb(terminal[4])),
        yellow = \(argb(colors.warning)),
        orange = \(blendedARGB(colors.warning, colors.error)),
        magenta = \(argb(terminal[5])),
        grey = \(argb(terminal[8])),
        transparent = 0x00000000,

        bar = {
          bg = \(barColor(colors.background)),
          border = \(argb(colors.background)),
        },
        popup = {
          bg = \(argb(colors.background, alpha: 0xc0)),
          border = \(argb(terminal[8])),
        },
        bg1 = \(argb(colors.surface)),
        bg2 = \(argb(colors.overlay)),
      }

      """
  }

  static func renderShellPalette(package: ThemePackage) -> String {
    let colors = package.semantic
    let terminal = package.terminal.ansi
    return """
      # Generated by Macarchy. Do not edit.
      MACARCHY_BAR_COLOR=\(barColor(colors.background))
      MACARCHY_TEXT_COLOR=\(argb(colors.text))
      MACARCHY_ACCENT_COLOR=\(argb(terminal[4]))
      MACARCHY_MUTED_COLOR=\(argb(terminal[8]))

      """
  }

  static func paletteImport(root: URL) -> String {
    let path = root.appending(path: "current/\(outputPath)").path
    return "local colors = dofile(\(luaStringLiteral(path)))"
  }

  private func readConfiguration(_ url: URL) throws -> Data {
    do {
      return try BoundedRegularFile.read(at: url).data
    } catch BoundedRegularFileError.tooLarge {
      throw SketchyBarAdapterError.configurationTooLarge(url)
    } catch {
      throw SketchyBarAdapterError.cannotReadConfiguration(url)
    }
  }

  private func readConfigurationText(_ url: URL) throws -> String {
    let data = try readConfiguration(url)
    guard let text = String(data: data, encoding: .utf8) else {
      throw SketchyBarAdapterError.cannotReadConfiguration(url)
    }
    return text
  }

  private func queryState(timeout: TimeInterval) throws -> SketchyBarState {
    let result = try processRunner.run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: ["--query", "bar"],
        timeout: timeout
      )
    )
    guard result.terminationStatus == 0 else {
      throw SketchyBarAdapterError.queryRejected(
        result.output.isEmpty ? "SketchyBar rejected its bar query" : result.output
      )
    }
    do {
      return try JSONDecoder().decode(SketchyBarState.self, from: Data(result.output.utf8))
    } catch {
      throw SketchyBarAdapterError.invalidQuery(String(describing: error))
    }
  }

  private func matchesActivePalette(
    _ state: SketchyBarState,
    expectedColor: String
  ) -> Bool {
    state.drawing == "on"
      && state.color.lowercased() == expectedColor
      && state.items.contains(Self.readyItem)
  }

  private func activeBarColor() throws -> String {
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    let theme = try JSONDecoder().decode(
      NormalizedTheme.self,
      from: BoundedRegularFile.read(
        at: root.appending(
          path: "generations/\(manifest.generationID)/\(ThemeRenderer.themeOutputPath)"
        )
      ).data
    )
    guard
      theme.generationID == manifest.generationID,
      theme.themeID == manifest.themeID,
      theme.schemaVersion == manifest.themeSchemaVersion
    else {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "theme.json does not match the active manifest"
      )
    }
    return Self.barColor(theme.semantic.background)
  }

  private static func isIntegrationDrift(_ error: any Error) -> Bool {
    switch error {
    case SketchyBarAdapterError.missingInitImport,
      SketchyBarAdapterError.missingPaletteImport,
      SketchyBarAdapterError.missingReadyMarker:
      true
    default:
      false
    }
  }

  private static func argb(_ color: SRGBColor, alpha: UInt8 = 0xff) -> String {
    String(format: "0x%02x%@", alpha, String(color.rawValue.dropFirst()))
  }

  private static func barColor(_ background: SRGBColor) -> String {
    argb(background, alpha: 0xf0)
  }

  private static func blendedARGB(_ first: SRGBColor, _ second: SRGBColor) -> String {
    let firstRGB = rgb(first)
    let secondRGB = rgb(second)
    return String(
      format: "0xff%02x%02x%02x",
      (firstRGB.red + secondRGB.red) / 2,
      (firstRGB.green + secondRGB.green) / 2,
      (firstRGB.blue + secondRGB.blue) / 2
    )
  }

  private static func rgb(_ color: SRGBColor) -> (red: Int, green: Int, blue: Int) {
    let value = Int(color.rawValue.dropFirst(), radix: 16)!
    return ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
  }

  private static func luaStringLiteral(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
  }
}

private struct SketchyBarState: Decodable {
  let drawing: String
  let color: String
  let items: [String]
}
