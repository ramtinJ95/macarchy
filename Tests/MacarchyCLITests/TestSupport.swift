import Darwin
import Foundation
import Testing

let repositoryRoot = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

func jsonObject(_ output: String) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}

func fixtureContents(_ path: String) throws -> String {
  try String(
    contentsOf: repositoryRoot.appending(path: "Tests/Fixtures/\(path)"),
    encoding: .utf8
  )
}

func setExtendedAttribute(_ name: String, value: String, at url: URL) throws {
  try setExtendedAttribute(name, data: Data(value.utf8), at: url)
}

func setExtendedAttribute(_ name: String, data: Data, at url: URL) throws {
  let result = data.withUnsafeBytes { bytes in
    url.path.withCString { path in
      name.withCString { attribute in
        Darwin.setxattr(path, attribute, bytes.baseAddress, bytes.count, 0, 0)
      }
    }
  }
  guard result == 0 else { throw posixError() }
}

func setSymbolicLinkExtendedAttribute(_ name: String, value: String, at url: URL) throws {
  try setSymbolicLinkExtendedAttribute(name, data: Data(value.utf8), at: url)
}

func setSymbolicLinkExtendedAttribute(_ name: String, data: Data, at url: URL) throws {
  try withNoFollowDescriptor(at: url, symbolicLink: true) { descriptor in
    let result = data.withUnsafeBytes { bytes in
      name.withCString {
        Darwin.fsetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, XATTR_CREATE)
      }
    }
    guard result == 0 else { throw posixError() }
  }
}

func removeExtendedAttribute(_ name: String, at url: URL, symbolicLink: Bool) throws {
  try withNoFollowDescriptor(at: url, symbolicLink: symbolicLink) { descriptor in
    let result = name.withCString { Darwin.fremovexattr(descriptor, $0, 0) }
    guard result == 0 else { throw posixError() }
  }
}

func extendedAttribute(_ name: String, at url: URL) throws -> String {
  let size = url.path.withCString { path in
    name.withCString { Darwin.getxattr(path, $0, nil, 0, 0, 0) }
  }
  guard size >= 0 else { throw posixError() }
  var data = Data(count: size)
  let count = data.withUnsafeMutableBytes { bytes in
    url.path.withCString { path in
      name.withCString { Darwin.getxattr(path, $0, bytes.baseAddress, bytes.count, 0, 0) }
    }
  }
  guard count == size else { throw posixError() }
  return String(decoding: data, as: UTF8.self)
}

func symbolicLinkExtendedAttribute(_ name: String, at url: URL) throws -> String {
  try withNoFollowDescriptor(at: url, symbolicLink: true) { descriptor in
    let size = try extendedAttributeSize(name, descriptor: descriptor)
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes { bytes in
      name.withCString {
        Darwin.fgetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
      }
    }
    guard count == size else { throw posixError() }
    return String(decoding: data, as: UTF8.self)
  }
}

func symbolicLinkExtendedAttributeSize(_ name: String, at url: URL) throws -> Int {
  try withNoFollowDescriptor(at: url, symbolicLink: true) {
    try extendedAttributeSize(name, descriptor: $0)
  }
}

func extendedAttributeNames(at url: URL) throws -> [String] {
  let size = url.path.withCString { Darwin.listxattr($0, nil, 0, 0) }
  guard size >= 0 else { throw posixError() }
  var names = [CChar](repeating: 0, count: size)
  let count = url.path.withCString { Darwin.listxattr($0, &names, names.count, 0) }
  guard count == size else { throw posixError() }
  return names.prefix(count).map { UInt8(bitPattern: $0) }.split(separator: 0).map {
    String(decoding: $0, as: UTF8.self)
  }
}

func extendedAttributeAggregateSize(at url: URL) throws -> Int {
  let names = try extendedAttributeNames(at: url)
  return try names.reduce(names.reduce(0) { $0 + $1.utf8.count + 1 }) { total, name in
    let size = url.path.withCString { path in
      name.withCString { Darwin.getxattr(path, $0, nil, 0, 0, 0) }
    }
    guard size >= 0 else { throw posixError() }
    return total + size
  }
}

private func withNoFollowDescriptor<Result>(
  at url: URL,
  symbolicLink: Bool,
  _ body: (Int32) throws -> Result
) throws -> Result {
  let descriptor = url.path.withCString {
    Darwin.open($0, O_RDONLY | (symbolicLink ? O_SYMLINK : O_NOFOLLOW) | O_CLOEXEC)
  }
  guard descriptor >= 0 else { throw posixError() }
  defer { Darwin.close(descriptor) }
  return try body(descriptor)
}

private func extendedAttributeSize(_ name: String, descriptor: Int32) throws -> Int {
  let size = name.withCString { Darwin.fgetxattr(descriptor, $0, nil, 0, 0, 0) }
  guard size >= 0 else { throw posixError() }
  return size
}

private func posixError() -> POSIXError {
  POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
