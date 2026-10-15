import Darwin
import Foundation

/// Path-based symbolic-link reads for callers that inspect a link rather than pin it.
package enum SymbolicLink {
  /// The link target, decoded as UTF-8 with replacement, or nil when `url` is not a readable link.
  package static func target(of url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(url.path, &buffer, buffer.count - 1)
    guard count >= 0 else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  /// `target` resolved against the directory that contains `link`.
  package static func resolve(_ target: String, at link: URL) -> URL {
    if target.hasPrefix("/") { return URL(filePath: target).standardizedFileURL }
    return link.deletingLastPathComponent().appending(path: target).standardizedFileURL
  }
}
