import Foundation

/// A file at a path the user chose, which Macarchy creates and never replaces.
enum NewFile {
  /// Why the path cannot take a new file.
  enum Refusal: Equatable {
    /// Something has the name already, even a dangling link.
    case exists
    /// The parent folder is missing or not a folder.
    case missingParent(URL)
  }

  /// The path must name nothing yet inside an existing folder. A file can still appear after
  /// this check, so the final write must be exclusive too.
  static func refusal(at url: URL) -> Refusal? {
    if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil { return .exists }
    let parent = url.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return .missingParent(parent) }
    return nil
  }
}
