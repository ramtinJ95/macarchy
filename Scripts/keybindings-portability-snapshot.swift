import CryptoKit
import Darwin
import Foundation

private let maximumEntries = 256
private let maximumDepth = 16
private let maximumPathBytes = 1_024
private let maximumRegularBytes = 16 * 1_024 * 1_024

private struct SnapshotEntry: Encodable {
  let path: String
  let type: String
  let mode: UInt16
  let digest: String?
}

private enum SnapshotError: Error, CustomStringConvertible {
  case invalidArguments
  case pathTooLong(String)
  case tooDeep(String)
  case tooManyEntries
  case tooMuchRegularData
  case unsafeEntry(String)
  case changedEntry(String)
  case system(String, Int32)

  var description: String {
    switch self {
    case .invalidArguments:
      "usage: keybindings-portability-snapshot <directory>"
    case .pathTooLong(let path):
      "snapshot path exceeds 1024 bytes: \(path)"
    case .tooDeep(let path):
      "snapshot inventory exceeds 16 levels: \(path)"
    case .tooManyEntries:
      "snapshot inventory exceeds 256 entries"
    case .tooMuchRegularData:
      "snapshot regular data exceeds \(maximumRegularBytes) bytes"
    case .unsafeEntry(let path):
      "snapshot entry is not a pinned regular file or directory: \(path)"
    case .changedEntry(let path):
      "snapshot entry changed during collection: \(path)"
    case .system(let operation, let code):
      "\(operation): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}

private struct Snapshot {
  var entries: [SnapshotEntry] = []
  var regularBytes = 0

  mutating func collect(root: String) throws {
    let descriptor = try openDirectory(root)
    defer { Darwin.close(descriptor) }
    try visit(descriptor: descriptor, path: ".", depth: 0, parent: nil, name: nil)
  }

  private mutating func visit(
    descriptor: Int32,
    path: String,
    depth: Int,
    parent: Int32?,
    name: String?
  ) throws {
    guard path.utf8.count <= maximumPathBytes else {
      throw SnapshotError.pathTooLong(path)
    }
    guard entries.count < maximumEntries else {
      // Observe only the 257th entry needed to prove overflow.
      throw SnapshotError.tooManyEntries
    }

    let initial = try metadata(descriptor, operation: "inspect pinned entry \(path)")
    let mode = UInt16(initial.st_mode & 0o7777)
    switch initial.st_mode & S_IFMT {
    case S_IFDIR:
      entries.append(SnapshotEntry(path: path, type: "directory", mode: mode, digest: nil))
      guard depth < maximumDepth else {
        if try directoryHasEntry(descriptor: descriptor, path: path) {
          throw SnapshotError.tooDeep(path)
        }
        return
      }
      try visitChildren(descriptor: descriptor, path: path, depth: depth)
    case S_IFREG:
      let data = try readRegularFile(descriptor: descriptor, path: path, metadata: initial)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      entries.append(SnapshotEntry(path: path, type: "regular", mode: mode, digest: digest))
    default:
      throw SnapshotError.unsafeEntry(path)
    }

    let final = try metadata(descriptor, operation: "reinspect pinned entry \(path)")
    guard unchanged(initial, final) else {
      throw SnapshotError.changedEntry(path)
    }
    if let parent, let name {
      var current = stat()
      let result = name.withCString {
        Darwin.fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW)
      }
      guard result == 0, sameIdentity(initial, current) else {
        throw SnapshotError.changedEntry(path)
      }
    }
  }

  private mutating func visitChildren(descriptor: Int32, path: String, depth: Int) throws {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0 else {
      throw SnapshotError.system("duplicate pinned directory \(path)", errno)
    }
    guard let directory = fdopendir(duplicate) else {
      let code = errno
      Darwin.close(duplicate)
      throw SnapshotError.system("enumerate pinned directory \(path)", code)
    }
    defer { closedir(directory) }

    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else {
          throw SnapshotError.system("enumerate pinned directory \(path)", errno)
        }
        return
      }
      guard let name = directoryEntryName(entry) else {
        throw SnapshotError.unsafeEntry(path)
      }
      guard name != ".", name != ".." else { continue }
      guard entries.count < maximumEntries else {
        throw SnapshotError.tooManyEntries
      }

      let childPath = path == "." ? name : "\(path)/\(name)"
      let child = name.withCString {
        Darwin.openat(
          descriptor,
          $0,
          O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
      }
      guard child >= 0 else {
        throw SnapshotError.unsafeEntry(childPath)
      }
      do {
        defer { Darwin.close(child) }
        try visit(
          descriptor: child,
          path: childPath,
          depth: depth + 1,
          parent: descriptor,
          name: name
        )
      }
    }
  }

  private mutating func readRegularFile(
    descriptor: Int32,
    path: String,
    metadata: stat
  ) throws -> Data {
    guard metadata.st_size >= 0 else {
      throw SnapshotError.unsafeEntry(path)
    }
    let remaining = maximumRegularBytes - regularBytes
    guard metadata.st_size <= remaining else {
      throw SnapshotError.tooMuchRegularData
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while data.count <= remaining {
      let readSize = min(buffer.count, remaining + 1 - data.count)
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, readSize)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw SnapshotError.system("read pinned regular file \(path)", errno)
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count <= remaining else {
      throw SnapshotError.tooMuchRegularData
    }
    guard data.count == metadata.st_size else {
      throw SnapshotError.changedEntry(path)
    }
    regularBytes += data.count
    return data
  }

  private func directoryHasEntry(descriptor: Int32, path: String) throws -> Bool {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0 else {
      throw SnapshotError.system("duplicate pinned directory \(path)", errno)
    }
    guard let directory = fdopendir(duplicate) else {
      let code = errno
      Darwin.close(duplicate)
      throw SnapshotError.system("enumerate pinned directory \(path)", code)
    }
    defer { closedir(directory) }
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else {
          throw SnapshotError.system("enumerate pinned directory \(path)", errno)
        }
        return false
      }
      guard let name = directoryEntryName(entry) else {
        throw SnapshotError.unsafeEntry(path)
      }
      if name != ".", name != ".." { return true }
    }
  }
}

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String? {
  withUnsafePointer(to: entry.pointee.d_name) { pointer in
    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
      String(validatingCString: $0)
    }
  }
}

