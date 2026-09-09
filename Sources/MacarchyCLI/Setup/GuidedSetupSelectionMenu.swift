import Darwin
import Foundation
import ThemeCore

/// Interaction only: the ordinary profile compiler remains authoritative.
struct GuidedSetupSelectionMenu {
  let io: GuidedSetupIO
  let packages: [HomebrewPackageIdentity]

  private enum Setting {
    case flag(WritableKeyPath<GuidedSetupAnswers, Bool>)
    case preference(WritableKeyPath<GuidedSetupAnswers, Bool?>)
    case package(HomebrewPackageIdentity)
  }

  private var rows: [(String, Setting)] {
    [
      ("Desktop: yabai + skhd, tiling and default keybindings", .flag(\.desktop)),
      ("Top bar: SketchyBar", .flag(\.topBar)),
      ("Focus ring: Borders", .flag(\.focusRing)),
      ("Terminal: Kitty", .flag(\.terminal)),
      ("Shell: zsh", .flag(\.shell)),
      ("Prompt: Starship (requires shell)", .flag(\.prompt)),
      ("History: Atuin (requires shell)", .flag(\.history)),
      ("Editor: Neovim", .flag(\.editor)),
      ("Tool: bat", .flag(\.bat)),
      ("Tool: eza", .flag(\.eza)),
      ("Tool: btop", .flag(\.btop)),
      ("Tool: Yazi", .flag(\.yazi)),
      ("Preset: Codex", .flag(\.codex)),
      ("Preset: Herdr", .flag(\.herdr)),
      ("Preset: Pi (manual installation prerequisite)", .flag(\.pi)),
      ("Preset: Slack (manual theme import)", .flag(\.slack)),
      ("Preset: Spicetify (may restart Spotify)", .flag(\.spicetify)),
      ("Preset: tuicr", .flag(\.tuicr)),
      ("Native: Dock autohide", .preference(\.dockAutohide)),
      ("Native: Finder filename extensions", .preference(\.finderShowExtensions)),
    ] + packages.map { ("Package only: \($0.key)", .package($0)) }
  }

  func collect() throws -> GuidedSetupAnswers {
    var answers = GuidedSetupAnswers()
    var cursor = 0
    let rows = rows
    var notice = ""
    while true {
      let first = max(0, min(cursor - 5, rows.count - 10))
      io.write("\u{1B}[H\u{1B}[2JMacarchy setup — choose what to install and manage\n")
      io.write("Up/Down: move   Space: toggle   Enter: review   q/Ctrl-C: cancel\n")
      io.write("Native settings cycle: unmanaged -> true -> false.\n")
      io.write("Package-only choices do not enable presets; opt-outs never uninstall.\n\n")
      for index in first..<min(first + 10, rows.count) {
        let (title, setting) = rows[index]
        let state: String
        switch setting {
        case .flag(let key): state = answers[keyPath: key] ? "x" : " "
        case .preference(let key):
          state = answers[keyPath: key].map { $0 ? "true" : "false" } ?? "unmanaged"
        case .package(let identity):
          state = answers.packageExclusions.contains(identity) ? " " : "x"
        }
        io.write("\(index == cursor ? ">" : " ") [\(state)] \(title)\n")
      }
      io.write("\n\(cursor + 1)/\(rows.count)  \(notice)\n")
      guard let input = io.read() else { throw GuidedSetupError.inputClosed }
      notice = ""
      switch input {
      case "up": cursor = (cursor + rows.count - 1) % rows.count
      case "down": cursor = (cursor + 1) % rows.count
      case "", "enter": return answers
      case "q", "cancel": throw GuidedSetupError.inputClosed
      case " ":
        switch rows[cursor].1 {
        case .flag(let key):
          if !answers.shell && (key == \.prompt || key == \.history) {
            notice = "Enable the zsh shell first."
          } else {
            answers[keyPath: key].toggle()
            if key == \.shell {
              answers.prompt = answers.shell
              answers.history = answers.shell
              notice = "Prompt and history now follow the shell selection."
            }
          }
        case .preference(let key):
          switch answers[keyPath: key] {
          case nil: answers[keyPath: key] = true
          case true: answers[keyPath: key] = false
          case false: answers[keyPath: key] = nil
          }
        case .package(let identity):
          if answers.packageExclusions.contains(identity) {
            answers.packageExclusions.removeAll { $0 == identity }
          } else {
            answers.packageExclusions.append(identity)
          }
        }
      default: notice = "Use Up/Down, Space, Enter or q."
      }
    }
  }
}

enum GuidedSetupTerminal {
  static func collect(packages: [HomebrewPackageIdentity]) throws -> GuidedSetupAnswers {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
      ProcessInfo.processInfo.environment["TERM"] != "dumb"
    else { throw GuidedSetupError.terminalUnavailable }
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw GuidedSetupError.terminalUnavailable
    }
    var mode = original
    cfmakeraw(&mode)
    mode.c_oflag = original.c_oflag
    guard tcsetattr(STDIN_FILENO, TCSANOW, &mode) == 0 else {
      throw GuidedSetupError.terminalUnavailable
    }
    let write: @Sendable (String) -> Void = {
      FileHandle.standardOutput.write(Data($0.utf8))
    }
    write("\u{1B}[?1049h\u{1B}[?25l")
    defer {
      tcsetattr(STDIN_FILENO, TCSANOW, &original)
      write("\u{1B}[?25h\u{1B}[?1049l")
    }
    return try GuidedSetupSelectionMenu(
      io: .init(read: readKey, write: write), packages: packages
    ).collect()
  }

  private static func readByte() -> UInt8? {
    var byte: UInt8 = 0
    return Darwin.read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
  }

  private static func escapeByte() -> UInt8? {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 100) > 0 else { return nil }
    return readByte()
  }

  private static func readKey() -> String? {
    guard let byte = readByte() else { return nil }
    switch byte {
    case 3, 4, 113: return "cancel"
    case 10, 13: return "enter"
    case 32: return " "
    case 107: return "up"
    case 106: return "down"
    case 27:
      guard let prefix = escapeByte(), prefix == 91 || prefix == 79,
        let direction = escapeByte()
      else { return "unknown" }
      return direction == 65 ? "up" : direction == 66 ? "down" : "unknown"
    default: return "unknown"
    }
  }
}
