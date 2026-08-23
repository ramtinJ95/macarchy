import Darwin
import Foundation

struct BoundedRegularFile {
  static let maximumSize = 1_048_576

  let data: Data
  let permissions: Int

  static func read(at url: URL, maximumSize: Int = maximumSize) throws -> Self {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw BoundedRegularFileError.system(operation: "open", code: errno)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw BoundedRegularFileError.system(operation: "fstat", code: errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw BoundedRegularFileError.notRegular
    }
    guard metadata.st_size >= 0, metadata.st_size <= maximumSize else {
      throw BoundedRegularFileError.tooLarge(maximumSize)
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count <= maximumSize {
      let remaining = min(buffer.count, maximumSize + 1 - data.count)
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, remaining)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw BoundedRegularFileError.system(operation: "read", code: errno)
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count <= maximumSize else {
      throw BoundedRegularFileError.tooLarge(maximumSize)
    }
    return Self(data: data, permissions: Int(metadata.st_mode & 0o777))
  }
}

enum BoundedRegularFileError: Error, CustomStringConvertible, Equatable, Sendable {
  case notRegular
  case system(operation: String, code: Int32)
  case tooLarge(Int)

  var description: String {
    switch self {
    case .notRegular:
      "not a regular file"
    case .system(let operation, let code):
      "\(operation) failed (errno \(code)): \(String(cString: strerror(code)))"
    case .tooLarge(let maximumSize):
      "exceeds the \(maximumSize / 1_048_576) MiB file limit"
    }
  }
}
