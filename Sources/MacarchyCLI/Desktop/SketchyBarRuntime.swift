import Foundation
import ThemeCore

private struct SketchyBarQueryNoResponse: Error, CustomStringConvertible {
  let arguments: [String]
  var description: String {
    "SketchyBar returned no response to \(arguments.joined(separator: " ")); its messaging endpoint may not be ready"
  }
}

enum SketchyBarCoreRuntimeStatus: String, Codable, Sendable {
  case converged
  case partial
  case drifted
  case failed
}

struct SketchyBarCoreRuntimeInspection: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let status: SketchyBarCoreRuntimeStatus
  let message: String
  let themeGenerationID: String?
  let barColor: String?
  let items: [String]
  let spaceIndices: [Int]
  let clockLabelPresent: Bool
  let volumeLevelPresent: Bool?
  let batteryStatePresent: Bool?
  let metricModules: [String]?
  let wifiStatePresent: Bool?
  let mediaStatePresent: Bool?
  let appleStatePresent: Bool?
  let toggleStatePresent: Bool?
  let nativeConfiguration: Bool?

  /// Items a valid managed bar may lack, beside the item they need. A present group is complete.
  private struct OptionalGroup: Sendable {
    let owner: String
    let items: [String]
  }

  /// Older generations lack the clock preview, later clock companions, the volume slider, the
  /// volume picker's extras and the Wi-Fi bracket. Group padding follows the layout, which the
  /// evidence does not record.
  private static let optionalGroups: [OptionalGroup] = {
    let clock = SketchyBarContract.clockItem
    var groups = [OptionalGroup(owner: clock, items: [SketchyBarContract.clockPreviewItem])]
    groups += SketchyBarClockCompanion.all.map { OptionalGroup(owner: clock, items: $0.items) }
    groups += [
      OptionalGroup(
        owner: SketchyBarContract.volumeItem, items: [SketchyBarContract.volumeSliderItem]),
      OptionalGroup(
        owner: SketchyBarContract.volumeItem,
        items: [
          SketchyBarContract.volumeIconItem, SketchyBarContract.volumeBracketItem,
          SketchyBarContract.volumePaddingItem,
        ]),
      OptionalGroup(
        owner: SketchyBarContract.wifiItem, items: [SketchyBarContract.wifiBracketItem]),
      OptionalGroup(
        owner: SketchyBarContract.batteryItem,
        items: [SketchyBarContract.groupPaddingItem(.battery)]),
    ]
    groups += [SketchyBarModule.cpu, .memory].map {
      OptionalGroup(
        owner: SketchyBarContract.metricItem($0),
        items: [SketchyBarContract.groupPaddingItem($0)])
    }
    return groups
  }()

  init(
    status: SketchyBarCoreRuntimeStatus,
    message: String,
    themeGenerationID: String? = nil,
    barColor: String? = nil,
    items: [String] = [],
    spaceIndices: [Int] = [],
    clockLabelPresent: Bool = false,
    volumeLevelPresent: Bool = false,
    batteryStatePresent: Bool = false,
    metricModules: [String] = [],
    wifiStatePresent: Bool = false,
    mediaStatePresent: Bool = false,
    appleStatePresent: Bool = false,
    toggleStatePresent: Bool = false,
    nativeConfiguration: Bool? = nil
  ) {
    schemaVersion = 1
    self.status = status
    self.message = message
    self.themeGenerationID = themeGenerationID
    self.barColor = barColor
    self.items = items
    self.spaceIndices = spaceIndices
    self.clockLabelPresent = clockLabelPresent
    self.volumeLevelPresent = volumeLevelPresent
    self.batteryStatePresent = batteryStatePresent
    self.metricModules = metricModules
    self.wifiStatePresent = wifiStatePresent
    self.mediaStatePresent = mediaStatePresent
    self.appleStatePresent = appleStatePresent
    self.toggleStatePresent = toggleStatePresent
    self.nativeConfiguration = nativeConfiguration
  }

  var isValidEvidence: Bool {
    guard
      schemaVersion == 1,
      status == .converged || status == .partial,
      themeGenerationID.map(isGenerationID) == true,
      barColor.map(Self.isARGBColor) == true,
      items == items.sorted(),
      Set(items).count == items.count,
      items.count <= 64,
      items.allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 128
          && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
      }),
      spaceIndices == spaceIndices.sorted(),
      Set(spaceIndices).count == spaceIndices.count,
      spaceIndices.allSatisfy({ (1..<UInt32.bitWidth).contains($0) })
    else { return false }
    if nativeConfiguration == true {
      return status == .partial && items.contains(SketchyBarContract.readyItem)
        && spaceIndices.isEmpty && !clockLabelPresent && volumeLevelPresent != true
        && batteryStatePresent != true && (metricModules ?? []).isEmpty
        && wifiStatePresent != true && mediaStatePresent != true
        && appleStatePresent != true && toggleStatePresent != true
    }
    let metrics = metricModules ?? []
    guard metrics == metrics.sorted(), Set(metrics).count == metrics.count,
      metrics.allSatisfy({ ["cpu", "memory"].contains($0) })
    else { return false }
    // A module's items, apart from its optional groups, are present exactly when its evidence is.
    let modules: [(module: SketchyBarModule, present: Bool)] = [
      (.clock, clockLabelPresent), (.volume, volumeLevelPresent ?? false),
      (.battery, batteryStatePresent ?? false), (.cpu, metrics.contains("cpu")),
      (.memory, metrics.contains("memory")), (.wifi, wifiStatePresent ?? false),
      (.media, mediaStatePresent ?? false), (.apple, appleStatePresent ?? false),
      (.toggle, toggleStatePresent ?? false),
    ]
    let optionalItems = Set(Self.optionalGroups.flatMap(\.items))
    var managedItems = [SketchyBarContract.readyItem]
    for (module, present) in modules {
      let required = SketchyBarContract.items(of: module).filter { !optionalItems.contains($0) }
      guard required.allSatisfy({ items.contains($0) == present }) else { return false }
      if present { managedItems += required }
    }
    for group in Self.optionalGroups where group.items.contains(where: items.contains) {
      guard items.contains(group.owner), group.items.allSatisfy(items.contains) else {
        return false
      }
      managedItems += group.items
    }
    if items.contains(SketchyBarContract.spacesUnavailableItem) {
      guard spaceIndices.isEmpty else { return false }
      managedItems.append(SketchyBarContract.spacesUnavailableItem)
    } else {
      managedItems += spaceIndices.map(SketchyBarContract.spaceItem)
    }
    managedItems.sort()
    if status == .converged { return items == managedItems }
    return Set(managedItems).isSubset(of: items)
      && items.filter { $0.hasPrefix("macarchy.") }.allSatisfy(managedItems.contains)
  }

  func agreesWithProviderRuntime(_ current: Self) -> Bool {
    status == current.status
      && (nativeConfiguration ?? false) == (current.nativeConfiguration ?? false)
      && items == current.items
      && spaceIndices == current.spaceIndices
      && clockLabelPresent == current.clockLabelPresent
      && volumeLevelPresent == current.volumeLevelPresent
      && (batteryStatePresent ?? false) == (current.batteryStatePresent ?? false)
      && (metricModules ?? []) == (current.metricModules ?? [])
      && (wifiStatePresent ?? false) == (current.wifiStatePresent ?? false)
      && (mediaStatePresent ?? false) == (current.mediaStatePresent ?? false)
      && (appleStatePresent ?? false) == (current.appleStatePresent ?? false)
      && (toggleStatePresent ?? false) == (current.toggleStatePresent ?? false)
  }

  private static func isARGBColor(_ value: String) -> Bool {
    value == value.lowercased() && value.count == 10 && value.hasPrefix("0x")
      && value.dropFirst(2).allSatisfy { $0.isHexDigit }
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case status, message
    case themeGenerationID = "theme_generation_id"
    case barColor = "bar_color"
    case items
    case spaceIndices = "space_indices"
    case clockLabelPresent = "clock_label_present"
    case volumeLevelPresent = "volume_level_present"
    case batteryStatePresent = "battery_state_present"
    case metricModules = "metric_modules"
    case wifiStatePresent = "wifi_state_present"
    case mediaStatePresent = "media_state_present"
    case appleStatePresent = "apple_state_present"
    case toggleStatePresent = "toggle_state_present"
    case nativeConfiguration = "native_configuration"
  }
}

