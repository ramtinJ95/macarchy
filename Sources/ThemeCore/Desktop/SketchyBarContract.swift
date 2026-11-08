import Foundation

/// Names the managed bar's generator and the CLI must agree on: each module's top-level items
/// and the sub-items listed below, the plugin scripts, and the hidden `macarchy desktop`
/// helpers those scripts run. The generator,
/// the CLI's runtime verifier, its bar helpers and the generation inspector use these entries.
/// It is not an inventory of the whole bar: other sub-items, popup rows and many CLI-side item
/// names are still spelled where they are used. Bars already on disk still call the helper
/// names and flags, so none of them may change.
package enum SketchyBarContract {
  package static let readyItem = "macarchy.theme.ready"
  package static let clockItem = "macarchy.clock"
  /// Holds the clock's week-number preview deadline; never drawn.
  package static let clockPreviewItem = "macarchy.clock.preview"
  package static let spacesUnavailableItem = "macarchy.spaces.unavailable"
  package static let toggleItem = "macarchy.toggle"
  package static let appleItem = "macarchy.apple"
  package static let volumeItem = "macarchy.volume"
  package static let volumeSliderItem = "macarchy.volume.slider"
  package static let volumeIconItem = "macarchy.volume.icon"
  package static let volumeBracketItem = "macarchy.volume.bracket"
  package static let volumePaddingItem = "macarchy.volume.padding"
  package static let batteryItem = "macarchy.battery"
  package static let batteryRemainingItem = "macarchy.battery.remaining"
  package static let wifiItem = "macarchy.wifi"
  package static let wifiItems = [
    wifiItem, "macarchy.wifi.up", "macarchy.wifi.down",
    "macarchy.wifi.ssid", "macarchy.wifi.hostname", "macarchy.wifi.ip",
    "macarchy.wifi.mask", "macarchy.wifi.router",
  ]
  package static let wifiBracketItem = "macarchy.wifi.bracket"
  package static let mediaItem = "macarchy.media"
  package static let mediaItems = [
    mediaItem, "macarchy.media.artist", "macarchy.media.title",
    "macarchy.media.previous", "macarchy.media.playpause", "macarchy.media.next",
    "macarchy.media.preview",
  ]

  package static func spaceItem(_ index: Int) -> String { "macarchy.space.\(index)" }

  /// The item of the CPU or memory metric.
  package static func metricItem(_ module: SketchyBarModule) -> String {
    "macarchy.\(module.rawValue)"
  }

  /// The spacer after the battery or the last of a CPU/memory group.
  package static func groupPaddingItem(_ module: SketchyBarModule) -> String {
    "macarchy.\(module.rawValue).padding"
  }

  /// Every item a placed module adds, except Spaces, which follow yabai's inventory, and group
  /// padding, which follows the layout.
  package static func items(of module: SketchyBarModule) -> [String] {
    switch module {
    case .spaces: []
    case .clock:
      [clockItem, clockPreviewItem] + SketchyBarClockCompanion.all.flatMap(\.items)
    case .volume:
      [volumeItem, volumeSliderItem, volumeIconItem, volumeBracketItem, volumePaddingItem]
    case .battery: [batteryItem, batteryRemainingItem]
    case .cpu, .memory: [metricItem(module)]
    case .wifi: wifiItems + [wifiBracketItem]
    case .media: mediaItems
    case .apple: [appleItem]
    case .toggle: [toggleItem]
    }
  }

  /// Plugins rendered for every bar.
  package static let clockPlugin = "clock"
  package static let spaceIndexesPlugin = "space-indexes"
  /// Rendered only when the profile names a trusted hook or personal configuration.
  package static let userHookPlugin = "user-hook"

  /// The plugins rendered only when `module` is placed. A module's own plugin is named after it.
  package static func plugins(of module: SketchyBarModule) -> [String] {
    switch module {
    case .spaces: []
    case .clock: SketchyBarClockCompanion.all.map(\.plugin)
    case .volume, .battery, .cpu, .memory, .wifi, .media, .apple, .toggle: [module.rawValue]
    }
  }

  /// Every plugin a generation may lack: the user hook and each module's plugins.
  package static let optionalPlugins =
    [userHookPlugin] + SketchyBarModule.allCases.flatMap(plugins(of:))

  package static func pluginArtifactPath(_ plugin: String) -> String { "plugins/\(plugin).sh" }

  // Hidden `macarchy desktop` helpers that generated scripts run.
  package static let calendarCommand = "_calendar"
  package static let barToggleCommand = "_bar-toggle"
  package static let hookCommand = "_run-sketchybar-hook"
  package static let audioPickerCommand = "_audio-picker"
  package static let mediaCommand = "_media"
  package static let wifiCommand = "_wifi"
  package static let popupToggleCommand = "_popup-toggle"
  package static let cpuLoadCommand = "_cpu-load"
}

