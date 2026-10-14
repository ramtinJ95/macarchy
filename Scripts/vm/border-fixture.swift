// Developer-only VM-guest fixture, not shipped: swiftc -O -parse-as-library
import AppKit

struct Fail: Error { let m: String }

func int(_ v: Any?) -> Int? {
  (v as? NSNumber).flatMap {
    CFGetTypeID($0) == CFNumberGetTypeID() && !CFNumberIsFloatType($0 as CFNumber)
      ? $0.intValue : nil
  }
}

@main @MainActor enum Main {
  static func main() {
    do {
      var v: Int32 = 0
      var n = 4
      guard sysctlbyname("kern.hv_vmm_present", &v, &n, nil, 0) == 0, v == 1 else {
        throw Fail(m: "not a VM guest")
      }
      let f = try Fixture(ProcessInfo.processInfo.arguments.dropFirst())
      NSApplication.shared.setActivationPolicy(.regular)
      NSApp.delegate = f
      f.trap()
      NSApp.run()
      exit(f.code)
    } catch {
      FileHandle.standardError.write(Data("\((error as? Fail)?.m ?? "\(error)")\n".utf8))
      exit(1)
    }
  }
}

@MainActor final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let dfd: Int32, count: Int, secs: Double, label: String, t0 = ProcessInfo.processInfo.systemUptime
  var ws: [NSWindow] = [], base: [NSRect] = [], moved: [Bool] = [], small: [Bool] = [],
    closed: [Bool] = []
  var vis = NSRect.zero, ready = false, ending = false, acked = 0, code: Int32 = 1,
    srcs: [DispatchSourceSignal] = []
  var err: String?, reason: String?, poll: Timer?, fsx: [String: Any] = [:]
  var an: (q: Int, i: Int, a: NSRect, b: NSRect, n: Int, t: Timer)?,
    fs: (q: Int, i: Int, want: Bool)?
  // Focus and minimize/restore ack sequence q once done() holds, or fail after deadline d.
  var settling: (q: Int, d: Double, done: @MainActor () -> Bool, failure: String)?
  var mo: (q: Int, i: Int, o: NSRect, t: Timer, n: Int, s: Double)?, mx: [String: Any] = [:]
  var up: Double { ProcessInfo.processInfo.systemUptime - t0 }

  init(_ a: ArraySlice<String>) throws {
    var o: [String: String] = [:]
    var i = a.startIndex
    while i < a.endIndex {
      guard i + 1 < a.endIndex, o.updateValue(a[i + 1], forKey: a[i]) == nil else {
        throw Fail(m: "bad arguments")
      }
      i += 2
    }
    guard o.count == 4, let d = o["--directory"], let c = Int(o["--count"] ?? ""),
      [1, 8, 24].contains(c), let s = Int(o["--seconds"] ?? ""),
      (30...600).contains(s), let l = o["--label"], l == "A" || l == "B"
    else { throw Fail(m: "bad arguments") }
    var st = stat()
    var sf = statfs()
    let fd = open(d, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard d.hasPrefix("/"), fd >= 0, fstat(fd, &st) == 0, st.st_uid == getuid(),
      st.st_mode & 0o022 == 0, fstatfs(fd, &sf) == 0,
      sf.f_flags & UInt32(MNT_LOCAL) != 0,
      withUnsafeBytes(
        of: sf.f_fstypename, { b in String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) })
        == "apfs"
    else { throw Fail(m: "unsafe --directory") }
    dfd = fd
    count = c
    secs = Double(s)
    label = l
    super.init()
  }

  func applicationDidFinishLaunching(_: Notification) {
    guard let v = NSScreen.main?.visibleFrame else { return fail("no screen") }
    let n = CGFloat(count - 1)
    let w = min(720, v.width)
    let h = min(480, v.height)
    let dx = n > 0 ? min(28, (v.width - w) / n) : 0
    let dy = n > 0 ? min(24, (v.height - h) / n) : 0
    vis = v
    for i in 0..<count {
      let c = CGFloat(i)
      let r = NSRect(
        x: v.midX - (w + n * dx) / 2 + c * dx, y: v.midY + (h + n * dy) / 2 - h - c * dy, width: w,
        height: h)
      let win = NSWindow(
        contentRect: r, styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
      win.isReleasedWhenClosed = false
      win.setFrame(r, display: false)
      win.title = "Fixture \(label) #\(i)"
      win.tabbingMode = .disallowed
      win.collectionBehavior = .fullScreenPrimary
      win.delegate = self
      win.backgroundColor = (label == "A" ? NSColor.systemBlue : .systemOrange).blended(
        withFraction: 0.7, of: .white)
      win.orderFront(nil)
      ws.append(win)
      base.append(r)
    }
    moved = Array(repeating: false, count: count)
    small = moved
    closed = moved
    ws[0].makeKeyAndOrderFront(nil)
    // Deliberate VM-only focus: main() rejects non-VM hosts before NSApp exists. Cooperative
    // activate() left this fixture inactive in the guest; the legacy call activates regardless
    // but asynchronously, so focus acks wait (bounded) for isActive/isKeyWindow in check().
    NSApp.activate(ignoringOtherApps: true)
    ready = true
    publish()
    poll = timer(0.1, true) { self.check() }
  }

  func check() {
    if up > secs { return finish("timeout", 2) }
    if let p = settling {
      guard p.done() else {
        if up > p.d { fail(p.failure) }
        return
      }
      settling = nil
      acked = p.q
      publish()
    }
    if an != nil || fs != nil || mo != nil { return }
    do { if let c = try command() { try handle(c) } } catch {
      fail((error as? Fail)?.m ?? "\(error)")
    }
  }

  func command() throws -> [String: Any]? {
    var st = stat()
    var b = [UInt8](repeating: 0, count: 4097)
    if fstatat(dfd, "command.json", &st, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return nil }
      throw Fail(m: "stat command.json")
    }
    let fd =
      st.st_mode & S_IFMT == S_IFREG && st.st_size <= 4096
      ? openat(dfd, "command.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK) : -1
    guard fd >= 0 else { throw Fail(m: "command.json not regular <= 4 KiB") }
    defer { close(fd) }
    let r = fstat(fd, &st) == 0 && st.st_mode & S_IFMT == S_IFREG ? read(fd, &b, 4097) : -1
    guard r >= 0, r <= 4096,
      let o = try? JSONSerialization.jsonObject(with: Data(b[..<r])) as? [String: Any]
    else { throw Fail(m: "bad command.json") }
    return o
  }

  func put(_ o: [String: Any]) -> Bool {
    guard let d = try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys) else {
      return false
    }
    unlinkat(dfd, "status.tmp", 0)
    let fd = openat(dfd, "status.tmp", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    if fd < 0 { return false }
    let ok = d.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == d.count && fsync(fd) == 0
    close(fd)
    return ok && renameat(dfd, "status.tmp", dfd, "status.json") == 0
  }

  func publish() {
    var o = snap()
    o["uptime"] = up
    if !put(o) && !ending { fail("status write failed") }
  }

  func snap() -> [String: Any] {
    let s = NSScreen.main
    let k = s?.backingScaleFactor ?? 0
    let sf = s?.frame ?? .zero
    let ph = NSScreen.screens.first?.frame.maxY ?? 0
    func r(_ f: NSRect, _ y: CGFloat) -> [CGFloat] { [f.minX, y, f.width, f.height] }
    let wins = ws.indices.map { i -> [String: Any] in
      let w = ws[i]
      let f = w.frame
      return [
        "index": i, "id": w.windowNumber, "closed": closed[i], "visible": w.isVisible,
        "minimized": w.isMiniaturized, "key": w.isKeyWindow,
        "fullscreen": w.styleMask.contains(.fullScreen), "frameNS": r(f, f.minY),
        "frameCG": r(f, ph - f.maxY),
      ]
    }
    return [
      "label": label, "pid": getpid(), "ready": ready, "actionSequence": acked, "error": err as Any,
      "reason": reason as Any,
      "stopped": ending, "appActive": NSApp.isActive, "fullscreenCheck": fsx, "motionCheck": mx,
      "backingScaleFactor": k, "screenLogicalFrame": r(sf, sf.minY),
      "screenPixelDimensions": [Int(sf.width * k), Int(sf.height * k)], "windows": wins,
    ]
  }

  func handle(_ c: [String: Any]) throws {
    guard Set(c.keys).isSubset(of: ["sequence", "action", "index"]), let q = int(c["sequence"]),
      q > 0, let a = c["action"] as? String,
      ["settle", "stop"].contains(a) == (c["index"] == nil)
    else { throw Fail(m: "malformed command") }
    if q <= acked {
      if q < acked { throw Fail(m: "sequence regressed") }
      return
    }
    if c["index"] == nil {
      acked = q
      publish()
      if a == "stop" { finish("stop", 0) }
      return
    }
    guard let i = int(c["index"]), ws.indices.contains(i), !closed[i] else {
      throw Fail(m: "bad or closed window")
    }
    let w = ws[i]
    switch a {
    case "focus":
      w.makeKeyAndOrderFront(nil)
      // Deliberate VM-only focus; see applicationDidFinishLaunching. Acked by check().
      NSApp.activate(ignoringOtherApps: true)
      settling = (q, up + 3, { NSApp.isActive && w.isKeyWindow }, "focus not granted")
      return
    case "move":
      moved[i].toggle()
      w.setFrame(target(i), display: true)
    case "resize":
      small[i].toggle()
      w.setFrame(target(i), display: true)
    case "minimize":
      settling = (q, up + 3, { w.isMiniaturized }, "minimize/restore did not settle")
      w.miniaturize(nil)
      return
    case "restore":
      settling = (q, up + 3, { !w.isMiniaturized }, "minimize/restore did not settle")
      w.deminiaturize(nil)
      return
    case "close":
      closed[i] = true
      w.close()
    case "fullscreen":
      fs = (q, i, !w.styleMask.contains(.fullScreen))
      w.toggleFullScreen(nil)
      _ = timer(1, false) { self.fsDone(q) }
      return
    case "animate":
      moved[i].toggle()
      an = (q, i, w.frame, target(i), 0, timer(1.0 / 30, true) { self.step() })
      return
    case "motion":
      let b = base[i]
      let (ax, ay) = amp(b)
      guard count == 1, i == 0, !w.isMiniaturized, !w.styleMask.contains(.fullScreen), ax > 0,
        ay > 0
      else { throw Fail(m: "motion needs one normal window with room") }
      let o = NSRect(
        x: vis.midX - b.width / 2, y: vis.midY - b.height / 2, width: b.width, height: b.height)
      moved[i] = false
      small[i] = false
      w.backgroundColor = NSColor(srgbRed: 0.1, green: 0.75, blue: 0.3, alpha: 1)
      w.setFrame(o, display: true)
      mo = (q, i, o, timer(1.0 / 60, true) { self.mstep() }, 0, up)
      return
    default: throw Fail(m: "unknown action")
    }
    acked = q
    publish()
  }

  func target(_ i: Int) -> NSRect {
    let b = base[i]
    let m: CGFloat = moved[i] ? 1 : 0
    let w = small[i] ? 540 : b.width
    let h = small[i] ? 360 : b.height
    return NSRect(
      x: min(max(b.minX + 120 * m, vis.minX), vis.maxX - w),
      y: min(max(b.maxY - h - 80 * m, vis.minY), vis.maxY - h), width: w, height: h)
  }

  func step() {
    guard var s = an else { return }
    s.n += 1
    an = s
    let p = CGFloat(s.n) / 90
    let o = NSPoint(
      x: s.a.minX + (s.b.minX - s.a.minX) * p, y: s.a.minY + (s.b.minY - s.a.minY) * p)
    ws[s.i].setFrame(NSRect(origin: o, size: s.b.size), display: true)
    if s.n >= 90 {
      s.t.invalidate()
      an = nil
      acked = s.q
      publish()
    }
  }

  // Motion amplitudes keep the centered frame at least 20 pt inside visibleFrame.
  func amp(_ r: NSRect) -> (CGFloat, CGFloat) {
    (min(240, (vis.width - r.width) / 2 - 20), min(60, (vis.height - r.height) / 2 - 20))
  }

  // 840 ticks at 60 Hz: 60 static, 720 sinusoidal (3 cycles), 60 static at the start frame.
  // Status is published only on completion, never per frame.
  func mstep() {
    guard var m = mo else { return }
    m.n += 1
    mo = m
    let (ax, ay) = amp(m.o)
    let k = m.n - 60
    let p: CGFloat = k > 0 && k < 720 ? CGFloat(sin(Double.pi * 6 * Double(k) / 720)) : 0
    ws[m.i].setFrame(m.o.offsetBy(dx: ax * p, dy: ay * p), display: true)
    if m.n >= 840 {
      m.t.invalidate()
      mo = nil
      mx = [
        "sequence": m.q, "ticks": m.n, "moving_ticks": 720, "elapsed_seconds": up - m.s,
        "requested_hz": 60,
      ]
      acked = m.q
      publish()
    }
  }

  func fsDone(_ q: Int) {
    guard let p = fs, p.q == q else { return }
    let got = ws[p.i].styleMask.contains(.fullScreen)
    fs = nil
    fsx = ["sequence": q, "expected": p.want, "actual": got]
    acked = q
    publish()
  }
  func windowDidEnterFullScreen(_ n: Notification) { fsDone(fs?.q ?? 0) }
  func windowDidExitFullScreen(_ n: Notification) { fsDone(fs?.q ?? 0) }
  func windowWillClose(_ n: Notification) {
    if let i = ws.firstIndex(where: { $0 == n.object as? NSWindow }) { closed[i] = true }
  }

  func fail(_ m: String) {
    err = m
    finish("error", 1)
  }
  func finish(_ why: String, _ c: Int32) {
    if ending { return }
    ending = true
    reason = why
    code = c
    fs = nil
    poll?.invalidate()
    an?.t.invalidate()
    mo?.t.invalidate()
    mo = nil
    ws.forEach { $0.close() }
    publish()
    NSApp.stop(nil)
    NSApp.postEvent(
      NSEvent.otherEvent(
        with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
  }

  func trap() {
    for s in [SIGTERM, SIGINT] {
      signal(s, SIG_IGN)
      let d = DispatchSource.makeSignalSource(signal: s, queue: .main)
      d.setEventHandler { MainActor.assumeIsolated { self.finish("signal", 3) } }
      d.resume()
      srcs.append(d)
    }
  }
  func timer(_ s: Double, _ r: Bool, _ f: @escaping @Sendable @MainActor () -> Void) -> Timer {
    let t = Timer(timeInterval: s, repeats: r) { _ in MainActor.assumeIsolated { f() } }
    RunLoop.main.add(t, forMode: .common)
    return t
  }
}