struct SketchyBarCoreRuntimeController: Sendable {
  let inspect: @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection
  let settle: @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection
  let settleRestored: @Sendable (SketchyBarCoreRuntimeInspection) -> Bool

  static func live(stateRoot: URL) -> Self {
    let verifier = SketchyBarCoreRuntimeVerifier.live(stateRoot: stateRoot)
    return Self(
      inspect: verifier.inspect,
      settle: verifier.settle,
      settleRestored: verifier.settleRestored
    )
  }
}

struct SketchyBarCoreRuntimeVerifier: Sendable {
  static let controlURL = ExternalTool.sketchybar
  static let yabaiURL = ExternalTool.yabai

  let stateRoot: URL
  let processRunner: ProcessRunner
  let waitForSettle: @Sendable () -> Void
  let waitForPresentation: @Sendable () -> Void
  let hasExternalDisplay: @Sendable () throws -> Bool
  let toggleProcessMatches: @Sendable (ToggleHeartbeat) -> Bool
  let uptime: @Sendable () -> TimeInterval

  static func live(stateRoot: URL) -> Self {
    Self(
      stateRoot: stateRoot,
      processRunner: .live,
      waitForSettle: { Thread.sleep(forTimeInterval: 0.05) },
      waitForPresentation: { Thread.sleep(forTimeInterval: 0.25) }
    )
  }

  init(
    stateRoot: URL,
    processRunner: ProcessRunner,
    waitForSettle: @escaping @Sendable () -> Void,
    waitForPresentation: @escaping @Sendable () -> Void,
    hasExternalDisplay: @escaping @Sendable () throws -> Bool = SketchyBarCalendar
      .externalDisplayPresent,
    toggleProcessMatches: @escaping @Sendable (ToggleHeartbeat) -> Bool = SketchyBarToggle
      .matchesProcess,
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.stateRoot = stateRoot.standardizedFileURL
    self.processRunner = processRunner
    self.waitForSettle = waitForSettle
    self.hasExternalDisplay = hasExternalDisplay
    self.toggleProcessMatches = toggleProcessMatches
    self.uptime = uptime
    self.waitForPresentation = waitForPresentation
  }

  func inspect(_ composition: SketchyBarComposition) -> SketchyBarCoreRuntimeInspection {
    do {
      return try probe(composition)
    } catch {
      return failed(error)
    }
  }

  func settle(_ composition: SketchyBarComposition) -> SketchyBarCoreRuntimeInspection {
    var lastDrift: SketchyBarCoreRuntimeInspection?
    var lastTimeout: ProcessRunnerError?
    var lastFailure: (any Error)?
    let attemptCount = composition.hookURL == nil ? 41 : 11
    for attempt in 0..<attemptCount {
      do {
        let inspection = try probe(composition)
        if inspection.status == .converged || inspection.status == .partial {
          waitForPresentation()
          return inspection
        }
        lastDrift = inspection
      } catch let error as SketchyBarQueryNoResponse {
        // The v2.24 CLI exits zero when its Mach endpoint/reply is unavailable.
        // Retry absence, not malformed JSON, inside the existing settle budget.
        lastFailure = error
      } catch let error as ProcessRunnerError {
        if composition.hookURL != nil {
          lastFailure = error
        } else {
          guard
            case .timedOut(let executableURL, _) = error,
            executableURL == Self.controlURL
          else {
            return failed(error)
          }
          lastTimeout = error
        }
      } catch {
        guard composition.hookURL != nil else { return failed(error) }
        lastFailure = error
      }
      if attempt < attemptCount - 1 {
        // The hook runner exits within three seconds; do not roll back while it can still mutate.
        for _ in 0..<(composition.hookURL == nil ? 1 : 10) {
          waitForSettle()
        }
      }
    }
    if let lastFailure { return failed(lastFailure) }
    if let lastDrift { return lastDrift }
    return SketchyBarCoreRuntimeInspection(
      status: .failed,
      message:
        "SketchyBar queries timed out through the bounded settle window: \(String(describing: lastTimeout))"
    )
  }

