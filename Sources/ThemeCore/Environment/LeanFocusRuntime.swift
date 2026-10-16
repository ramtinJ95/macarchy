import Darwin
import Foundation

/// Main-runloop acknowledgement, not pixels or exact AX focus. Contains no window
/// titles/application content. Process start identity prevents stale PID reuse.
package struct LeanFocusRuntime: Codable, Equatable, Sendable {
  package let pid: Int32
  package let started: UInt64
  package let executablePath: String
  package let generationID: String
  package let accent: String
  package let updated: Double

  package static func processStart(_ pid: Int32) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_uid == getuid()
    else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
  }

  package static func publish(
    configuration: LeanFocusServiceConfiguration, generationID: String, accent: String
  ) throws {
    guard let started = processStart(getpid()),
      processExecutablePath(getpid()) == configuration.executablePath
    else { throw LeanFocusServiceError("cannot establish the running helper identity") }
    let value = Self(
      pid: getpid(), started: started, executablePath: configuration.executablePath,
      generationID: generationID, accent: accent, updated: ProcessInfo.processInfo.systemUptime)
    let parent = try PinnedFilesystem.openDirectory(
      at: configuration.runtimeURL.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    _ = try ownedRecord(configuration: configuration, parent: parent)
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: parent, name: configuration.runtimeURL.lastPathComponent,
      url: configuration.runtimeURL, data: JSONEncoder().encode(value), mode: 0o600)
  }

  package static func read(configuration: LeanFocusServiceConfiguration) throws -> Self {
    let parent = try PinnedFilesystem.openDirectory(
      at: configuration.runtimeURL.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let data = try PinnedFilesystem.readRegularFile(
      parentDescriptor: parent, name: configuration.runtimeURL.lastPathComponent,
      url: configuration.runtimeURL, maximumSize: 8192
    ).data
    return try JSONDecoder().decode(Self.self, from: data)
  }

  /// Only after the owned job is stopped. Missing state is valid for an
  /// interrupted startup; unreadable, redirected or foreign state is not.
  package static func remove(configuration: LeanFocusServiceConfiguration) throws {
    guard
      let parent = try PinnedFilesystem.openDirectoryIfPresent(
        at: configuration.runtimeURL.deletingLastPathComponent())
    else { return }
    defer { Darwin.close(parent) }
    guard try ownedRecord(configuration: configuration, parent: parent) != nil else { return }
    guard unlinkat(parent, configuration.runtimeURL.lastPathComponent, 0) == 0,
      fsync(parent) == 0
    else { throw LeanFocusServiceError("cannot remove owned runtime evidence (errno \(errno))") }
  }

  private static func ownedRecord(
    configuration: LeanFocusServiceConfiguration, parent: Int32
  ) throws -> Self? {
    let data: Data
    do {
      data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: parent, name: configuration.runtimeURL.lastPathComponent,
        url: configuration.runtimeURL, maximumSize: 8192
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT { return nil }
    let record = try JSONDecoder().decode(Self.self, from: data)
    guard record.executablePath == configuration.executablePath else {
      throw LeanFocusServiceError("runtime evidence belongs to another executable")
    }
    return record
  }

  package func matches(
    configuration: LeanFocusServiceConfiguration, processID: Int32,
    palette: BordersPalette, now: Double = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    pid == processID && started == Self.processStart(pid)
      && executablePath == configuration.executablePath
      && processExecutablePath(pid) == executablePath
      && generationID == palette.generationID && accent == palette.accent
      && updated.isFinite && now >= updated && now - updated <= 3
  }
}
