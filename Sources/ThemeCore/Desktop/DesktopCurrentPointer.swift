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
    guard metadata.st_mode & S_IFMT == S_IFLNK, let target = SymbolicLink.target(of: current) else {
      return .invalid("current is not a readable symbolic link")
    }
    guard target.hasPrefix(StateLayout.generationPath("")) else {
      return .invalid("current target is outside the \(label) generation inventory")
    }
    guard
      let generationID = StateLayout.generationID(fromPath: target, isGenerationID: isGenerationID)
    else {
      return .invalid("current target has an invalid generation identity")
    }
    return .generation(generationID)
  }
}