  func settleRestored(_ expected: SketchyBarCoreRuntimeInspection) -> Bool {
    guard
      expected.isValidEvidence,
      let expectedColor = (try? activePalette())?.color
    else { return false }
    for attempt in 0..<41 {
      do {
        let bar: SketchyBarBarQuery = try query("bar")
        let items = try stableItems(bar.items, volumeEnabled: expected.volumeLevelPresent == true)
        let inventoryMatches =
          if expected.status == .partial {
            expected.items.filter { $0.hasPrefix("macarchy.") }.allSatisfy(items.contains)
              && items.filter { $0.hasPrefix("macarchy.") }.allSatisfy(expected.items.contains)
          } else {
            items == expected.items
          }
        var presentationMatches = inventoryMatches
        if expected.clockLabelPresent {
          let clock: SketchyBarItemQuery = try query(SketchyBarContract.clockItem)
          presentationMatches =
            presentationMatches && !clock.label.value.isEmpty && clock.label.value != "ERR"
          if expected.items.contains(SketchyBarContract.clockPreviewItem) {
            presentationMatches = try presentationMatches && validClockPreview()
          }
          for companion in SketchyBarClockCompanion.all
          where expected.items.contains(companion.item) {
            presentationMatches =
              try presentationMatches
              && validCompanion(companion, position: clock.geometry.position)
          }
        }
        if expected.toggleStatePresent == true {
          let toggle: SketchyBarItemQuery = try query(SketchyBarContract.toggleItem)
          presentationMatches =
            presentationMatches && validToggleHeartbeat(ToggleHeartbeat.parse(toggle.label.value))
        }
        if expected.appleStatePresent == true {
          let apple: SketchyBarItemQuery = try query(SketchyBarContract.appleItem)
          presentationMatches =
            presentationMatches && apple.label.drawing == "off" && apple.label.value.isEmpty
        }
        if expected.mediaStatePresent == true {
          let media: SketchyBarItemQuery = try query(SketchyBarContract.mediaItem)
          presentationMatches = presentationMatches && Self.validMediaIdentity(media.label.value)
        }
        if expected.volumeLevelPresent == true {
          let volume: SketchyBarItemQuery = try query(SketchyBarContract.volumeItem)
          presentationMatches = presentationMatches && !volume.label.value.isEmpty
          if expected.items.contains(SketchyBarContract.volumeIconItem) {
            let icon: SketchyBarItemQuery = try query(SketchyBarContract.volumeIconItem)
            presentationMatches = presentationMatches && Self.isVolumeIcon(icon.label.value)
          }
          if expected.items.contains(SketchyBarContract.volumeSliderItem) {
            let slider: SketchyBarItemQuery = try query(SketchyBarContract.volumeSliderItem)
            presentationMatches =
              presentationMatches && Self.isSliderLevel(slider.slider?.percentage)
          }
        }
        if expected.batteryStatePresent == true {
          let battery: SketchyBarItemQuery = try query(SketchyBarContract.batteryItem)
          let remaining: SketchyBarItemQuery = try query(SketchyBarContract.batteryRemainingItem)
          presentationMatches =
            presentationMatches && Self.isBatteryLabel(battery.label.value)
            && Self.isBatteryEstimate(remaining.label.value)
        }
        for metric in expected.metricModules ?? [] {
          let item: SketchyBarItemQuery = try query("macarchy.\(metric)")
          presentationMatches =
            presentationMatches && Self.isMetricLabel(item.label.value, metric: metric)
        }
        if expected.wifiStatePresent == true {
          for suffix in ["up", "down", "ssid"] {
            let item: SketchyBarItemQuery = try query("macarchy.wifi.\(suffix)")
            presentationMatches =
              presentationMatches
              && (suffix == "ssid"
                ? Self.isWiFiSSIDLabel(item.label.value) : Self.isWiFiRate(item.label.value))
          }
        }
        if bar.drawing == "on", bar.color.lowercased() == expectedColor,
          presentationMatches
        {
          waitForPresentation()
          return true
        }
      } catch {
        // Retry only inside the same bounded settle window used for normal reloads.
      }
      if attempt < 40 { waitForSettle() }
    }
    return false
  }

  private func probeNative(palette: (generationID: String, color: String)) throws
    -> SketchyBarCoreRuntimeInspection
  {
    let bar: SketchyBarBarQuery = try query("bar")
    let ready: SketchyBarItemQuery = try query(SketchyBarContract.readyItem)
    guard bar.drawing == "on", bar.color.lowercased() == palette.color, ready.isReadyMarker
    else {
      return drifted(
        "personal bar configuration is incomplete or its theme integration drifted",
        palette: palette, items: bar.items.sorted(), spaceIndices: [])
    }
    let final: SketchyBarBarQuery = try query("bar")
    guard final.items.sorted() == bar.items.sorted(), final.drawing == bar.drawing,
      final.color == bar.color
    else {
      return drifted(
        "personal bar changed during verification",
        palette: palette, items: final.items.sorted(), spaceIndices: [])
    }
    let evidence = SketchyBarCoreRuntimeInspection(
      status: .partial,
      message:
        "personal configuration completed; canonical bar color and readiness verified; personal layout and item behavior are not fully inspectable",
      themeGenerationID: palette.generationID, barColor: palette.color,
      items: bar.items.sorted(), nativeConfiguration: true)
    guard evidence.isValidEvidence else {
      return drifted(
        "personal bar inventory exceeds supported evidence bounds",
        palette: palette, items: bar.items.sorted(), spaceIndices: [])
    }
    return evidence
  }