/// An indicator the generated clock module keeps beside the clock (ADR-0256): one item with a
/// hover detail, a plugin that runs the companion's hidden helper, and a `_calendar` flag that
/// moves it along with the clock. The generator renders every companion from its entry and the
/// CLI verifies and drives it from the same entry. Older generations lack some companions, so
/// their clock scripts request only what they generated.
package struct SketchyBarClockCompanion: Sendable {
  package enum Side: Sendable { case left, right }

  package let item: String
  /// Visual side of the clock.
  package let side: Side
  package let plugin: String
  /// The hidden `macarchy desktop` subcommand its plugin runs.
  package let helperCommand: String
  /// The `_calendar` flag, without dashes, that asks the clock to position it.
  package let calendarFlag: String
  package let updateFrequency: Int
  /// Its feature triggers this event after a change so the bar refreshes before its timer.
  package let refreshEvent: String?
  /// How the generated bar first draws it, before its helper runs.
  package let initiallyDrawn: Bool
  package let icon: String
  /// The palette variable of its first icon color.
  package let iconColor: String
  package let initialDetail: String
  /// The color options its plugin passes to its helper, as rendered shell words.
  package let helperColorOptions: String
  /// The detail its plugin shows when the helper fails.
  package let failureDetail: String

  package var detailItem: String { item + ".detail" }
  package var items: [String] { [item, detailItem] }
  package var events: [String] { Self.hoverEvents + (refreshEvent.map { [$0] } ?? []) }

  private static let hoverEvents = [
    "mouse.clicked", "mouse.entered", "mouse.exited", "mouse.exited.global", "system_woke",
  ]
  private static let accentAndMuted =
    "--accent \"$MACARCHY_ACCENT_COLOR\" --muted \"$MACARCHY_MUTED_COLOR\""

  package static let update = Self(
    item: "macarchy.update", side: .right, plugin: "update",
    helperCommand: "_update-indicator", calendarFlag: "update-indicator", updateFrequency: 60,
    refreshEvent: nil, initiallyDrawn: false, icon: "↻", iconColor: "MACARCHY_ACCENT_COLOR",
    initialDetail: "Checking Macarchy updates…",
    helperColorOptions: "--accent \"$MACARCHY_ACCENT_COLOR\" --warning \"$MACARCHY_BATTERY_RED\"",
    failureDetail: "Update indicator failed; see SketchyBar stderr for details.")

  /// Keep-awake changes trigger this event so the indicator refreshes before its timer.
  package static let keepAwakeEvent = "macarchy_keep_awake_changed"
  /// SF Symbols cup.and.saucer.fill, drawn by SF Pro at the size of the other toggle icons.
  package static let keepAwakeIcon = "\u{100E19}"
  package static let keepAwake = Self(
    item: "macarchy.keep-awake", side: .left, plugin: "keep-awake",
    helperCommand: "_keep-awake-indicator", calendarFlag: "keep-awake-indicator",
    updateFrequency: 30, refreshEvent: keepAwakeEvent, initiallyDrawn: true,
    icon: keepAwakeIcon, iconColor: "MACARCHY_MUTED_COLOR", initialDetail: "Keep-awake is off.",
    helperColorOptions: accentAndMuted,
    failureDetail: "Keep-awake toggle failed; see SketchyBar stderr for details.")

  /// Microphone mute changes trigger this event so the indicator refreshes before its timer.
  package static let microphoneEvent = "macarchy_microphone_changed"
  /// SF Symbols mic.slash.fill, drawn by the SF Pro font like the bar's other symbol glyphs.
  package static let microphoneMutedIcon = "\u{1002B3}"
  /// SF Symbols mic.fill, the live counterpart of `microphoneMutedIcon`.
  package static let microphoneLiveIcon = "\u{1002B1}"
  package static let microphone = Self(
    item: "macarchy.microphone", side: .left, plugin: "microphone",
    helperCommand: "_microphone-indicator", calendarFlag: "microphone-indicator",
    updateFrequency: 30, refreshEvent: microphoneEvent, initiallyDrawn: true,
    icon: microphoneLiveIcon, iconColor: "MACARCHY_MUTED_COLOR",
    initialDetail: "Microphone is live.", helperColorOptions: accentAndMuted,
    failureDetail: "Microphone toggle failed; see SketchyBar stderr for details.")

  /// Idle screensaver changes trigger this event so its toggle refreshes before its timer.
  package static let saverIdleEvent = "macarchy_saver_idle_changed"
  /// SF Symbols pause.fill, drawn by SF Pro like the idle screensaver icon it replaces.
  package static let saverPausedIcon = "\u{100286}"
  /// SF Symbols sparkles.tv: a screen showing decorative sparkles, drawn by SF Pro.
  package static let saverIdleIcon = "\u{10114B}"
  package static let saverPaused = Self(
    item: "macarchy.saver-paused", side: .left, plugin: "saver-paused",
    helperCommand: "_saver-paused-indicator", calendarFlag: "saver-paused-indicator",
    updateFrequency: 30, refreshEvent: saverIdleEvent, initiallyDrawn: true,
    icon: saverIdleIcon, iconColor: "MACARCHY_MUTED_COLOR",
    initialDetail: "Idle screensaver is off.", helperColorOptions: accentAndMuted,
    failureDetail: "Idle screensaver toggle failed; see SketchyBar stderr for details.")

  /// In the order the generator draws them and the clock script requests them.
  package static let all = [update, keepAwake, microphone, saverPaused]
}
