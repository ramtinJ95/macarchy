import Foundation

enum CanonicalThemeLinkError: Error, CustomStringConvertible, Sendable {
  case notSymbolicLink(URL)
  case wrongDestination(URL, expected: String)

  var description: String {
    switch self {
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
      throw CanonicalThemeLinkError.notSymbolicLink(url)
    }
    guard actual == destination.path else {
      throw CanonicalThemeLinkError.wrongDestination(url, expected: destination.path)
    }
  }
}
