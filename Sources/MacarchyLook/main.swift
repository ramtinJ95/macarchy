import Darwin
import Foundation

// This executable alone calls the private AppKit accent-color functions. Neither ThemeCore nor
// the main CLI links or loads them; `macarchy` runs this helper as a child process, so a crash
// here cannot take the CLI down. Every command prints one JSON object on standard output:
// `{"ok":true,"value":…}` with exit status 0, or `{"ok":false,"error":"…"}` with status 1.
//
//   macarchy-look check           which controls resolve on this macOS, and its build
//   macarchy-look get accent      the stored accent preset
//   macarchy-look set accent N    sets preset N, reads it back, and reverts on a mismatch
//
// Accent presets: -2 multicolor, -1 graphite, 0 red, 1 orange, 2 yellow, 3 green, 4 blue,
// 5 purple, 6 pink. -3, the hardware-matched color of some Macs, is reported but never set.
// The approach follows Scene (MIT, Copyright (c) 2026 InsaneArts), see THIRD_PARTY_NOTICES.md.

enum Accent {
  typealias Getter = @convention(c) () -> Int
  typealias Setter = @convention(c) (Int, Bool) -> Void

  static let settable = -2...6
  /// How long the setter is given before the stored value is read back.
  static let settleMicroseconds: useconds_t = 150_000

  struct Functions {
    let get: Getter
    let set: Setter
  }

  /// The two private AppKit functions, or nil when either is missing on this macOS.
  static func resolve() -> Functions? {
    guard
      let appKit = dlopen(
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", RTLD_NOW | RTLD_LOCAL),
      let get = dlsym(appKit, "NSColorGetUserAccentColor"),
      let set = dlsym(appKit, "NSColorSetUserAccentColor")
    else { return nil }
    // AppKit stays loaded for the life of this short process.
    return Functions(
      get: unsafeBitCast(get, to: Getter.self), set: unsafeBitCast(set, to: Setter.self))
  }

  /// The stored preset, read fresh: the getter caches its value inside this process, and an
  /// absent key is what the getter reports for it.
  static func stored(_ functions: Functions) -> Int {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    if let value = CFPreferencesCopyAppValue(
      "AppleAccentColor" as CFString, kCFPreferencesAnyApplication) as? Int
    {
      return value
    }
    return functions.get()
  }

  static func set(_ value: Int, _ functions: Functions) throws(HelperFailure) -> Int {
    guard settable.contains(value) else {
      throw HelperFailure(
        "accent must be between \(settable.lowerBound) and \(settable.upperBound)")
    }
    let before = stored(functions)
    // System Settings passes true as the second argument.
    functions.set(value, true)
    usleep(settleMicroseconds)
    let after = stored(functions)
    guard after == value else {
      functions.set(before, true)
      usleep(settleMicroseconds)
      let restored = stored(functions)
      throw HelperFailure(
        restored == before
          ? "accent read back \(after), expected \(value); reverted to \(before)"
          : "accent read back \(after), expected \(value); reverting to \(before) read back \(restored)"
      )
    }
    return after
  }
}

struct HelperFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }

  static let unavailable = HelperFailure("the accent color functions are unavailable on this macOS")
}

/// The macOS build, such as 25G83.
func buildVersion() -> String? {
  var size = 0
  guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
  var buffer = [CChar](repeating: 0, count: size)
  guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
  return String(cString: buffer)
}

func run(_ arguments: [String]) throws(HelperFailure) -> Any {
  switch arguments {
  case ["check"]:
    guard let build = buildVersion() else { throw HelperFailure("cannot read the macOS build") }
    return ["build": build, "accent": Accent.resolve() != nil]
  case ["get", "accent"]:
    guard let functions = Accent.resolve() else { throw .unavailable }
    return Accent.stored(functions)
  case let command where command.count == 3 && command[0] == "set" && command[1] == "accent":
    guard let value = Int(command[2]) else { throw HelperFailure("accent must be an integer") }
    guard let functions = Accent.resolve() else { throw .unavailable }
    return try Accent.set(value, functions)
  default:
    throw HelperFailure("usage: macarchy-look check | get accent | set accent <preset>")
  }
}

func emit(_ object: [String: Any]) {
  let data =
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    ?? Data(#"{"ok":false,"error":"cannot encode the result"}"#.utf8)
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

do {
  let value = try run(Array(CommandLine.arguments.dropFirst()))
  emit(["ok": true, "value": value])
  exit(0)
} catch {
  emit(["ok": false, "error": error.message])
  exit(1)
}
