/// The `macarchy` arguments Macarchy runs itself: action-menu rows, clicks on the bar's clock
/// companions, and launch agents with the detached processes that show their alerts. Launch
/// agents already installed keep running these, so the commands they name must keep parsing
/// them. Hidden `macarchy desktop` helpers that generated bar scripts run live in
/// `SketchyBarContract`; hidden menu-terminal commands declare their own `commandName`.
enum MacarchyInvocation {
  /// Shows a failure in an alert, since these launches have no terminal.
  static let alertOnError = "--alert-on-error"

  static let themeBrowse = ["theme", "browse"]
  static let keybindingsShowEffective = ["keybindings", "show", "--effective"]
  static let captureScreenshot = ["capture", "screenshot"]
  static let captureAnnotate = ["capture", "annotate"]
  static let captureOCR = ["capture", "ocr"]
  static let imageChoose = ["image", "choose"]
  static let clipboardOpen = ["clipboard", "open"]
  static let clipboardClearConfirmed = ["clipboard", "clear", "--confirm"]
  /// The automatic clear's launch agent.
  static let clipboardAutoClear = ["clipboard", "_auto-clear"]
  static let keepAwakeToggle = ["keep-awake", "toggle"]
  static let keepAwakeOff = ["keep-awake", "off"]
  static let saverStart = ["saver", "start"]
  static let saverIdleToggle = ["saver", "idle", "toggle"]
  static let saverTogglePause = ["saver", "toggle-pause"]
  static let saverResume = ["saver", "resume"]
  /// The idle screensaver's launch agent.
  static let saverIdle = ["saver", SaverCommand.Observe.commandName]
  /// The program inside each screensaver panel.
  static let saverRun = ["saver", SaverCommand.Run.commandName]
  static let microphoneChoose = ["mic", "choose"]
  static let microphoneToggle = ["mic", "toggle"]
  static let microphoneUnmute = ["mic", "unmute"]
}