  private func probe(
    _ composition: SketchyBarComposition
  ) throws -> SketchyBarCoreRuntimeInspection {
    let palette = try activePalette()
    if composition.nativeConfiguration {
      return try probeNative(palette: palette)
    }
    let spaceIndices = try expectedSpaceIndices(composition.spaceModule)
    let expectedItems = expectedItemNames(
      layout: composition.layout,
      spaceModule: composition.spaceModule,
      spaceIndices: spaceIndices
    )
    let bar: SketchyBarBarQuery = try query("bar")
    let items = try stableItems(
      bar.items, volumeEnabled: composition.layout.position(of: .volume) != nil)
    var clockLabelPresent = false
    var volumeLevelPresent = false
    func drift(
      _ message: String, items driftItems: [String]? = nil, spaceIndices driftSpaces: [Int]? = nil
    ) -> SketchyBarCoreRuntimeInspection {
      drifted(
        message, palette: palette, items: driftItems ?? items,
        spaceIndices: driftSpaces ?? spaceIndices, clockLabelPresent: clockLabelPresent,
        volumeLevelPresent: volumeLevelPresent)
    }
    let inventoryMatches =
      if composition.hookURL == nil {
        items == expectedItems
      } else {
        Set(items).count == items.count
          && expectedItems.allSatisfy(items.contains)
          && items.filter { $0.hasPrefix("macarchy.") }.allSatisfy(expectedItems.contains)
      }
    guard
      bar.drawing == "on",
      bar.color.lowercased() == palette.color,
      bar.position == composition.settings.position,
      bar.height == composition.settings.height,
      bar.margin == composition.settings.margin,
      bar.cornerRadius == composition.settings.cornerRadius,
      bar.topmost == "on",
      composition.layout.position(of: .toggle) != nil
        ? ["on", "off"].contains(bar.hidden) && (-50...0).contains(bar.yOffset)
        : bar.hidden == "off" && bar.yOffset == 0,
      inventoryMatches
    else {
      return drift("running SketchyBar bar state does not match the selected managed generation")
    }

    if let clockPosition = composition.layout.position(of: .clock) {
      let actualPosition =
        composition.automaticClock
        ? (try hasExternalDisplay() ? "center" : "right") : clockPosition.rawValue
      let clock: SketchyBarItemQuery = try query(SketchyBarContract.clockItem)
      let expectedClockScript = pluginPath(SketchyBarContract.clockPlugin)
      let clockLabel = clock.label.value
      clockLabelPresent = !clockLabel.isEmpty && clockLabel != "ERR"
      let events: [String: SketchyBarEventQuery] = try query("events")
      let bits = ["mouse.clicked", "display_change", "system_woke"].compactMap { events[$0]?.bit }
      let mask = bits.reduce(0, |)
      guard
        clock.name == SketchyBarContract.clockItem,
        clock.type == "item",
        clock.geometry.drawing == "on",
        clock.geometry.position == actualPosition,
        clock.label.drawing == "on",
        clockLabelPresent,
        clock.scripting.script == expectedClockScript,
        clock.scripting.updateFrequency == 30,
        clock.scripting.updates == "on",
        bits.count == 3, clock.scripting.updateMask.map({ $0 & mask == mask }) == true,
        try validClockPreview(),
        try SketchyBarClockCompanion.all.allSatisfy({
          try validCompanion($0, position: actualPosition)
        })
      else {
        return drift(
          "running SketchyBar clock or its companions are incomplete: "
            + "name=\(clock.name), type=\(clock.type), drawing=\(clock.geometry.drawing), "
            + "position=\(clock.geometry.position), label_drawing=\(clock.label.drawing), "
            + "label_present=\(clockLabelPresent), script=\(clock.scripting.script), "
            + "update_freq=\(clock.scripting.updateFrequency), "
            + "updates=\(clock.scripting.updates ?? "missing")")
      }
    }

    let ready: SketchyBarItemQuery = try query(SketchyBarContract.readyItem)
    guard ready.isReadyMarker else {
      return drift("running SketchyBar ready marker is missing or visible")
    }

    if composition.spaceModule == .disabledWithoutDesktop {
      let expectedPosition = composition.layout.position(of: .spaces)!
      let fallback: SketchyBarItemQuery = try query(SketchyBarContract.spacesUnavailableItem)
      guard
        fallback.name == SketchyBarContract.spacesUnavailableItem,
        fallback.type == "item",
        fallback.geometry.drawing == "on",
        fallback.geometry.position == expectedPosition.rawValue,
        fallback.label.drawing == "on",
        fallback.label.value == "Spaces unavailable"
      else {
        return drift("running SketchyBar does not expose the disabled desktop Space state")
      }
    } else if composition.spaceModule == .dynamicYabai {
      let expectedPosition = composition.layout.position(of: .spaces)!
      for index in spaceIndices {
        let name = SketchyBarContract.spaceItem(index)
        let space: SketchyBarItemQuery
        do {
          space = try query(name)
        } catch SketchyBarDesktopError.lifecycle(let message) {
          let missing = "[!] Query: Invalid query, or item '\(name)' not found"
          guard message.trimmingCharacters(in: .whitespacesAndNewlines) == missing else {
            throw SketchyBarDesktopError.lifecycle(message)
          }
          return drift("running SketchyBar Space inventory changed during verification")
        }
        let expectedAssociation = UInt32(1) << UInt32(index)
        let expectedClickScript = "\(Self.yabaiURL.path) -m space --focus \(index)"
        guard
          space.name == name,
          space.type == "space",
          space.geometry.drawing == "on",
          space.geometry.position == expectedPosition.rawValue,
          space.geometry.associatedSpaceMask == expectedAssociation,
          space.scripting.clickScript == expectedClickScript
        else {
          return drift("running SketchyBar Spaces are incomplete or misplaced")
        }
      }
      let finalSpaceIndices = try expectedSpaceIndices(.dynamicYabai)
      guard finalSpaceIndices == spaceIndices else {
        return drift(
          "running SketchyBar Space inventory changed during verification",
          spaceIndices: finalSpaceIndices)
      }
    }

    if let volumePosition = composition.layout.position(of: .volume) {
      let volume: SketchyBarItemQuery = try query(SketchyBarContract.volumeItem)
      let events: [String: SketchyBarEventQuery] = try query("events")
      let expectedVolumeScript = pluginPath("volume")
      let volumeEventBit = events["volume_change"]?.bit
      let wakeEventBit = events["system_woke"]?.bit
      let interactionBits = ["mouse.clicked", "mouse.scrolled", "mouse.exited.global"].compactMap {
        events[$0]?.bit
      }
      let requiredEventMask = interactionBits.reduce((volumeEventBit ?? 0) | (wakeEventBit ?? 0), |)
      let slider: SketchyBarItemQuery = try query(SketchyBarContract.volumeSliderItem)
      let icon: SketchyBarItemQuery = try query(SketchyBarContract.volumeIconItem)
      let padding: SketchyBarItemQuery = try query(SketchyBarContract.volumePaddingItem)
      let parent: SketchyBarAudioPicker.Parent = try query(SketchyBarAudioPicker.popupOwner)
      volumeLevelPresent = Self.isVolumeLabel(volume.label.value)
      guard
        parent.owns(rows: bar.items.filter { $0.hasPrefix(SketchyBarAudioPicker.prefix) }),
        parent.geometry.position == volumePosition.rawValue, parent.geometry.drawing == "on",
        parent.label.drawing == "off", parent.scripting.hasNoScript,
        parent.scripting.updateFrequency == 0,
        icon.name == SketchyBarContract.volumeIconItem, icon.type == "item",
        icon.geometry.position == volumePosition.rawValue,
        icon.geometry.drawing == "on", icon.label.drawing == "on",
        Self.isVolumeIcon(icon.label.value),
        icon.scripting.script == expectedVolumeScript, icon.scripting.updateFrequency == 0,
        icon.scripting.updateMask.map({
          $0 & ((events["mouse.clicked"]?.bit ?? 0) | (events["mouse.scrolled"]?.bit ?? 0))
            == ((events["mouse.clicked"]?.bit ?? 0) | (events["mouse.scrolled"]?.bit ?? 0))
        }) == true,
        padding.name == SketchyBarContract.volumePaddingItem, padding.type == "item",
        padding.geometry.position == volumePosition.rawValue,
        padding.geometry.drawing == "on", padding.geometry.width == 8,
        padding.label.drawing == "off",
        padding.scripting.hasNoScript, padding.scripting.updateFrequency == 0,
        interactionBits.count == 3, interactionBits.allSatisfy({ $0 > 0 }),
        slider.name == SketchyBarContract.volumeSliderItem, slider.type == "slider",
        slider.geometry.drawing == "on", slider.geometry.position == "popup",
        slider.label.drawing == "off", slider.scripting.hasNoScript,
        slider.scripting.clickScript
          == SketchyBarConfigurationComposer.pluginClickScript(
            sender: "macarchy.slider", pluginPath: expectedVolumeScript),
        slider.scripting.updateFrequency == 0, Self.isSliderLevel(slider.slider?.percentage),
        volumeEventBit.map({ $0 > 0 }) == true,
        wakeEventBit.map({ $0 > 0 }) == true,
        volume.name == SketchyBarContract.volumeItem,
        volume.type == "item",
        volume.geometry.drawing == "on",
        volume.geometry.position == volumePosition.rawValue,
        volume.label.drawing == "on",
        volumeLevelPresent,
        volume.scripting.script == expectedVolumeScript,
        volume.scripting.updateFrequency == 0,
        volume.scripting.updateMask.map({ $0 & requiredEventMask == requiredEventMask }) == true
      else {
        return drift("running SketchyBar volume module is incomplete, misplaced, or unsubscribed")
      }
    }

    var batteryStatePresent = false
    if let position = composition.layout.position(of: .battery) {
      let battery: SketchyBarItemQuery = try query(SketchyBarContract.batteryItem)
      let remaining: SketchyBarItemQuery = try query(SketchyBarContract.batteryRemainingItem)
      let events: [String: SketchyBarEventQuery] = try query("events")
      let eventBits = [
        "power_source_change", "system_woke", "mouse.clicked", "mouse.exited.global",
      ]
      .compactMap { events[$0]?.bit }.filter { $0 > 0 }
      let mask = eventBits.reduce(UInt64(0), |)
      batteryStatePresent =
        Self.isBatteryLabel(battery.label.value)
        && Self.isBatteryEstimate(remaining.label.value)
      guard eventBits.count == 4,
        battery.name == SketchyBarContract.batteryItem, battery.type == "item",
        battery.geometry.drawing == "on", battery.geometry.position == position.rawValue,
        battery.label.drawing == "on", batteryStatePresent,
        battery.scripting.script
          == pluginPath("battery"),
        battery.scripting.updateFrequency == 180,
        battery.scripting.updateMask.map({ $0 & mask == mask }) == true,
        remaining.name == SketchyBarContract.batteryRemainingItem, remaining.type == "item",
        remaining.label.drawing == "on"
      else {
        return drift("running SketchyBar battery state, popup, or subscriptions are incomplete")
      }
    }

    var metricModules: [String] = []
    for module in [SketchyBarModule.cpu, .memory] {
      guard let position = composition.layout.position(of: module) else { continue }
      let name = SketchyBarContract.metricItem(module)
      let metric: SketchyBarItemQuery = try query(name)
      guard metric.name == name, metric.type == "item",
        metric.geometry.drawing == "on", metric.geometry.position == position.rawValue,
        metric.label.drawing == "on",
        Self.isMetricLabel(metric.label.value, metric: module.rawValue),
        metric.scripting.script
          == pluginPath(module.rawValue),
        metric.scripting.updateFrequency == (module == .cpu ? 2 : 5),
        metric.scripting.clickScript == "/usr/bin/open -a \"Activity Monitor\""
      else {
        return drift("running SketchyBar \(module.rawValue) metric is incomplete or misplaced")
      }
      metricModules.append(module.rawValue)
    }

    for module in [SketchyBarModule.battery, .cpu, .memory]
    where composition.layout.hasTrailingGroupPadding(module) {
      let name = SketchyBarContract.groupPaddingItem(module)
      let padding: SketchyBarItemQuery = try query(name)
      guard padding.name == name, padding.type == "item", padding.geometry.drawing == "on",
        padding.geometry.position == composition.layout.position(of: module)?.rawValue,
        padding.geometry.width == 8, padding.label.drawing == "off",
        padding.scripting.hasNoScript, padding.scripting.updateFrequency == 0
      else {
        return drift("running SketchyBar widget group spacing is incomplete")
      }
    }

    var wifiStatePresent = false
    if let position = composition.layout.position(of: .wifi) {
      let group: SketchyBarItemQuery = try query(SketchyBarContract.wifiBracketItem)
      guard group.name == SketchyBarContract.wifiBracketItem, group.type == "bracket",
        group.geometry.drawing == "on",
        group.geometry.position == position.rawValue, group.label.drawing == "off",
        group.bracket?.sorted() == ["macarchy.wifi", "macarchy.wifi.down", "macarchy.wifi.up"],
        group.popup?.items.sorted() == [
          "macarchy.wifi.hostname", "macarchy.wifi.ip", "macarchy.wifi.mask",
          "macarchy.wifi.router", "macarchy.wifi.ssid",
        ],
        group.scripting.hasNoScript, group.scripting.updateFrequency == 0
      else {
        return drift("running SketchyBar Wi-Fi popup group is incomplete")
      }
      let events: [String: SketchyBarEventQuery] = try query("events")
      for name in SketchyBarContract.wifiItems {
        let item: SketchyBarItemQuery = try query(name)
        let main = name == SketchyBarContract.wifiItem
        let rate = name == "macarchy.wifi.up" || name == "macarchy.wifi.down"
        let required =
          main ? ["mouse.clicked", "mouse.exited.global", "system_woke"] : ["mouse.clicked"]
        let bits = required.compactMap { events[$0]?.bit }.filter { $0 > 0 }
        let mask = bits.reduce(UInt64(0), |)
        guard bits.count == required.count, item.name == name, item.type == "item",
          item.geometry.position == (main || rate ? position.rawValue : "popup"),
          (!main && !rate) || item.geometry.drawing == "on",
          item.label.drawing == (main ? "off" : "on"),
          main
            || (rate
              ? Self.isWiFiRate(item.label.value)
              : name == "macarchy.wifi.ssid"
                ? Self.isWiFiSSIDLabel(item.label.value) : !item.label.value.isEmpty),
          item.scripting.script
            == pluginPath("wifi"),
          item.scripting.updateFrequency == (main ? 2 : 0),
          item.scripting.updateMask.map({ $0 & mask == mask }) == true
        else {
          return drift("running SketchyBar Wi-Fi state, popup, or subscriptions are incomplete")
        }
      }
      wifiStatePresent = true
    }

    var toggleStatePresent = false
    if let position = composition.layout.position(of: .toggle) {
      let toggle: SketchyBarItemQuery = try query(SketchyBarContract.toggleItem)
      let events: [String: SketchyBarEventQuery] = try query("events")
      let bits = ["display_change", "system_woke"].compactMap { events[$0]?.bit }
      let mask = bits.reduce(UInt64(0), |)
      let heartbeat = ToggleHeartbeat.parse(toggle.label.value)
      guard toggle.name == SketchyBarContract.toggleItem, toggle.type == "item",
        toggle.geometry.drawing == "off",
        toggle.geometry.position == position.rawValue, toggle.label.drawing == "off",
        let heartbeat,
        toggle.scripting.script
          == SketchyBarConfigurationComposer.toggleScript(
            pluginPath: pluginPath("toggle"),
            token: heartbeat.token),
        toggle.scripting.updateFrequency == 1, toggle.scripting.updates == "on",
        bits.count == 2, toggle.scripting.updateMask.map({ $0 & mask == mask }) == true,
        validToggleHeartbeat(heartbeat)
      else {
        return drift(
          "running SketchyBar native-menu toggle is not ready, failed, stale, or has lost process ownership"
        )
      }
      toggleStatePresent = true
    }
    var appleStatePresent = false
    if let position = composition.layout.position(of: .apple) {
      let apple: SketchyBarItemQuery = try query(SketchyBarContract.appleItem)
      let events: [String: SketchyBarEventQuery] = try query("events")
      guard apple.name == SketchyBarContract.appleItem, apple.type == "item",
        apple.geometry.drawing == "on",
        apple.geometry.position == position.rawValue, apple.label.drawing == "off",
        apple.label.value.isEmpty,
        apple.scripting.script
          == pluginPath("apple"),
        apple.scripting.updateFrequency == 0,
        let bit = events["mouse.clicked"]?.bit,
        apple.scripting.updateMask.map({ $0 & bit == bit }) == true
      else {
        return drift(
          "running SketchyBar Apple-menu helper failed or its script/subscription is incomplete")
      }
      appleStatePresent = true
    }
    var mediaStatePresent = false
    if let position = composition.layout.position(of: .media) {
      let script = pluginPath("media")
      let events: [String: SketchyBarEventQuery] = try query("events")
      var observed: [String: SketchyBarItemQuery] = [:]
      for name in SketchyBarContract.mediaItems {
        let item: SketchyBarItemQuery = try query(name)
        observed[name] = item
        let main = name == SketchyBarContract.mediaItem
        let detail = ["macarchy.media.artist", "macarchy.media.title"].contains(name)
        let preview = name == "macarchy.media.preview"
        let required =
          main
          ? [
            "mouse.entered", "mouse.exited", "mouse.clicked", "mouse.exited.global", "system_woke",
          ]
          : detail ? ["mouse.entered", "mouse.exited", "mouse.exited.global"] : []
        let bits = required.compactMap { events[$0]?.bit }
        let mask = bits.reduce(0, |)
        guard item.name == name, item.type == "item",
          item.geometry.position
            == (preview ? "right" : (main || detail ? position.rawValue : "popup")),
          item.scripting.updateFrequency == (main ? 2 : 0),
          main || detail
            ? item.scripting.script == script : item.scripting.hasNoScript,
          main || detail
            ? bits.count == required.count
              && item.scripting.updateMask.map({ $0 & mask == mask }) == true : true,
          main || detail || preview
            ? true
            : item.scripting.clickScript
              == SketchyBarConfigurationComposer.pluginClickScript(sender: name, pluginPath: script),
          preview
            ? item.geometry.drawing == "off"
              && (item.label.value == "hover"
                || Self.isCanonicalUInt64(item.label.value))
            : true
        else {
          return drift(
            "running SketchyBar media scripts, controls, preview, or subscriptions are incomplete")
        }
      }
      let main = observed[SketchyBarContract.mediaItem]!
      let playing = main.label.value != "inactive"
      guard Self.validMediaIdentity(main.label.value), main.label.drawing == "off",
        [SketchyBarContract.mediaItem, "macarchy.media.artist", "macarchy.media.title"].allSatisfy({
          observed[$0]?.geometry.drawing == (playing ? "on" : "off")
        }),
        !playing || observed["macarchy.media.title"]?.label.value.isEmpty == false
      else {
        return drift("running SketchyBar media presentation is incomplete or failed")
      }
      mediaStatePresent = true
    }

    let finalBar: SketchyBarBarQuery = try query("bar")
    guard finalBar.items.sorted() == bar.items.sorted() else {
      return drift(
        "running SketchyBar item inventory changed during verification",
        items: finalBar.items.sorted())
    }

    let partial = composition.hookURL != nil
    return SketchyBarCoreRuntimeInspection(
      status: partial ? .partial : .converged,
      message: partial
        ? "managed SketchyBar core is verified; the trusted hook may add behavior Macarchy cannot inspect"
        : "running SketchyBar matches the selected provider and canonical theme generations",
      themeGenerationID: palette.generationID,
      barColor: palette.color,
      items: items,
      spaceIndices: spaceIndices,
      clockLabelPresent: clockLabelPresent,
      volumeLevelPresent: volumeLevelPresent,
      batteryStatePresent: batteryStatePresent,
      metricModules: metricModules,
      wifiStatePresent: wifiStatePresent,
      mediaStatePresent: mediaStatePresent,
      appleStatePresent: appleStatePresent,
      toggleStatePresent: toggleStatePresent
    )
  }

