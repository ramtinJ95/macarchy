import Darwin
import Foundation

package struct PinnedFilesystemError: Error, CustomStringConvertible, Sendable {
  package let operation: String
  package let url: URL
  package let code: Int32

  package init(operation: String, url: URL, code: Int32) {
    self.operation = operation
    self.url = url
    self.code = code
  }

  package var description: String {
    "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
  }
}

package enum PinnedFilesystem {
  package static func openDirectory(at url: URL) throws -> Int32 {
    let url = url.standardizedFileURL
    guard url.path.hasPrefix("/") else {
      throw PinnedFilesystemError(operation: "open non-absolute directory", url: url, code: EINVAL)
    }
    let components = url.path.split(separator: "/")
    let usesPrivateAlias = components.first.map { ["var", "tmp", "etc"].contains($0) } ?? false
    let startingPath = usesPrivateAlias ? "/private" : "/"
    var descriptor = Darwin.open(
      startingPath,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw PinnedFilesystemError(
        operation: "open filesystem root",
        url: URL(filePath: startingPath),
        code: errno
      )
    }
    var candidate = URL(filePath: startingPath, directoryHint: .isDirectory)
    for component in components {
      candidate.append(path: String(component), directoryHint: .isDirectory)
      let next = component.withCString {
        Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      }
      let code = errno
      Darwin.close(descriptor)
      guard next >= 0 else {
        throw PinnedFilesystemError(operation: "open pinned directory", url: candidate, code: code)
      }
      descriptor = next
    }
    return descriptor
  }

  package static func openDirectory(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> Int32 {
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw PinnedFilesystemError(operation: "open pinned directory", url: url, code: errno)
    }
    return descriptor
  }

  package static func createDirectory(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    mode: mode_t = 0o755
  ) throws -> Int32 {
    let result = name.withCString { Darwin.mkdirat(parentDescriptor, $0, mode) }
    guard result == 0 else {
      throw PinnedFilesystemError(operation: "create pinned directory", url: url, code: errno)
    }
    guard fsync(parentDescriptor) == 0 else {
      throw PinnedFilesystemError(operation: "sync pinned directory parent", url: url, code: errno)
    }
    return try openDirectory(parentDescriptor: parentDescriptor, name: name, url: url)
  }

  package static func metadata(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> stat {
    var metadata = stat()
    let result = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
      throw PinnedFilesystemError(operation: "inspect pinned item", url: url, code: errno)
    }
    return metadata
  }

  package static func symlinkDestination(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = name.withCString {
      Darwin.readlinkat(parentDescriptor, $0, &buffer, buffer.count - 1)
    }
    guard count >= 0 else {
      throw PinnedFilesystemError(operation: "read pinned symlink", url: url, code: errno)
    }
    let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    guard let destination = String(bytes: bytes, encoding: .utf8) else {
      throw PinnedFilesystemError(operation: "decode pinned symlink", url: url, code: EILSEQ)
    }
    return destination
  }

  package static func readRegularFile(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    maximumSize: Int = BoundedRegularFile.maximumSize
  ) throws -> BoundedRegularFile {
    let descriptor = name.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
      )
    }
    guard descriptor >= 0 else {
      throw PinnedFilesystemError(operation: "open pinned regular file", url: url, code: errno)
    }
    defer { Darwin.close(descriptor) }
    return try BoundedRegularFile.read(descriptor: descriptor, maximumSize: maximumSize)
  }

  package static func writeNewRegularFile(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    data: Data,
    mode: mode_t
  ) throws {
    let descriptor = name.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode
      )
    }
    guard descriptor >= 0 else {
      throw PinnedFilesystemError(operation: "create pinned regular file", url: url, code: errno)
    }
    defer { Darwin.close(descriptor) }
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { bytes in
        Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          data.count - offset
        )
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw PinnedFilesystemError(operation: "write pinned regular file", url: url, code: errno)
      }
      offset += count
    }
    guard fsync(descriptor) == 0 else {
      throw PinnedFilesystemError(operation: "sync pinned regular file", url: url, code: errno)
    }
  }

  package static func replaceRegularFileAtomically(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    data: Data,
    mode: mode_t
  ) throws {
    let temporaryName = ".\(name)-\(UUID().uuidString.lowercased())"
    let temporaryURL = url.deletingLastPathComponent().appending(path: temporaryName)
    try writeNewRegularFile(
      parentDescriptor: parentDescriptor,
      name: temporaryName,
      url: temporaryURL,
      data: data,
      mode: mode
    )
    var removeTemporary = true
    defer {
      if removeTemporary {
        temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
      }
    }
    let replaced = temporaryName.withCString { source in
      name.withCString { destination in
        Darwin.renameat(parentDescriptor, source, parentDescriptor, destination)
      }
    }
    guard replaced == 0 else {
      throw PinnedFilesystemError(operation: "replace pinned regular file", url: url, code: errno)
    }
    removeTemporary = false
    guard fsync(parentDescriptor) == 0 else {
      throw PinnedFilesystemError(operation: "sync replaced regular file", url: url, code: errno)
    }
  }

  package static func readRegularFile(
    at url: URL,
    maximumSize: Int = BoundedRegularFile.maximumSize
  ) throws -> BoundedRegularFile {
    let parent = try openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    return try readRegularFile(
      parentDescriptor: parent,
      name: url.lastPathComponent,
      url: url,
      maximumSize: maximumSize
    )
  }

  package static func directoryEntries(
    descriptor: Int32,
    url: URL,
    limit: Int
  ) throws -> (entries: [String], truncated: Bool) {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0 else {
      throw PinnedFilesystemError(operation: "duplicate pinned directory", url: url, code: errno)
    }
    guard let directory = fdopendir(duplicate) else {
      let code = errno
      Darwin.close(duplicate)
      throw PinnedFilesystemError(operation: "enumerate pinned directory", url: url, code: code)
    }
    defer { closedir(directory) }

    var entries: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        let code = errno
        guard code == 0 else {
          throw PinnedFilesystemError(operation: "enumerate pinned directory", url: url, code: code)
        }
        break
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      guard name != ".", name != ".." else { continue }
      if entries.count == limit {
        return (entries.sorted(), true)
      }
      entries.append(name)
    }
    return (entries.sorted(), false)
  }
}
