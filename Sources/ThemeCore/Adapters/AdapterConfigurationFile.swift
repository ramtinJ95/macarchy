import Foundation

enum AdapterConfigurationFile {
  static func readUTF8<AdapterError: Error>(
    at url: URL,
    tooLarge: @autoclosure () -> AdapterError,
    unreadable: @autoclosure () -> AdapterError
  ) throws -> String {
    do {
      return try BoundedRegularFile.readUTF8(at: url)
    } catch BoundedRegularFileError.tooLarge {
      throw tooLarge()
    } catch {
      throw unreadable()
    }
  }

  /// Reads a consumer configuration that is either an ordinary file or the
  /// exact Macarchy-managed leaf link the environment installs at `url`.
  ///
  /// Only a symbolic link whose destination equals `managedDestination.path`
  /// is followed, and the destination itself is still opened without following
  /// its final component. Every other symbolic link is rejected through
  /// `unexpectedLink` so arbitrary redirection stays visible.
  static func readUTF8<AdapterError: Error>(
    at url: URL,
    managedDestination: URL,
    tooLarge: @autoclosure () -> AdapterError,
    unreadable: @autoclosure () -> AdapterError,
    unexpectedLink: (_ actualDestination: String) -> AdapterError
  ) throws -> String {
    guard let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    else {
      return try readUTF8(at: url, tooLarge: tooLarge(), unreadable: unreadable())
    }
    guard actual == managedDestination.path else {
      throw unexpectedLink(actual)
    }
    return try readUTF8(at: managedDestination, tooLarge: tooLarge(), unreadable: unreadable())
  }
}
