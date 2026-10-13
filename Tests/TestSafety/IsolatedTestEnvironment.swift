import Darwin
import Foundation

/// Test-only boundary. An environment variable alone must never authorize host FIFOs.
public enum IsolatedTestEnvironment {
  public struct Refusal: Error, CustomStringConvertible {
    public let description: String

    init(_ reason: String) {
      description =
        "Unsafe filesystem test refused: \(reason). "
        + "Run inside a disposable macOS VM with MACARCHY_TEST_VM=1; "
        + "do not disable endpoint security or skip this coverage."
    }
  }

  private static let authorization: Result<Void, Error> = Result {
    var virtualized: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.hv_vmm_present", &virtualized, &size, nil, 0) == 0 else {
      throw Refusal("cannot establish virtual-machine identity")
    }
    // Refuse the physical host before invoking any other inspection or fixture work.
    try validateGuest(
      optedIn: ProcessInfo.processInfo.environment["MACARCHY_TEST_VM"] == "1",
      virtualized: virtualized,
      extensions: ""
    )
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/systemextensionsctl")
    process.arguments = ["list"]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let extensions = String(data: data, encoding: .utf8)
    else { throw Refusal("cannot inspect guest security extensions") }
    try validateGuest(optedIn: true, virtualized: virtualized, extensions: extensions)
  }

  public static func requireGuest() throws {
    try authorization.get()
  }

  static func validateGuest(optedIn: Bool, virtualized: Int32, extensions: String) throws {
    guard virtualized == 1 else { throw Refusal("this is not a verified virtual machine") }
    guard optedIn else { throw Refusal("disposable-guest execution was not explicitly selected") }
    guard !extensions.lowercased().contains("io.kandji") else {
      throw Refusal("the guest contains the affected Iru/Kandji extension")
    }
  }

  static func validateFilesystem(type: String, source: String, local: Bool) throws {
    guard local, type == "apfs", source.hasPrefix("/dev/disk") else {
      throw Refusal("fixtures must reside on the guest's local APFS disk, not a shared mount")
    }
  }

  private static func openLocalDirectory(_ directory: URL) throws -> Int32 {
    try requireGuest()
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Refusal("cannot pin fixture directory") }
    do {
      var filesystem = statfs()
      guard fstatfs(descriptor, &filesystem) == 0 else {
        throw Refusal("cannot identify fixture filesystem")
      }
      let type = withUnsafePointer(to: &filesystem.f_fstypename) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
          String(cString: $0)
        }
      }
      let source = withUnsafePointer(to: &filesystem.f_mntfromname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
          String(cString: $0)
        }
      }
      try validateFilesystem(
        type: type, source: source, local: filesystem.f_flags & UInt32(MNT_LOCAL) != 0)
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  public static func requireLocalDirectory(_ directory: URL) throws {
    close(try openLocalDirectory(directory))
  }

  public static func makeFIFO(at url: URL) throws {
    let descriptor = try openLocalDirectory(url.deletingLastPathComponent())
    defer { close(descriptor) }
    guard mkfifoat(descriptor, url.lastPathComponent, 0o600) == 0 else {
      throw Refusal("creating the guest FIFO failed (errno \(errno))")
    }
  }
}

#if MACARCHY_TEST_SAFETY_CLI
  @main
  struct TestSafetyCommand {
    static func main() {
      do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--check"] {
          try IsolatedTestEnvironment.requireGuest()
        } else if arguments.count == 2, arguments[0] == "--check-directory" {
          try IsolatedTestEnvironment.requireLocalDirectory(URL(filePath: arguments[1]))
        } else if arguments.count == 2, arguments[0] == "--create-fifo" {
          try IsolatedTestEnvironment.makeFIFO(at: URL(filePath: arguments[1]))
        } else {
          throw IsolatedTestEnvironment.Refusal(
            "usage: test-safety --check | --check-directory PATH | --create-fifo PATH")
        }
      } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
      }
    }
  }
#endif
