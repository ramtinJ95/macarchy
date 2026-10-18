import Darwin
import Foundation
import ThemeCore

/// A small JSON record in `<state root>/run/`, beside the lock that serializes every access to it.
struct RunStateRecord<Value: Codable> {
  let name: String
  let directory: URL
  /// Decoded content that fails this check is not a record.
  let isValid: (Value) -> Bool

  init(_ name: String, stateRoot: URL, isValid: @escaping (Value) -> Bool) {
    self.name = name
    directory = stateRoot.appending(path: "run", directoryHint: .isDirectory)
    self.isValid = isValid
  }

  var url: URL { directory.appending(path: name) }

  /// nil when absent, larger than 4 KiB, or not a valid record.
  func read() throws -> Value? {
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
        return nil
      }
      guard let value = try? JSONDecoder().decode(Value.self, from: data), isValid(value) else {
        return nil
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
