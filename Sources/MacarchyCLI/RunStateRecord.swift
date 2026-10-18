import Darwin
import Foundation
import ThemeCore

/// A small JSON record under `<state root>/run/`. Callers serialize access to it, with the lock
/// beside it or by giving each concurrent writer its own record.
struct RunStateRecord<Value: Codable> {
  let name: String
  let directory: URL
  /// Decoded content that fails this check is not a record.
  let isValid: (Value) -> Bool

  init(_ name: String, stateRoot: URL, isValid: @escaping (Value) -> Bool) {
    self.init(
      name, directory: stateRoot.appending(path: "run", directoryHint: .isDirectory),
      isValid: isValid)
  }

  /// A record in `directory`, which its owner creates.
  init(_ name: String, directory: URL, isValid: @escaping (Value) -> Bool) {
    self.name = name
    self.directory = directory
    self.isValid = isValid
  }

  var url: URL { directory.appending(path: name) }

  /// nil when absent, larger than 4 KiB, or not a valid record.
  func read() throws -> Value? {
    do {
      return try readStrictly()
    } catch is InvalidRunStateRecord {
      return nil
    }
  }

  /// nil only when absent. Content larger than 4 KiB or not a valid record throws
  /// `InvalidRunStateRecord`, for a record whose loss must not pass unnoticed.
  func readStrictly() throws -> Value? {
    try withDirectory { parent in
      let data: Data
      do {
        data =
          try PinnedFilesystem.readRegularFile(
            parentDescriptor: parent, name: name, url: url, maximumSize: 4096
          ).data
      } catch let error as PinnedFilesystemError where error.code == ENOENT {
        return nil
      } catch BoundedRegularFileError.tooLarge {
        throw InvalidRunStateRecord(url: url)
      }
      guard let value = try? JSONDecoder().decode(Value.self, from: data), isValid(value) else {
        throw InvalidRunStateRecord(url: url)
      }
      return value
    }
  }

  func write(_ value: Value) throws {
    try withDirectory {
      try PinnedStateFile.write(value, parentDescriptor: $0, name: name, url: url)
    }
  }

  func remove() throws {
    try withDirectory { parent in
      guard
        let failure = PinnedStateFile.remove(name, parentDescriptor: parent, syncWhenAbsent: false)
      else { return }
      throw PinnedFilesystemError(
        operation: failure.step == .unlink ? "remove" : "sync the removal of", url: url,
        code: failure.code)
    }
  }

  private func withDirectory<Output>(_ body: (Int32) throws -> Output) throws -> Output {
    let parent = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(parent) }
    return try body(parent)
  }
}

struct InvalidRunStateRecord: Error, CustomStringConvertible {
  let url: URL

  var description: String { "\(url.path) is not a valid record" }
}
