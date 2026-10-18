import Darwin
import Foundation

/// Startup/palette-change acknowledgement, not a heartbeat or hung-runloop proof.
/// Process start identity prevents stale PID reuse; ownership is label + state root.
package struct LeanFocusRuntime: Codable, Equatable, Sendable {
  package let label: String
  package let stateRoot: String
  package let pid: Int32
  package let started: UInt64
  package let executablePath: String
  package let generationID: String
  package let accent: String

  package static func publish(
    configuration: LeanFocusServiceConfiguration, generationID: String, accent: String
  ) throws {
    guard let started = processStartTime(getpid()),
      let processPath = processExecutablePath(getpid()),
      let physical = LeanFocusServiceConfiguration.physicalPath(processPath),
      physical == configuration.currentExecutablePath
    else { throw LeanFocusServiceError("cannot establish the running helper identity") }
    let value = Self(
      label: LeanFocusService.label, stateRoot: configuration.stateRoot,
      pid: getpid(), started: started, executablePath: physical,
      generationID: generationID, accent: accent)
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

  package static func validateIfPresent(configuration: LeanFocusServiceConfiguration) throws {
    guard
      let parent = try PinnedFilesystem.openDirectoryIfPresent(
        at: configuration.runtimeURL.deletingLastPathComponent())
    else { return }
    defer { Darwin.close(parent) }
    _ = try ownedRecord(configuration: configuration, parent: parent)
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
    guard record.label == LeanFocusService.label, record.stateRoot == configuration.stateRoot else {
      throw LeanFocusServiceError("runtime evidence belongs to another label or state root")
    }
    return record
  }

  package func matches(
    configuration: LeanFocusServiceConfiguration, processID: Int32,
    palette: BordersPalette
  ) -> Bool {
    label == LeanFocusService.label && stateRoot == configuration.stateRoot
      && pid == processID && started == processStartTime(pid)
      && configuration.currentExecutablePath != nil
      && executablePath == configuration.currentExecutablePath
      && processExecutablePath(pid).flatMap(LeanFocusServiceConfiguration.physicalPath)
        == executablePath
      && generationID == palette.generationID && accent == palette.accent
  }
}
