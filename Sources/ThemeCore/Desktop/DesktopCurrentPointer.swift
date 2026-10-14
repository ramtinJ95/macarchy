import Darwin
import Foundation

/// What a desktop provider's `current` symbolic link selects.
enum DesktopCurrentPointer {
  case missing
  case invalid(String)
  case generation(String)

  /// `label` names the provider in the out-of-inventory message.
  static func read(
    providerRoot: URL, label: String, isGenerationID: (String) -> Bool
  ) -> Self {
    let current = providerRoot.appending(path: "current")
    var metadata = stat()
    guard lstat(current.path, &metadata) == 0 else {
      return errno == ENOENT
        ? .missing
        : .invalid("cannot inspect current pointer: \(errnoDescription(errno))")
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK, let target = readLink(current) else {
      return .invalid("current is not a readable symbolic link")
    }
    let prefix = "generations/"
    guard target.hasPrefix(prefix) else {
      return .invalid("current target is outside the \(label) generation inventory")
    }
    let generationID = String(target.dropFirst(prefix.count))
    guard isGenerationID(generationID), !generationID.contains("/") else {
      return .invalid("current target has an invalid generation identity")
    }
    return .generation(generationID)
  }

  private static func readLink(_ url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(url.path, &buffer, buffer.count - 1)
    guard count >= 0 else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }
}
