import Darwin
import Foundation
import ThemeCore

/// The inert text the saver animates. It only ever reaches ttfx's standard input, never a shell
/// or an argument.
enum SaverText: Equatable, Sendable {
  case custom(String)
  /// `rejected` says why the custom text file was not used; nil when there is none.
  case banner(rejected: String?)

  static let maximumSize = 64 * 1024

  static let bannerText = #"""
     __  __                                  _
    |  \/  |  __ _   ___   __ _  _ __   ___ | |__   _   _
    | |\/| | / _` | / __| / _` || '__| / __|| '_ \ | | | |
    | |  | || (_| || (__ | (_| || |   | (__ | | | || |_| |
    |_|  |_| \__,_| \___| \__,_||_|    \___||_| |_| \__, |
                                                    |___/
    """#

  var content: String {
    switch self {
    case .custom(let text): text
    case .banner: Self.bannerText
    }
  }

  /// Why the custom text file is not shown, when it exists but cannot be used.
  func notice(textFile: URL) -> String? {
    guard case .banner(let rejected?) = self else { return nil }
    return "Showing the Macarchy banner: \(textFile.path) is not used because \(rejected)."
  }

  /// `<state root>/screensaver.txt`, which is `~/.config/macarchy/screensaver.txt` by default.
  static func fileURL(stateRoot: URL) -> URL {
    stateRoot.appending(path: "screensaver.txt")
  }

  /// Valid UTF-8 with control characters other than newline and tab removed, or the banner and
  /// the reason the file was not used.
  static func choose(_ file: SaverTextFile) -> Self {
    let data: Data
    switch file {
    case .absent: return .banner(rejected: nil)
    case .symbolicLink: return .banner(rejected: "it is a symbolic link")
    case .notRegularFile: return .banner(rejected: "it is not a regular file")
    case .tooLarge: return .banner(rejected: "it is larger than 64 KiB")
    case .unreadable(let reason): return .banner(rejected: "it cannot be read (\(reason))")
    case .contents(let contents): data = contents
    }
    guard let text = String(data: data, encoding: .utf8) else {
      return .banner(rejected: "it is not valid UTF-8")
    }
    let scalars = text.unicodeScalars.filter {
      $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
    }
    let visible = String(String.UnicodeScalarView(scalars))
    guard !visible.allSatisfy(\.isWhitespace) else {
      return .banner(rejected: "it contains no visible text")
    }
    return .custom(visible)
  }

  /// Reads `url` without following a symbolic link, up to `maximumSize` bytes.
  static func read(_ url: URL) -> SaverTextFile {
    do {
      return .contents(try PinnedFilesystem.readRegularFile(at: url, maximumSize: maximumSize).data)
    } catch let error as PinnedFilesystemError where [ENOENT, ENOTDIR].contains(error.code) {
      return .absent
    } catch let error as PinnedFilesystemError where error.code == ELOOP {
      return .symbolicLink
    } catch BoundedRegularFileError.notRegular {
      return .notRegularFile
    } catch BoundedRegularFileError.tooLarge {
      return .tooLarge
    } catch {
      return .unreadable(String(describing: error))
    }
  }
}

/// What reading the custom text file found.
enum SaverTextFile: Equatable, Sendable {
  case absent
  case symbolicLink
  case notRegularFile
  case tooLarge
  case unreadable(String)
  case contents(Data)
}
