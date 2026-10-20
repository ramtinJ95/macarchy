import Darwin
import Foundation

enum CanonicalThemeLinkError: Error, CustomStringConvertible, Sendable {
  case absent(URL)
  case notSymbolicLink(URL)
  case wrongDestination(URL, expected: String)

  var description: String {
    switch self {
    case .absent(let url):
      "Theme link at \(url.path) does not exist"
    case .notSymbolicLink(let url):
      "Theme link at \(url.path) must be a symbolic link"
    case .wrongDestination(let url, let expected):
      "Theme link at \(url.path) must point to \(expected)"
    }
  }
}

struct CanonicalThemeLink: Sendable {
  let url: URL
  let destination: URL

  func validate() throws {
    let actual: String
    do {
      actual = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    } catch {
      var metadata = stat()
      if lstat(url.path, &metadata) != 0, errno == ENOENT {
        throw CanonicalThemeLinkError.absent(url)
      }
      throw CanonicalThemeLinkError.notSymbolicLink(url)
    }
    guard actual == destination.path else {
      throw CanonicalThemeLinkError.wrongDestination(url, expected: destination.path)
    }
  }

  /// Validates every link, then `checks`, and reports an absent link only after both pass.
  /// Activation tolerates `.absent`, so it must never hide a conflict or a later check.
  static func validate(
    _ links: [CanonicalThemeLink],
    then checks: () throws -> Void
  ) throws {
    var absent: URL?
    for link in links {
      do {
        try link.validate()
      } catch CanonicalThemeLinkError.absent(let url) {
        absent = absent ?? url
      }
    }
    try checks()
    if let absent { throw CanonicalThemeLinkError.absent(absent) }
  }
}
