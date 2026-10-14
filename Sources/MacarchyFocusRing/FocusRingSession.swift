import AppKit
import Darwin
import Foundation
import ThemeCore

/// Bounded prototype: one accent outline around the front connection's first suitable
/// window until the deadline, SIGINT/SIGTERM/SIGHUP or the first failure. The target is
/// not exact focus; window-server events drive refresh with a 2 s missed-event reconciliation.
@MainActor
final class FocusRingSession {
  private let options: FocusRingOptions
  private let root: URL
  private let focus: SkyLightFocus
  private var palette: PaletteState
  private let panel = OutlinePanel(
    contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  private let outline = OutlineView(frame: .zero)
  private var diagnostics = FocusRingDiagnostics()
  private var timer: Timer?
  private var settleTimer: Timer?
  private var deadlineTimer: Timer?
  private var notifications: SkyLightNotifications?
  private var cachedTarget: WindowCandidate?
  private var cachedConnection: Int32?
  private var sources: [DispatchSourceSignal] = []
  private var start = 0.0, deadline = 0.0, nextPointerCheck = 0.0, nextWatchdog = 0.0
  private var eventCount = 0, fullRefreshCount = 0, geometryRefreshCount = 0
  private var watchdogRefreshCount = 0
  private var running = false
  private var previousOrderedTarget: UInt32?
  private var stopReason: String?
  private var failure: String?
  private var exitCode: Int32 = 0

  static func run(_ options: FocusRingOptions) -> Int32 {
    let session: FocusRingSession
    do {
      // Every preflight completes before any window exists.
      try requireConsoleSession()
      let root = URL(filePath: options.stateRoot)
      let palette = try PaletteState.load(root: root)
      let focus = try SkyLightFocus()
      try refuseCompetingOutlines()
      NSApplication.shared.setActivationPolicy(.accessory)
      session = FocusRingSession(options: options, root: root, focus: focus, palette: palette)
    } catch {
      writeError("focus ring refused: \(error)")
      return 1
    }
    return session.execute()
  }

  private init(options: FocusRingOptions, root: URL, focus: SkyLightFocus, palette: PaletteState) {
    self.options = options
    self.root = root
    self.focus = focus
    self.palette = palette
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
    panel.contentView = outline
    outline.color = palette.color.cgColor
  }

  private func execute() -> Int32 {
    start = ProcessInfo.processInfo.systemUptime
    deadline = start + options.seconds
    nextPointerCheck = start + 0.25
    nextWatchdog = start + 2
    for number in [SIGINT, SIGTERM, SIGHUP] {
      Darwin.signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler {
        MainActor.assumeIsolated { self.stop("signal-\(number)", code: 128 + number) }
      }
      source.resume()
      sources.append(source)
    }
    do {
      notifications = try focus.newNotifications { [weak self] batch in self?.handle(batch) }
      try notifications?.start()
    } catch {
      stop("failure", code: 1, error: "notification start failed: \(error)")
    }
    if stopReason == nil { tick() }
    if stopReason == nil {
      // Canonical pointer checks and the 2 s watchdog only; window motion is event-driven.
      let checks = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.maintenance() }
      }
      let cutoff = Timer(
        timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime), repeats: false
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.stop("duration", code: 0) }
      }
      RunLoop.main.add(checks, forMode: .common)
      RunLoop.main.add(cutoff, forMode: .common)
      (timer, deadlineTimer) = (checks, cutoff)
      running = true
      NSApplication.shared.run()
      running = false
      stop("run-loop-exit", code: 1, error: "AppKit run loop ended early")
    }
    for source in sources { source.cancel() }
    return report(elapsed: ProcessInfo.processInfo.systemUptime - start)
  }

  private func tick() {
    guard stopReason == nil else { return }
    autoreleasepool {
      do { try step() } catch { stop("failure", code: 1, error: "\(error)") }
    }
  }

  /// Full refresh: topology, selection and subscription are re-read from the window server.
  private func step() throws {
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      return stop("duration", code: 0)
    }
    fullRefreshCount = Self.adding(fullRefreshCount, 1)
    let ownID = panel.windowNumber > 0 ? UInt32(panel.windowNumber) : nil
    // Query authoritative Space state rather than infer fullscreen from geometry.
    let context = try focus.frontContext()
    switch try focus.spaceKind(in: context) {
    case .user: break
    case .fullscreen:
      try subscribe([], excluding: ownID)
      return hide("native-fullscreen")
    case .other(let type):
      try subscribe([], excluding: ownID)
      return hide("unknown-space-type-\(type)")
    }
    let target = try focus.firstSuitableWindow(in: context, excluding: ownID)
    try subscribe(focus.observedWindowIDs.filter { $0 != ownID }, excluding: ownID)
    guard let target else { return hide("no-eligible-window") }
    (cachedTarget, cachedConnection) = (target, context.ownConnection)
    try updateGeometry(target, connection: context.ownConnection)
  }

  private func subscribe(_ ids: [UInt32], excluding ownID: UInt32?) throws {
    guard let notifications else { throw FocusRingError("notification source is absent") }
    try notifications.observe(windowIDs: ids, excluding: ownID)
  }

  private func handle(_ batch: FocusEventBatch) {
    guard stopReason == nil else { return }
    eventCount = Self.adding(eventCount, batch.count)
    if !batch.requiresFullRefresh, let target = cachedTarget, let connection = cachedConnection {
      // Background motion is ignored; only the cached target's geometry is refreshed.
      if batch.geometryIDs.contains(target.windowID) {
        geometryRefreshCount = Self.adding(geometryRefreshCount, 1)
        // A stale target gets one full refresh; a failing full query stops the helper.
        let updated = autoreleasepool { () -> Bool in
          do {
            try updateGeometry(target, connection: connection)
            return true
          } catch { return false }
        }
        if !updated { tick() }
      }
    } else {
      tick()
    }
    guard batch.settle, settleTimer == nil, stopReason == nil else { return }
    let settle = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.settleTimer = nil
        self?.tick()
      }
    }
    RunLoop.main.add(settle, forMode: .common)
    settleTimer = settle
  }

  /// Canonical-pointer checks plus a documented 2 s missed-event reconciliation, not a
  /// hidden fast poll. Watchdog refreshes are reported so absent events stay visible.
  private func maintenance() {
    guard stopReason == nil else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now < deadline else { return stop("duration", code: 0) }
    if now >= nextPointerCheck {
      nextPointerCheck = now + 0.25
      do {
        // A stable pointer stays authoritative; decode the palette only when it moves.
        let moved = try autoreleasepool { () throws -> Bool in
          guard try PaletteState.pointerStamp(root: root) != palette.stamp else { return false }
          palette = try PaletteState.load(root: root)
          outline.color = palette.color.cgColor
          return true
        }
        if moved { tick() }
      } catch { return stop("failure", code: 1, error: "\(error)") }
    }
    if now >= nextWatchdog, stopReason == nil {
      nextWatchdog = now + 2
      watchdogRefreshCount = Self.adding(watchdogRefreshCount, 1)
      tick()
    }
  }

  private static func adding(_ value: Int, _ amount: Int) -> Int {
    let (sum, overflow) = value.addingReportingOverflow(max(0, amount))
    return overflow ? .max : sum
  }

  /// Bounds, frame, level, ordering and record for an already selected target.
  private func updateGeometry(_ target: WindowCandidate, connection: Int32) throws {
    let bounds = try focus.bounds(of: target.windowID, connection: connection)
    if outline.cornerRadius != target.cornerRadius {
      outline.cornerRadius = target.cornerRadius
    }
    guard let primary = NSScreen.screens.first?.frame else {
      throw FocusRingError("no primary screen")
    }
    let frame = OutlineGeometry.outlineFrame(
      around: OutlineGeometry.appKitRect(fromWindowServer: bounds, primaryScreenFrame: primary))
    // Capture eligibility before any public frame update or order. On first
    // show and on resize, AppKit's deferred window backing is not yet published
    // to the window server (GetWindowBounds reports zero size right after the
    // first order), so AppKit owns those changes and no transaction is issued.
    let directMove = SkyLightOutlineMover.shouldMoveDirectly(
      previous: panel.frame, next: frame, isVisible: panel.isVisible)
    if panel.frame.size == frame.size {
      // Movement-only: keep AppKit model position current without forcing a redraw.
      if panel.frame.origin != frame.origin { panel.setFrameOrigin(frame.origin) }
    } else {
      panel.setFrame(frame, display: true)
    }
    let level = NSWindow.Level(rawValue: Int(target.level))
    let levelChanged = panel.level != level
    if levelChanged { panel.level = level }
    if OutlineOrdering.needsOrder(
      isVisible: panel.isVisible, previousTarget: previousOrderedTarget,
      target: target.windowID, levelChanged: levelChanged)
    {
      panel.order(.below, relativeTo: Int(target.windowID))
      previousOrderedTarget = target.windowID
    }
    if directMove { try moveOwnWindow(to: frame, primary: primary) }
    record(visible: true, reason: "target", target: target.windowID, frame: frame)
  }

  private var outlineMover: SkyLightOutlineMover?
  private var ownMoveCount = 0

  /// AppKit already holds `frame`; committing the same position for our own window
  /// asks the window server to apply it now rather than at AppKit's deferred flush.
  private func moveOwnWindow(to frame: CGRect, primary: CGRect) throws {
    let number = panel.windowNumber
    guard number > 0, let windowID = UInt32(exactly: number) else {
      throw FocusRingError("outline panel has no window number (\(number))")
    }
    let mover: SkyLightOutlineMover
    if let existing = outlineMover, existing.windowID == windowID {
      mover = existing
    } else {
      mover = try focus.newOutlineMover(windowID: windowID)
      outlineMover = mover
    }
    try mover.move(to: CGPoint(x: frame.minX, y: primary.maxY - frame.maxY))
    ownMoveCount += 1
  }

  private func hide(_ reason: String) {
    if panel.isVisible { panel.orderOut(nil) }
    previousOrderedTarget = nil
    (cachedTarget, cachedConnection) = (nil, nil)
    record(visible: false, reason: reason)
  }

  private func record(visible: Bool, reason: String, target: UInt32? = nil, frame: CGRect? = nil) {
    diagnostics.record(
      FocusRingObservation(
        uptime: ProcessInfo.processInfo.systemUptime - start, visible: visible, reason: reason,
        targetWindowID: target, frame: frame.map(FocusRingObservation.Frame.init),
        generationID: palette.generationID, accent: palette.accent))
  }

  private func stop(_ reason: String, code: Int32, error: String? = nil) {
    guard stopReason == nil else { return }
    (stopReason, exitCode, failure) = (reason, code, error)
    for pending in [timer, settleTimer, deadlineTimer] { pending?.invalidate() }
    (timer, settleTimer, deadlineTimer) = (nil, nil, nil)
    // Unsubscribe before the outline goes away; a stop error always fails the run.
    if let source = notifications {
      notifications = nil
      do { try source.stop() } catch {
        (stopReason, exitCode) = ("failure", 1)
        failure = [failure, "notification stop failed: \(error)"].compactMap { $0 }
          .joined(separator: "; ")
      }
    }
    hide(failure == nil ? "stopped" : "failure")
    panel.close()
    guard running else { return }
    NSApplication.shared.stop(nil)
    // stop(_:) is only observed after an event; wake the loop explicitly.
    if let wake = NSEvent.otherEvent(
      with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
    {
      NSApplication.shared.postEvent(wake, atStart: false)
    }
  }

  /// Written only after the outline is removed.
  private func report(elapsed: Double) -> Int32 {
    let outcome = failure != nil ? "failed" : exitCode == 0 ? "completed" : "interrupted"
    let reason = stopReason ?? "unknown"
    if let failure { Self.writeError("focus ring failed: \(failure)") }
    do {
      let summaryParts: [String] = [
        "Focus ring \(outcome) (\(reason)) after \(Int(elapsed))s, ",
        "\(diagnostics.observations.count) state changes, \(eventCount) events, ",
        "\(fullRefreshCount) full/\(geometryRefreshCount) geometry/",
        "\(watchdogRefreshCount) watchdog refreshes; target is ",
        "\(FocusTargetPolicy.selectionLabel), event-driven with 2s reconciliation, ",
        "not exact focus.",
      ]
      var data = Data(summaryParts.joined().utf8)
      if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        data = try encoder.encode(
          FocusRingReport(
            outcome: outcome, stopReason: reason, error: failure, seconds: elapsed,
            observations: diagnostics.observations,
            droppedObservations: diagnostics.dropped, eventCount: eventCount,
            fullRefreshCount: fullRefreshCount, geometryRefreshCount: geometryRefreshCount,
            watchdogRefreshCount: watchdogRefreshCount, directMoveCount: ownMoveCount))
      }
      data.append(0x0A)
      try FileHandle.standardOutput.write(contentsOf: data)
      return exitCode
    } catch {
      Self.writeError("cannot write report: \(error)")
      return 1
    }
  }

  private static func writeError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
  }

  private static func requireConsoleSession() throws {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    guard (session[kCGSessionUserIDKey] as? NSNumber)?.uint32Value == getuid(),
      session[kCGSessionOnConsoleKey] as? Bool == true,
      session[kCGSessionLoginDoneKey] as? Bool == true
    else { throw FocusRingError("not this user's completed on-console window-server session") }
  }

  /// Point-in-time refusal only: a racing start is not prevented and this is not a lock.
  private static func refuseCompetingOutlines() throws {
    let runner = ProcessRunner.live
    let borders = try processIDs(command: "borders", runner: runner)
    guard borders.isEmpty else {
      throw FocusRingError("JankyBorders is running for this user (pids \(borders))")
    }
    let command = try ownCommand()
    let helpers = try processIDs(command: command, runner: runner).filter { $0 != getpid() }
    guard helpers.isEmpty else {
      throw FocusRingError("another \(command) is running (pids \(helpers))")
    }
    let registration = try HomebrewUserServiceRegistration.inspect(
      provider: .borders, home: URL(filePath: NSHomeDirectory()), runner: runner)
    // Any registration refuses, loaded or not, matching the preview policy.
    guard registration == nil else {
      throw FocusRingError(
        "a Homebrew borders service is registered for this user; remove it first")
    }
  }

  /// Exact `p_comm` matches for this user; pgrep exits 1 for a clean absence.
  private static func processIDs(command: String, runner: ProcessRunner) throws -> [pid_t] {
    let result = try runner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/pgrep"),
        arguments: ["-x", "-U", "\(getuid())", command], timeout: 2))
    switch result.terminationStatus {
    case 1: return []
    case 0:
      let lines = result.output.split(whereSeparator: \.isNewline)
      let pids = lines.compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
      guard !pids.isEmpty, pids.count == lines.count else {
        throw FocusRingError("unexpected pgrep output: \(result.output)")
      }
      return pids
    default:
      throw FocusRingError(
        "pgrep \(command) failed (status \(result.terminationStatus)): \(result.output)")
    }
  }

  /// The kernel's truncated `p_comm`, which is what `pgrep -x` matches.
  private static func ownCommand() throws -> String {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
      throw FocusRingError("cannot read own process name (errno \(errno))")
    }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    let literal = name.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
    }
    guard !name.isEmpty, literal else {
      throw FocusRingError("own process name '\(name)' is not a literal pgrep pattern")
    }
    return name
  }
}