private func openDirectory(_ path: String) throws -> Int32 {
  let absolute = URL(filePath: path).standardizedFileURL.path
  guard absolute.hasPrefix("/") else {
    throw SnapshotError.invalidArguments
  }
  let components = absolute.split(separator: "/")
  let usesPrivateAlias = components.first.map { ["var", "tmp", "etc"].contains($0) } ?? false
  let startingPath = usesPrivateAlias ? "/private" : "/"
  var descriptor = Darwin.open(
    startingPath,
    O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
  )
  guard descriptor >= 0 else {
    throw SnapshotError.system("open filesystem root", errno)
  }
  for component in components {
    let next = component.withCString {
      Darwin.openat(
        descriptor,
        $0,
        O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
      )
    }
    let code = errno
    Darwin.close(descriptor)
    guard next >= 0 else {
      throw SnapshotError.system("open pinned snapshot root", code)
    }
    descriptor = next
  }
  return descriptor
}

private func metadata(_ descriptor: Int32, operation: String) throws -> stat {
  var value = stat()
  guard fstat(descriptor, &value) == 0 else {
    throw SnapshotError.system(operation, errno)
  }
  return value
}

private func sameIdentity(_ left: stat, _ right: stat) -> Bool {
  left.st_dev == right.st_dev
    && left.st_ino == right.st_ino
    && left.st_mode & S_IFMT == right.st_mode & S_IFMT
}

private func unchanged(_ left: stat, _ right: stat) -> Bool {
  sameIdentity(left, right)
    && left.st_mode == right.st_mode
    && left.st_size == right.st_size
    && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
    && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
    && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
    && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
}

do {
  guard CommandLine.arguments.count == 2 else {
    throw SnapshotError.invalidArguments
  }
  var snapshot = Snapshot()
  try snapshot.collect(root: CommandLine.arguments[1])
  guard !snapshot.entries.isEmpty else {
    throw SnapshotError.unsafeEntry(".")
  }
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  // Collection is capped before this deterministic sort.
  let output = try encoder.encode(snapshot.entries.sorted { $0.path < $1.path })
  FileHandle.standardOutput.write(output)
  FileHandle.standardOutput.write(Data([0x0a]))
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