  private func validToggleHeartbeat(_ heartbeat: ToggleHeartbeat?) -> Bool {
    guard let heartbeat else { return false }
    return heartbeat.fresh(at: uptime()) && toggleProcessMatches(heartbeat)
  }

  private static func validMediaIdentity(_ value: String) -> Bool {
    value == "inactive" || isSHA256Hex(value)
  }

  private func validCompanion(_ companion: SketchyBarClockCompanion, position: String) throws
    -> Bool
  {
    let item: SketchyBarItemQuery = try query(companion.item)
    let detail: SketchyBarItemQuery = try query(companion.detailItem)
    let events: [String: SketchyBarEventQuery] = try query("events")
    let bits = companion.events.compactMap { events[$0]?.bit }
    let mask = bits.reduce(0, |)
    // Visibility and the state each companion shows are volatile UI state, not readiness.
    return item.name == companion.item && item.type == "item"
      && ["on", "off"].contains(item.geometry.drawing) && item.geometry.position == position
      && item.label.drawing == "off" && item.scripting.updates == "on"
      && item.scripting.updateFrequency == companion.updateFrequency
      && item.scripting.script == pluginPath(companion.plugin)
      && bits.count == companion.events.count
      && item.scripting.updateMask.map { $0 & mask == mask } == true
      && item.popup?.items == [companion.detailItem]
      && detail.name == companion.detailItem && detail.type == "item"
      && detail.geometry.position == "popup" && detail.label.drawing == "on"
  }

