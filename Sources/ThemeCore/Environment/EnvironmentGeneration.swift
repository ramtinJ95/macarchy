import Darwin
import Foundation

package struct EnvironmentGenerationManifest: Codable, Equatable, Sendable {
  package static let currentSchemaVersion = 1

  package let schemaVersion: Int
  package let generationID: String
  package let inputDigest: String
  package let renderedDigest: String
  package let artifacts: [String: String]

  package init(
    generationID: String,
    inputDigest: String,
    renderedDigest: String,
    artifacts: [String: String]
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.generationID = generationID
    self.inputDigest = inputDigest
    self.renderedDigest = renderedDigest
    self.artifacts = artifacts
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case inputDigest = "input_digest"
    case renderedDigest = "rendered_digest"
    case artifacts
  }
}

package struct EnvironmentGenerationInspection: Equatable, Sendable {
  package enum Status: String, Sendable {
    case absent
    case current
    case drifted
  }

  package let status: Status
  package let generationID: String?
  package let inputDigest: String?
  package let renderedDigest: String?
  package let message: String
}

package enum EnvironmentGenerationError: Error, CustomStringConvertible, Sendable {
  case invalid(String)
  case system(String, URL, Int32)

  package var description: String {
    switch self {
    case .invalid(let reason):
      "invalid environment generation: \(reason)"
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}

package struct StagedEnvironmentGeneration: Sendable {
  package let manifest: EnvironmentGenerationManifest
}

package struct EnvironmentGenerationStore: Sendable {
  package let stateRoot: URL

  private var environmentRoot: URL {
    stateRoot.appending(path: "environment", directoryHint: .isDirectory)
  }

  private var generationsRoot: URL {
    environmentRoot.appending(path: "generations", directoryHint: .isDirectory)
  }

  package init(stateRoot: URL) {
    self.stateRoot = stateRoot.standardizedFileURL
  }

  package func inspect(expected composition: EnvironmentComposition? = nil)
    -> EnvironmentGenerationInspection
  {
    do {
      guard let manifest = try currentManifest() else {
        return EnvironmentGenerationInspection(
          status: .absent,
          generationID: nil,
          inputDigest: nil,
          renderedDigest: nil,
          message: "No environment generation is selected."
        )
      }
      if let composition,
        manifest.inputDigest != composition.inputDigest
          || manifest.renderedDigest != composition.renderedDigest
      {
        return EnvironmentGenerationInspection(
          status: .drifted,
          generationID: manifest.generationID,
          inputDigest: manifest.inputDigest,
          renderedDigest: manifest.renderedDigest,
          message: "The selected environment generation does not match the profile."
        )
      }
      return EnvironmentGenerationInspection(
        status: .current,
        generationID: manifest.generationID,
        inputDigest: manifest.inputDigest,
        renderedDigest: manifest.renderedDigest,
        message: "The selected environment generation is valid."
      )
    } catch {
      return EnvironmentGenerationInspection(
        status: .drifted,
        generationID: nil,
        inputDigest: nil,
        renderedDigest: nil,
        message: String(describing: error)
      )
    }
  }

  package func currentManifest() throws -> EnvironmentGenerationManifest? {
    guard let destination = try currentDestination() else { return nil }
    let generationID = try validatedGenerationID(from: destination)
    return try manifest(generationID: generationID)
  }

  package func manifest(generationID: String) throws -> EnvironmentGenerationManifest {
    guard Self.isGenerationID(generationID) else {
      throw EnvironmentGenerationError.invalid("generation identity is invalid")
    }
    let generation = generationsRoot.appending(path: generationID, directoryHint: .isDirectory)
    let manifestURL = generation.appending(path: "manifest.json")
    let data = try BoundedRegularFile.read(at: manifestURL, maximumSize: 65_536).data
    let manifest = try JSONDecoder().decode(EnvironmentGenerationManifest.self, from: data)
    guard manifest.schemaVersion == EnvironmentGenerationManifest.currentSchemaVersion,
      manifest.generationID == generationID,
      Self.isGenerationID(generationID)
    else {
      throw EnvironmentGenerationError.invalid("manifest identity is invalid")
    }
    let files = try artifactInventory(at: generation)
    guard files == manifest.artifacts else {
      let expected = Set(manifest.artifacts.keys)
      let actual = Set(files.keys)
      let missing = expected.subtracting(actual).sorted()
      let unexpected = actual.subtracting(expected).sorted()
      let changed = expected.intersection(actual).filter {
        manifest.artifacts[$0] != files[$0]
      }.sorted()
      throw EnvironmentGenerationError.invalid(
        "artifact inventory or bytes drifted (missing: \(missing), unexpected: \(unexpected), changed: \(changed))"
      )
    }
    return manifest
  }

  package func validatedArtifact(generationID: String, path: String) throws -> Data {
    guard Self.isGenerationID(generationID), !path.hasPrefix("/") else {
      throw EnvironmentGenerationError.invalid("artifact identity is invalid")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw EnvironmentGenerationError.invalid("artifact identity is invalid")
    }

    let generation = generationsRoot.appending(path: generationID, directoryHint: .isDirectory)
    var rootMetadata = stat()
    guard lstat(generation.path, &rootMetadata) == 0 else {
      throw EnvironmentGenerationError.system("inspect generation", generation, errno)
    }
    guard rootMetadata.st_mode & S_IFMT == S_IFDIR, rootMetadata.st_mode & 0o222 == 0 else {
      throw EnvironmentGenerationError.invalid("generation root is not sealed")
    }

    let manifestURL = generation.appending(path: "manifest.json")
    let manifestFile = try BoundedRegularFile.read(at: manifestURL, maximumSize: 65_536)
    guard manifestFile.permissions & 0o222 == 0 else {
      throw EnvironmentGenerationError.invalid("manifest is not sealed")
    }
    let manifestData = manifestFile.data
    let manifest = try JSONDecoder().decode(EnvironmentGenerationManifest.self, from: manifestData)
    guard manifest.schemaVersion == EnvironmentGenerationManifest.currentSchemaVersion,
      manifest.generationID == generationID,
      let expectedDigest = manifest.artifacts[path]
    else {
      throw EnvironmentGenerationError.invalid("manifest identity is invalid")
    }

    var directory = generation
    for component in components.dropLast() {
      directory.append(path: String(component), directoryHint: .isDirectory)
      var metadata = stat()
      guard lstat(directory.path, &metadata) == 0 else {
        throw EnvironmentGenerationError.system("inspect artifact directory", directory, errno)
      }
      guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o222 == 0 else {
        throw EnvironmentGenerationError.invalid("artifact directory is not sealed")
      }
    }

    let artifactURL = generation.appending(path: path)
    let artifact = try BoundedRegularFile.read(at: artifactURL)
    guard artifact.permissions & 0o222 == 0,
      sha256Digest(artifact.data) == expectedDigest
    else {
      throw EnvironmentGenerationError.invalid("artifact bytes drifted: \(path)")
    }
    return artifact.data
  }

  package func stage(_ composition: EnvironmentComposition) throws -> StagedEnvironmentGeneration {
    try ensureRoots()
    let current: EnvironmentGenerationManifest?
    do {
      current = try currentManifest()
    } catch EnvironmentGenerationError.invalid(let reason)
      where reason.hasPrefix("artifact inventory or bytes drifted")
    {
      current = nil
    }
    if let manifest = current,
      manifest.inputDigest == composition.inputDigest,
      manifest.renderedDigest == composition.renderedDigest
    {
      return StagedEnvironmentGeneration(manifest: manifest)
    }

    let generationID = "e-\(UUID().uuidString.lowercased())"
    let staging = generationsRoot.appending(
      path: ".staging-\(generationID)",
      directoryHint: .isDirectory
    )
    let destination = generationsRoot.appending(path: generationID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    var published = false
    defer { if !published { try? FileManager.default.removeItem(at: staging) } }

    for artifact in composition.artifacts {
      let file = staging.appending(path: artifact.path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try artifact.data.write(to: file, options: .withoutOverwriting)
      try sealRegularFile(file, operation: "seal artifact")
    }
    let manifest = EnvironmentGenerationManifest(
      generationID: generationID,
      inputDigest: composition.inputDigest,
      renderedDigest: composition.renderedDigest,
      artifacts: Dictionary(
        uniqueKeysWithValues: composition.artifacts.map { ($0.path, $0.digest) })
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestURL = staging.appending(path: "manifest.json")
    try encoder.encode(manifest).write(to: manifestURL, options: .withoutOverwriting)
    try sealRegularFile(manifestURL, operation: "seal manifest")
    try sealDirectories(below: staging, includeRoot: false)
    let generationsDescriptor = try PinnedFilesystem.openDirectory(at: generationsRoot)
    defer { Darwin.close(generationsDescriptor) }
    let stagingDescriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: generationsDescriptor,
      name: staging.lastPathComponent,
      url: staging
    )
    defer { Darwin.close(stagingDescriptor) }
    do {
      try PinnedFilesystem.publishDirectoryAtomicallyAndSeal(
        parentDescriptor: generationsDescriptor,
        directoryDescriptor: stagingDescriptor,
        sourceName: staging.lastPathComponent,
        destinationName: destination.lastPathComponent,
        sourceURL: staging,
        destinationURL: destination,
        didPublish: { published = true }
      )
    } catch {
      if published {
        makeDirectoriesWritable(below: destination)
        try? FileManager.default.removeItem(at: destination)
      }
      throw error
    }
    return StagedEnvironmentGeneration(manifest: manifest)
  }

  package func select(_ generationID: String) throws {
    guard Self.isGenerationID(generationID) else {
      throw EnvironmentGenerationError.invalid("generation identity is invalid")
    }
    try ensureRoots()
    let temporaryName = ".current-\(UUID().uuidString.lowercased())"
    let temporary = environmentRoot.appending(path: temporaryName)
    let current = environmentRoot.appending(path: "current")
    let (stateDescriptor, environmentDescriptor) = try openEnvironment(create: false)
    defer {
      Darwin.close(environmentDescriptor)
      Darwin.close(stateDescriptor)
    }
    let created = "generations/\(generationID)".withCString { target in
      temporaryName.withCString { name in
        Darwin.symlinkat(target, environmentDescriptor, name)
      }
    }
    guard created == 0 else {
      throw EnvironmentGenerationError.system("create current pointer", temporary, errno)
    }
    defer { temporaryName.withCString { _ = Darwin.unlinkat(environmentDescriptor, $0, 0) } }
    let replaced = temporaryName.withCString { source in
      "current".withCString { destination in
        Darwin.renameat(environmentDescriptor, source, environmentDescriptor, destination)
      }
    }
    guard replaced == 0, fsync(environmentDescriptor) == 0 else {
      throw EnvironmentGenerationError.system("select current generation", current, errno)
    }
  }

  package func restoreCurrent(_ destination: String?) throws {
    let current = environmentRoot.appending(path: "current")
    guard let destination else {
      let descriptors: (Int32, Int32)
      do {
        descriptors = try openEnvironment(create: false)
      } catch let error as PinnedFilesystemError where error.code == ENOENT {
        return
      }
      let (stateDescriptor, environmentDescriptor) = descriptors
      defer {
        Darwin.close(environmentDescriptor)
        Darwin.close(stateDescriptor)
      }
      let removed = "current".withCString {
        Darwin.unlinkat(environmentDescriptor, $0, 0)
      }
      guard removed == 0 || errno == ENOENT else {
        throw EnvironmentGenerationError.system("remove current pointer", current, errno)
      }
      if removed == 0, fsync(environmentDescriptor) != 0 {
        throw EnvironmentGenerationError.system("sync removed current pointer", current, errno)
      }
      return
    }
    _ = try validatedGenerationID(from: destination)
    try ensureRoots()
    let temporary = environmentRoot.appending(
      path: ".current-restore-\(UUID().uuidString.lowercased())")
    let (stateDescriptor, environmentDescriptor) = try openEnvironment(create: false)
    defer {
      Darwin.close(environmentDescriptor)
      Darwin.close(stateDescriptor)
    }
    let created = destination.withCString { target in
      temporary.lastPathComponent.withCString { name in
        Darwin.symlinkat(target, environmentDescriptor, name)
      }
    }
    guard created == 0 else {
      throw EnvironmentGenerationError.system("create restored current pointer", temporary, errno)
    }
    defer {
      temporary.lastPathComponent.withCString {
        _ = Darwin.unlinkat(environmentDescriptor, $0, 0)
      }
    }
    let replaced = temporary.lastPathComponent.withCString { source in
      "current".withCString { target in
        Darwin.renameat(environmentDescriptor, source, environmentDescriptor, target)
      }
    }
    guard replaced == 0, fsync(environmentDescriptor) == 0 else {
      throw EnvironmentGenerationError.system("restore current pointer", current, errno)
    }
  }

  package func currentDestination() throws -> String? {
    let current = environmentRoot.appending(path: "current")
    let descriptors: (Int32, Int32)
    do {
      descriptors = try openEnvironment(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    let (stateDescriptor, environmentDescriptor) = descriptors
    defer {
      Darwin.close(environmentDescriptor)
      Darwin.close(stateDescriptor)
    }
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: environmentDescriptor,
        name: "current",
        url: current
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK else {
      throw EnvironmentGenerationError.invalid("current must be a symbolic link")
    }
    let destination = try PinnedFilesystem.symlinkDestination(
      parentDescriptor: environmentDescriptor,
      name: "current",
      url: current
    )
    _ = try validatedGenerationID(from: destination)
    return destination
  }

  package static func isGenerationID(_ value: String) -> Bool {
    guard value.hasPrefix("e-") else { return false }
    return UUID(uuidString: String(value.dropFirst(2))) != nil
  }

  private func ensureRoots() throws {
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    let stateDescriptor = try PinnedFilesystem.openDirectory(at: stateRoot)
    defer { Darwin.close(stateDescriptor) }
    let environmentDescriptor = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: stateDescriptor,
      name: "environment",
      url: environmentRoot,
      mode: 0o700
    )
    defer { Darwin.close(environmentDescriptor) }
    let generationsDescriptor = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: environmentDescriptor,
      name: "generations",
      url: generationsRoot,
      mode: 0o700
    )
    Darwin.close(generationsDescriptor)
  }

  private func openEnvironment(create: Bool) throws -> (Int32, Int32) {
    let stateDescriptor = try PinnedFilesystem.openDirectory(at: stateRoot)
    do {
      let environmentDescriptor =
        try create
        ? PinnedFilesystem.openOrCreateChildDirectory(
          parentDescriptor: stateDescriptor,
          name: "environment",
          url: environmentRoot,
          mode: 0o700
        )
        : PinnedFilesystem.openDirectory(
          parentDescriptor: stateDescriptor,
          name: "environment",
          url: environmentRoot
        )
      return (stateDescriptor, environmentDescriptor)
    } catch {
      Darwin.close(stateDescriptor)
      throw error
    }
  }

  private func validatedGenerationID(from destination: String) throws -> String {
    let prefix = "generations/e-"
    guard destination.hasPrefix(prefix), !destination.dropFirst(prefix.count).contains("/") else {
      throw EnvironmentGenerationError.invalid("current has an unexpected destination")
    }
    let generationID = String(destination.dropFirst("generations/".count))
    guard Self.isGenerationID(generationID) else {
      throw EnvironmentGenerationError.invalid("current has an unexpected destination")
    }
    return generationID
  }

  private func artifactInventory(at generation: URL) throws -> [String: String] {
    var rootMetadata = stat()
    guard lstat(generation.path, &rootMetadata) == 0 else {
      throw EnvironmentGenerationError.system("inspect generation", generation, errno)
    }
    guard rootMetadata.st_mode & S_IFMT == S_IFDIR else {
      throw EnvironmentGenerationError.invalid("generation root is not a directory")
    }
    guard rootMetadata.st_mode & 0o222 == 0 else {
      throw EnvironmentGenerationError.invalid(
        "artifact inventory or bytes drifted (writable entry: generation root)"
      )
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: generation,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: []
      )
    else {
      throw EnvironmentGenerationError.invalid("cannot enumerate generation")
    }
    let generationComponents = generation.resolvingSymlinksInPath().pathComponents
    var artifacts = [String: String]()
    for case let file as URL in enumerator {
      let relative = file.resolvingSymlinksInPath().pathComponents.dropFirst(
        generationComponents.count
      ).joined(separator: "/")
      var metadata = stat()
      guard lstat(file.path, &metadata) == 0 else {
        throw EnvironmentGenerationError.system("inspect generation entry", file, errno)
      }
      guard metadata.st_mode & 0o222 == 0 else {
        throw EnvironmentGenerationError.invalid(
          "artifact inventory or bytes drifted (writable entry: \(relative))"
        )
      }
      let values = try file.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isSymbolicLink != true else {
        throw EnvironmentGenerationError.invalid("generation contains a symbolic link")
      }
      if values.isDirectory == true { continue }
      guard values.isRegularFile == true else {
        throw EnvironmentGenerationError.invalid("generation contains an unsupported entry")
      }
      if relative == "manifest.json" { continue }
      artifacts[relative] = sha256Digest(try BoundedRegularFile.read(at: file).data)
    }
    return artifacts
  }

  private func sealRegularFile(_ url: URL, operation: String) throws {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw EnvironmentGenerationError.system(operation, url, errno)
    }
    defer { Darwin.close(descriptor) }
    guard fchmod(descriptor, 0o444) == 0, fsync(descriptor) == 0 else {
      throw EnvironmentGenerationError.system(operation, url, errno)
    }
  }

  private func sealDirectories(below root: URL, includeRoot: Bool) throws {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
      )
    else { return }
    var directories = includeRoot ? [root] : []
    for case let item as URL in enumerator {
      if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        directories.append(item)
      }
    }
    for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
      let descriptor = try PinnedFilesystem.openDirectory(at: directory)
      defer { Darwin.close(descriptor) }
      guard fchmod(descriptor, 0o555) == 0, fsync(descriptor) == 0 else {
        throw EnvironmentGenerationError.system("seal generation directory", directory, errno)
      }
    }
  }

  private func makeDirectoriesWritable(below root: URL) {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else { return }
    var directories = [root]
    for case let item as URL in enumerator {
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(item)
      }
    }
    for directory in directories {
      _ = chmod(directory.path, 0o755)
    }
  }
}
