import Foundation

/// Executable and configuration-file failures that adapters render the same way.
/// `subject` is the adapter's own wording, such as "bat" or "Yazi theme configuration".
enum AdapterConfigurationError: Error, CustomStringConvertible, Sendable {
  case controlUnavailable(String, URL)
  case cannotReadConfiguration(String, URL)
  case configurationTooLarge(String, URL)

  var description: String {
    switch self {
    case .controlUnavailable(let subject, let url):
      "\(subject) is not executable at \(url.path)"
    case .cannotReadConfiguration(let subject, let url):
      "Cannot read \(subject) at \(url.path)"
    case .configurationTooLarge(let subject, let url):
      "\(subject) at \(url.path) exceeds \(BoundedRegularFile.maximumSize / 1_048_576) MiB"
    }
  }
}