  private func validClockPreview() throws -> Bool {
    let item: SketchyBarItemQuery = try query(SketchyBarContract.clockPreviewItem)
    return item.name == SketchyBarContract.clockPreviewItem && item.type == "item"
      && item.geometry.drawing == "off" && item.geometry.position == "right"
      && Self.isCanonicalUInt64(item.label.value)
      && item.scripting.hasNoScript
      && item.scripting.updateFrequency == 0
  }

  private func stableItems(_ items: [String], volumeEnabled: Bool) throws -> [String] {
    guard volumeEnabled, Set(items).count == items.count else { return items.sorted() }
    let rows = items.filter { $0.hasPrefix(SketchyBarAudioPicker.prefix) }
    if !rows.isEmpty {
      let parent: SketchyBarAudioPicker.Parent = try query(SketchyBarAudioPicker.popupOwner)
      guard parent.owns(rows: rows) else { return items.sorted() }
    }
    let volumeScript = pluginPath("volume")
    for name in rows {
      guard SketchyBarAudioPicker.selector(name) != nil else { return items.sorted() }
      let row: SketchyBarAudioPicker.Row = try query(name)
      guard row.valid(name: name, pluginPath: volumeScript) else { return items.sorted() }
    }
    return items.filter { !rows.contains($0) }.sorted()
  }

