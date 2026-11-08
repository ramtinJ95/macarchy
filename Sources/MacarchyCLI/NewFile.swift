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

  /// Writes `data` exclusively, so a file that appeared after `refusal(at:)` is never replaced.
  /// Returns false when something already has the name; any other failure throws.
  static func write(_ data: Data, to url: URL) throws -> Bool {
    do {
      try data.write(to: url, options: .withoutOverwriting)
      return true
    } catch let error where alreadyExists(error) {
      return false
    }
  }

  /// Foundation reports EEXIST as a Cocoa error, possibly wrapping the POSIX one.
  private static func alreadyExists(_ error: any Error) -> Bool {
    let failure = error as NSError
    if failure.domain == NSCocoaErrorDomain,
      failure.code == CocoaError.fileWriteFileExists.rawValue
    {
      return true
    }
    let errors: [NSError?] = [failure, failure.userInfo[NSUnderlyingErrorKey] as? NSError]
    return errors.contains { $0?.domain == NSPOSIXErrorDomain && $0?.code == Int(EEXIST) }
  }
}
