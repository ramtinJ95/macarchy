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
}