  private func activePalette() throws -> (generationID: String, color: String) {
    let manifest = try ThemeGenerationReader(root: stateRoot).activeManifest()
    guard
      manifest.rendererVersions[SketchyBarConfigurationComposer.providerID, default: 0] >= 2,
      manifest.artifacts[SketchyBarConfigurationComposer.paletteArtifactPath] != nil
    else {
      throw SketchyBarDesktopError.lifecycle(
        "the active theme does not contain the managed SketchyBar shell palette"
      )
    }
    let paletteURL = StateLayout(root: stateRoot).currentThemeArtifact(
      SketchyBarConfigurationComposer.paletteArtifactPath)
    let text = try BoundedRegularFile.readUTF8(at: paletteURL, maximumSize: 65_536)
    let values = text.split(separator: "\n").compactMap { line -> String? in
      let prefix = "MACARCHY_BAR_COLOR="
      return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }
    guard
      values.count == 1,
      values[0].count == 10,
      values[0].hasPrefix("0x"),
      values[0].dropFirst(2).allSatisfy({ $0.isHexDigit })
    else {
      throw SketchyBarDesktopError.lifecycle(
        "the active SketchyBar shell palette has an invalid bar color"
      )
    }
    return (manifest.generationID, values[0].lowercased())
  }

  private func expectedSpaceIndices(_ module: SketchyBarSpaceModule) throws -> [Int] {
    guard module == .dynamicYabai else { return [] }
    let spaces: [YabaiSpaceQuery] = try query(
      control: Self.yabaiURL,
      arguments: ["-m", "query", "--spaces"],
      timeout: 0.5
    )
    let indices = spaces.map(\.index).sorted()
    guard
      !indices.isEmpty,
      indices.count <= 64,
      Set(indices).count == indices.count,
      indices.allSatisfy({ (1..<UInt32.bitWidth).contains($0) })
    else {
      throw SketchyBarDesktopError.lifecycle("yabai returned an invalid Space inventory")
    }
    return indices
  }

  private func expectedItemNames(
    layout: SketchyBarLayout,
    spaceModule: SketchyBarSpaceModule,
    spaceIndices: [Int]
  ) -> [String] {
    let placed = SketchyBarPosition.allCases.flatMap(layout.modules(at:))
    var names = [SketchyBarContract.readyItem] + placed.flatMap(SketchyBarContract.items(of:))
    names += placed.filter(layout.hasTrailingGroupPadding).map(
      SketchyBarContract.groupPaddingItem)
    switch spaceModule {
    case .dynamicYabai:
      names += spaceIndices.map(SketchyBarContract.spaceItem)
    case .disabledWithoutDesktop:
      names.append(SketchyBarContract.spacesUnavailableItem)
    case .hidden:
      break
    }
    return names.sorted()
  }

  private static func isVolumeIcon(_ value: String) -> Bool {
    ["􀊣", "􀊡", "􀊥", "􀊧", "􀊩"].contains(value)
  }

  private static func isWiFiRate(_ value: String) -> Bool {
    value == "Unavailable"
      || value.range(
        of: #"^[0-9]{3}( Bps|KBps|MBps|GBps)$"#,
        options: .regularExpression) != nil
  }

  private static func isWiFiSSIDLabel(_ value: String) -> Bool {
    ["No Wi-Fi interface", "Disconnected / no IPv4", "Privacy restricted", "􀉄"].contains(value)
  }

  private static func isMetricLabel(_ value: String, metric: String) -> Bool {
    let prefix = metric == "cpu" ? "cpu " : "mem "
    guard value.hasPrefix(prefix), value.hasSuffix("%"),
      let level = Int(value.dropFirst(prefix.count).dropLast()), (0...100).contains(level)
    else { return false }
    return value == prefix + String(format: "%02d%%", level)
  }

  private static func isBatteryLabel(_ value: String) -> Bool {
    value == "No battery" || isVolumeLabel(value)
  }