/// The canonical palette as last read, plus the theme pointer's link target.
private struct PaletteState {
  let stamp: String
  let generationID: String
  let accent: String
  let color: OutlineColor

  static func pointerStamp(root: URL) throws -> String {
    let path = root.appending(path: "current").path
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let count = readlink(path, &buffer, buffer.count)
    guard count >= 0, count < buffer.count else {
      throw FocusRingError("cannot read theme pointer \(path) (errno \(errno))")
    }
    return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// Stamped before the read so a concurrent swap is seen at the next check.
  static func load(root: URL) throws -> Self {
    let stamp = try pointerStamp(root: root)
    let palette = try BordersPalette.read(root: root)
    guard let color = OutlineColor(accent: palette.accent) else {
      throw FocusRingError("theme accent \(palette.accent) is not #RRGGBB")
    }
    return Self(
      stamp: stamp, generationID: palette.generationID, accent: palette.accent, color: color)
  }
}

private final class OutlinePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Strokes the rounded outline only; the interior stays transparent.
private final class OutlineView: NSView {
  var color = CGColor(gray: 0, alpha: 0) {
    didSet { needsDisplay = true }
  }

  var cornerRadius = OutlineGeometry.defaultCornerRadius {
    didSet { needsDisplay = true }
  }

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    // Clear first so a resize or theme change leaves no stale outline pixels.
    context.clear(bounds)
    let rect = OutlineGeometry.strokeRect(in: bounds)
    let radius = OutlineGeometry.pathRadius(for: rect, cornerRadius: cornerRadius)
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setStrokeColor(color)
    context.setLineWidth(OutlineGeometry.width)
    context.strokePath()
  }
}