  private static func isBatteryEstimate(_ value: String) -> Bool {
    if value == "No estimate" || value == "No battery" { return true }
    return value.range(of: #"^[0-9]+:[0-5][0-9]h$"#, options: .regularExpression) != nil
  }

  private static func isVolumeLabel(_ value: String) -> Bool {
    guard value.hasSuffix("%"), let level = Int(value.dropLast()), (0...100).contains(level)
    else { return false }
    return value == String(format: "%02d%%", level)
  }

  private static func isCanonicalUInt64(_ value: String) -> Bool {
    UInt64(value).map { String($0) == value } == true
  }

  private static func isSliderLevel(_ value: String?) -> Bool {
    guard let value, let level = Int(value), (0...100).contains(level) else { return false }
    return value == String(level)
  }

  private func query<Value: Decodable>(_ target: String) throws -> Value {
    try query(control: Self.controlURL, arguments: ["--query", target], timeout: 0.1)
  }

  private func pluginPath(_ name: String) -> String {
    stateRoot.appending(path: "\(StateLayout.sketchyBarDirectory)/current/plugins/\(name).sh").path
  }

  private func query<Value: Decodable>(
    control: URL,
    arguments: [String],
    timeout: TimeInterval
  ) throws -> Value {
    let result = try processRunner.run(
      ProcessRequest(executableURL: control, arguments: arguments, timeout: timeout)
    )
    guard result.terminationStatus == 0 else {
      throw SketchyBarDesktopError.lifecycle(
        result.output.isEmpty
          ? "\(control.lastPathComponent) rejected \(arguments.joined(separator: " "))"
          : result.output
      )
    }
    if control == Self.controlURL, result.output.isEmpty {
      throw SketchyBarQueryNoResponse(arguments: arguments)
    }
    do {
      return try control == Self.controlURL
        ? SketchyBarQueryReply.decode(Value.self, from: result.output)
        : JSONDecoder().decode(Value.self, from: Data(result.output.utf8))
    } catch {
      throw SketchyBarDesktopError.lifecycle(
        "cannot decode \(control.lastPathComponent) \(arguments.joined(separator: " ")) runtime state: \(error)"
      )
    }
  }

  private func drifted(
    _ message: String,
    palette: (generationID: String, color: String),
    items: [String],
    spaceIndices: [Int],
    clockLabelPresent: Bool = false,
    volumeLevelPresent: Bool = false
  ) -> SketchyBarCoreRuntimeInspection {
    SketchyBarCoreRuntimeInspection(
      status: .drifted,
      message: message,
      themeGenerationID: palette.generationID,
      barColor: palette.color,
      items: items,
      spaceIndices: spaceIndices,
      clockLabelPresent: clockLabelPresent,
      volumeLevelPresent: volumeLevelPresent
    )
  }

  private func failed(_ error: any Error) -> SketchyBarCoreRuntimeInspection {
    SketchyBarCoreRuntimeInspection(status: .failed, message: String(describing: error))
  }
}

private struct SketchyBarBarQuery: Decodable {
  let position: String
  let drawing: String
  let color: String
  let height: Int
  let margin: Int
  let cornerRadius: Int
  let hidden: String
  let yOffset: Int
  let topmost: String
  let items: [String]

  enum CodingKeys: String, CodingKey {
    case position, drawing, color, height, margin, items, hidden, topmost
    case yOffset = "y_offset"
    case cornerRadius = "corner_radius"
  }
}

private struct SketchyBarItemQuery: Decodable {
  struct Popup: Decodable {
    let drawing: String
    let items: [String]
  }
  struct Slider: Decodable { let percentage: String }
  struct Geometry: Decodable {
    let drawing: String
    let position: String
    let associatedSpaceMask: UInt32
    let width: Int?

    enum CodingKeys: String, CodingKey {
      case drawing, position, width
      case associatedSpaceMask = "associated_space_mask"
    }
  }

  struct Label: Decodable {
    let value: String
    let drawing: String
  }

  struct Scripting: Decodable {
    let script: String
    let clickScript: String
    let updateFrequency: Int
    let updateMask: UInt64?
    let updates: String?

    enum CodingKeys: String, CodingKey {
      case script
      case clickScript = "click_script"
      case updateFrequency = "update_freq"
      case updateMask = "update_mask"
      case updates
    }

    var hasNoScript: Bool { script.isEmpty || script == "(null)" }
  }

  let name: String
  let type: String
  let geometry: Geometry
  let label: Label
  let scripting: Scripting
  let slider: Slider?
  let bracket: [String]?
  let popup: Popup?

  var isReadyMarker: Bool {
    name == SketchyBarContract.readyItem && type == "item"
      && geometry.drawing == "off" && geometry.position == "right"
  }
}

/// Decodes `sketchybar --query` output. SketchyBar 2.24 prints icon, label and image values
/// verbatim, so a quote, backslash or control character in bar text such as a song title, an
/// SSID or a device name makes its reply invalid JSON. Each such value is closed by the
/// `drawing` key that SketchyBar prints next at the same indent, which bounds the raw text.
enum SketchyBarQueryReply {
  static func decode<Value: Decodable>(_ type: Value.Type, from output: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(escapingRawValues(output).utf8))
  }

  private static func escapingRawValues(_ output: String) -> String {
    var result = ""
    var rest = output[...]
    while let opening = rest.range(of: "\"value\": \"", options: .literal) {
      let lineStart = rest[..<opening.lowerBound].lastIndex(of: "\n").map { rest.index(after: $0) }
      let indent = rest[(lineStart ?? rest.startIndex)..<opening.lowerBound]
      result.append(contentsOf: rest[..<opening.upperBound])
      rest = rest[opening.upperBound...]
      guard !indent.isEmpty, indent.allSatisfy({ $0 == "\t" }),
        let closing = rest.range(of: "\",\n\(indent)\"drawing\": \"", options: .literal)
      else { continue }
      for scalar in rest[..<closing.lowerBound].unicodeScalars {
        switch scalar {
        case "\"", "\\": result += "\\\(scalar)"
        case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
        default: result.unicodeScalars.append(scalar)
        }
      }
      rest = rest[closing.lowerBound...]
    }
    result.append(contentsOf: rest)
    return result
  }
}

/// The label of one `sketchybar --query <item>` result, as read by the bar's helper commands.
struct SketchyBarLabelQuery: Decodable {
  struct Label: Decodable { let value: String }
  let label: Label

  static func value(from output: String) throws -> String {
    try SketchyBarQueryReply.decode(Self.self, from: output).label.value
  }
}

private struct SketchyBarEventQuery: Decodable {
  let bit: UInt64
}

private struct YabaiSpaceQuery: Decodable {
  let index: Int
}
