import Darwin
import Foundation

package struct SketchyBarGenerationManifest: Codable, Equatable, Sendable {
  package static let schemaVersion = 1
  package static let rendererVersion = 1

  package let schemaVersion: Int
  package let rendererVersion: Int
  package let generationID: String
  package let inputDigest: String
  package let renderedDigest: String
  package let artifacts: [String: String]

  package init(generationID: String, composition: SketchyBarComposition) {
    schemaVersion = Self.schemaVersion
    rendererVersion = Self.rendererVersion
    self.generationID = generationID
    inputDigest = composition.inputDigest
    renderedDigest = composition.renderedDigest
    artifacts = Dictionary(
      uniqueKeysWithValues: composition.artifacts.map { ($0.path, $0.digest) }
    )
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case rendererVersion = "renderer_version"
    case generationID = "generation_id"
    case inputDigest = "input_digest"
    case renderedDigest = "rendered_digest"
    case artifacts
  }
}

package enum SketchyBarGenerationStatus: String, Sendable {
  case missing
  case current
  case invalid
}

package struct SketchyBarGenerationInspection: Equatable, Sendable {
  package let status: SketchyBarGenerationStatus
  package let generationID: String?
  package let manifest: SketchyBarGenerationManifest?
  package let message: String

  package static let missing = Self(
    status: .missing,
    generationID: nil,
    manifest: nil,
    message: "No managed SketchyBar generation is selected."
  )
}

package enum SketchyBarGenerationError: Error, CustomStringConvertible, Sendable {
  case invalid(String)
  case system(String, URL, Int32)

  package var description: String {
    switch self {
    case .invalid(let reason):
      "invalid SketchyBar generation: \(reason)"
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}

package struct SketchyBarGenerationInspector: Sendable {
  private static let coreArtifactPaths = [
    "plugins/clock.sh", "plugins/space-indexes.sh", "sketchybarrc",
  ]
  private static let hookArtifactPath = "plugins/user-hook.sh"

  private let stateRoot: URL

  package init(stateRoot: URL) {
    self.stateRoot = stateRoot.standardizedFileURL
  }

  package func inspect() -> SketchyBarGenerationInspection {
    let providerRoot = stateRoot.appending(
      path: "desktop/sketchybar",
      directoryHint: .isDirectory
    )
    let current = providerRoot.appending(path: "current")
    var metadata = stat()
    guard lstat(current.path, &metadata) == 0 else {
      return errno == ENOENT
        ? .missing
        : invalid("cannot inspect current pointer: \(systemMessage())")
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK, let target = readLink(current) else {
      return invalid("current is not a readable symbolic link")
    }
    let prefix = "generations/"
    guard target.hasPrefix(prefix) else {
      return invalid("current target is outside the SketchyBar generation inventory")
    }
    let generationID = String(target.dropFirst(prefix.count))
    guard Self.isGenerationID(generationID), !generationID.contains("/") else {
      return invalid("current target has an invalid generation identity")
    }
    do {
      let manifest = try validatedManifest(generationID)
      return SketchyBarGenerationInspection(
        status: .current,
        generationID: generationID,
        manifest: manifest,
        message: "Managed SketchyBar generation \(generationID) is valid and selected."
      )
    } catch {
      return invalid("\(generationID): \(error)", generationID: generationID)
    }
  }

  fileprivate func validateGeneration(_ generationID: String) throws {
    guard Self.isGenerationID(generationID) else {
      throw SketchyBarGenerationError.invalid("generation identity is invalid")
    }
    _ = try validatedManifest(generationID)
  }

  package static func isGenerationID(_ value: String) -> Bool {
    guard value.hasPrefix("s-") else { return false }
    let nonce = String(value.dropFirst(2))
    return nonce == nonce.lowercased() && UUID(uuidString: nonce) != nil
  }

  private func validatedManifest(
    _ generationID: String
  ) throws -> SketchyBarGenerationManifest {
    let generation = stateRoot.appending(
      path: "desktop/sketchybar/generations/\(generationID)",
      directoryHint: .isDirectory
    )
    let generationDescriptor = try PinnedFilesystem.openDirectory(at: generation)
    defer { Darwin.close(generationDescriptor) }
    try inspectDirectory(
      descriptor: generationDescriptor,
      permissions: 0o555,
      label: "generation root"
    )
    let rootInventory = try PinnedFilesystem.directoryEntries(
      descriptor: generationDescriptor,
      url: generation,
      limit: 3
    )
    guard
      !rootInventory.truncated,
      rootInventory.entries == ["manifest.json", "plugins", "sketchybarrc"]
    else {
      throw SketchyBarGenerationError.invalid("generation root inventory is unexpected")
    }
    let plugins = generation.appending(path: "plugins", directoryHint: .isDirectory)
    let pluginsDescriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: generationDescriptor,
      name: "plugins",
      url: plugins
    )
    defer { Darwin.close(pluginsDescriptor) }
    try inspectDirectory(
      descriptor: pluginsDescriptor,
      permissions: 0o555,
      label: "plugins directory"
    )
    let pluginInventory = try PinnedFilesystem.directoryEntries(
      descriptor: pluginsDescriptor,
      url: plugins,
      limit: 3
    )
    guard !pluginInventory.truncated else {
      throw SketchyBarGenerationError.invalid("plugin inventory is unexpected")
    }

    let manifestFile = try PinnedFilesystem.readRegularFile(
      parentDescriptor: generationDescriptor,
      name: "manifest.json",
      url: generation.appending(path: "manifest.json"),
      maximumSize: 16_384
    )
    guard manifestFile.permissions == 0o444 else {
      throw SketchyBarGenerationError.invalid("manifest is not read-only")
    }
    let manifest = try JSONDecoder().decode(
      SketchyBarGenerationManifest.self,
      from: manifestFile.data
    )
    let artifactPaths = manifest.artifacts.keys.sorted()
    guard
      manifest.schemaVersion == SketchyBarGenerationManifest.schemaVersion,
      manifest.rendererVersion == SketchyBarGenerationManifest.rendererVersion,
      manifest.generationID == generationID,
      manifest.inputDigest.hasPrefix("sha256:"),
      manifest.renderedDigest.hasPrefix("sha256:"),
      artifactPaths == Self.coreArtifactPaths
        || artifactPaths == (Self.coreArtifactPaths + [Self.hookArtifactPath]).sorted()
    else {
      throw SketchyBarGenerationError.invalid("manifest identity or inventory is invalid")
    }
    let expectedPluginInventory =
      artifactPaths
      .filter { $0.hasPrefix("plugins/") }
      .map { String($0.dropFirst("plugins/".count)) }
      .sorted()
    guard pluginInventory.entries == expectedPluginInventory else {
      throw SketchyBarGenerationError.invalid("plugin inventory does not match its manifest")
    }
    for path in artifactPaths {
      let components = path.split(separator: "/")
      let parentDescriptor = components.count == 1 ? generationDescriptor : pluginsDescriptor
      let name = String(components.last!)
      let artifact = try PinnedFilesystem.readRegularFile(
        parentDescriptor: parentDescriptor,
        name: name,
        url: generation.appending(path: path)
      )
      guard artifact.permissions == 0o555 else {
        throw SketchyBarGenerationError.invalid("\(path) is not read-only and executable")
      }
      guard sha256Digest(artifact.data) == manifest.artifacts[path] else {
        throw SketchyBarGenerationError.invalid("\(path) digest does not match its manifest")
      }
    }
    guard sketchyBarArtifactDigest(manifest.artifacts) == manifest.renderedDigest else {
      throw SketchyBarGenerationError.invalid("rendered digest does not match its artifacts")
    }
    return manifest
  }

  private func inspectDirectory(descriptor: Int32, permissions: Int, label: String) throws {
    var metadata = stat()
    guard
      fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o777 == permissions
    else {
      throw SketchyBarGenerationError.invalid(
        "\(label) is not a sealed ordinary directory"
      )
    }
  }

  private func invalid(
    _ message: String,
    generationID: String? = nil
  ) -> SketchyBarGenerationInspection {
    SketchyBarGenerationInspection(
      status: .invalid,
      generationID: generationID,
      manifest: nil,
      message: message
    )
  }

  private func readLink(_ url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(url.path, &buffer, buffer.count - 1)
    guard count >= 0 else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  private func systemMessage() -> String {
    "\(String(cString: strerror(errno))) (errno \(errno))"
  }
}

package struct SketchyBarGenerationActivator: Sendable {
  private let stateRoot: URL

  package init(stateRoot: URL) {
    self.stateRoot = stateRoot.standardizedFileURL
  }

  package func publish(
    _ composition: SketchyBarComposition,
    generationID: String
  ) throws {
    guard SketchyBarGenerationInspector.isGenerationID(generationID) else {
      throw SketchyBarGenerationError.invalid("cannot publish an invalid generation identity")
    }
    let manifest = SketchyBarGenerationManifest(
      generationID: generationID,
      composition: composition
    )
    let providerRoot = stateRoot.appending(
      path: "desktop/sketchybar",
      directoryHint: .isDirectory
    )
    let generations = providerRoot.appending(path: "generations", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: providerRoot, withIntermediateDirectories: true)
    let providerDescriptor = try PinnedFilesystem.openDirectory(at: providerRoot)
    defer { Darwin.close(providerDescriptor) }
    let generationsDescriptor = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: providerDescriptor,
      name: "generations",
      url: generations
    )
    defer { Darwin.close(generationsDescriptor) }

    let stagingName = Self.stagingName(generationID)
    let staging = generations.appending(path: stagingName, directoryHint: .isDirectory)
    let destination = generationURL(generationID)
    let stagingDescriptor = try PinnedFilesystem.createDirectory(
      parentDescriptor: generationsDescriptor,
      name: stagingName,
      url: staging
    )
    defer { Darwin.close(stagingDescriptor) }

    do {
      let plugins = staging.appending(path: "plugins", directoryHint: .isDirectory)
      let pluginsDescriptor = try PinnedFilesystem.createDirectory(
        parentDescriptor: stagingDescriptor,
        name: "plugins",
        url: plugins
      )
      defer { Darwin.close(pluginsDescriptor) }
      for artifact in composition.artifacts {
        let parentDescriptor =
          artifact.path.hasPrefix("plugins/")
          ? pluginsDescriptor : stagingDescriptor
        let name = String(artifact.path.split(separator: "/").last!)
        try PinnedFilesystem.writeNewRegularFile(
          parentDescriptor: parentDescriptor,
          name: name,
          url: staging.appending(path: artifact.path),
          data: Data(artifact.contents.utf8),
          mode: 0o555
        )
      }
      guard fchmod(pluginsDescriptor, 0o555) == 0, fsync(pluginsDescriptor) == 0 else {
        throw SketchyBarGenerationError.system("seal plugins directory", plugins, errno)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try PinnedFilesystem.writeNewRegularFile(
        parentDescriptor: stagingDescriptor,
        name: "manifest.json",
        url: staging.appending(path: "manifest.json"),
        data: try encoder.encode(manifest),
        mode: 0o444
      )
      try PinnedFilesystem.publishDirectoryAtomicallyAndSeal(
        parentDescriptor: generationsDescriptor,
        directoryDescriptor: stagingDescriptor,
        sourceName: stagingName,
        destinationName: generationID,
        sourceURL: staging,
        destinationURL: destination
      )
    } catch {
      let publicationError = error
      do {
        try removeTransactionResidue(generationID)
      } catch {
        throw SketchyBarGenerationError.invalid(
          "publication failed: \(publicationError); cleanup failed: \(error)"
        )
      }
      throw publicationError
    }
  }

  package func select(_ generationID: String) throws {
    try replaceCurrent(with: generationID)
  }

  package func restoreCurrent(_ generationID: String?) throws {
    guard let generationID else {
      let current = providerRoot.appending(path: "current")
      if unlink(current.path) != 0, errno != ENOENT {
        throw SketchyBarGenerationError.system("remove current pointer", current, errno)
      }
      return
    }
    guard SketchyBarGenerationInspector.isGenerationID(generationID) else {
      throw SketchyBarGenerationError.invalid("cannot restore an invalid generation identity")
    }
    try replaceCurrent(with: generationID)
  }

  package func removeTransactionResidue(_ generationID: String) throws {
    guard SketchyBarGenerationInspector.isGenerationID(generationID) else {
      throw SketchyBarGenerationError.invalid("cannot recover an invalid generation identity")
    }
    try removeNamedGeneration(Self.stagingName(generationID))
    try removeNamedGeneration(generationID)
  }

  package func removeCurrentSelectionResidue(_ generationID: String) throws {
    guard SketchyBarGenerationInspector.isGenerationID(generationID) else {
      throw SketchyBarGenerationError.invalid("cannot recover an invalid generation identity")
    }
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: providerRoot)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(descriptor) }
    let name = Self.currentSelectionName(generationID)
    let residue = providerRoot.appending(path: name)
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: descriptor,
        name: name,
        url: residue
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    let expected = "generations/\(generationID)"
    guard
      metadata.st_mode & S_IFMT == S_IFLNK,
      metadata.st_nlink == 1,
      try PinnedFilesystem.symlinkDestination(
        parentDescriptor: descriptor,
        name: name,
        url: residue
      ) == expected
    else {
      throw SketchyBarGenerationError.invalid("current selection residue is not authentic")
    }
    guard name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
      throw SketchyBarGenerationError.system("remove current selection residue", residue, errno)
    }
    guard fsync(descriptor) == 0 else {
      throw SketchyBarGenerationError.system("sync current selection recovery", residue, errno)
    }
  }

  package func validatedGenerationIDs() throws -> [String] {
    let providerDescriptor = try PinnedFilesystem.openDirectory(at: providerRoot)
    defer { Darwin.close(providerDescriptor) }
    let generations = providerRoot.appending(path: "generations", directoryHint: .isDirectory)
    let generationsDescriptor: Int32
    do {
      generationsDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: providerDescriptor,
        name: "generations",
        url: generations
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return []
    }
    defer { Darwin.close(generationsDescriptor) }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: generationsDescriptor,
      url: generations,
      limit: 1_024
    )
    guard
      !inventory.truncated,
      inventory.entries.allSatisfy(SketchyBarGenerationInspector.isGenerationID)
    else {
      throw SketchyBarGenerationError.invalid(
        "SketchyBar generation inventory contains unowned entries"
      )
    }
    let inspector = SketchyBarGenerationInspector(stateRoot: stateRoot)
    for generationID in inventory.entries {
      try inspector.validateGeneration(generationID)
    }
    return inventory.entries
  }

  package func removeGenerations(_ generationIDs: [String]) throws {
    guard
      generationIDs == generationIDs.sorted(),
      Set(generationIDs).count == generationIDs.count,
      generationIDs.allSatisfy(SketchyBarGenerationInspector.isGenerationID)
    else {
      throw SketchyBarGenerationError.invalid("cannot remove an invalid generation inventory")
    }
    let providerDescriptor = try PinnedFilesystem.openDirectory(at: providerRoot)
    defer { Darwin.close(providerDescriptor) }
    let generations = providerRoot.appending(path: "generations", directoryHint: .isDirectory)
    let generationsDescriptor: Int32
    do {
      generationsDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: providerDescriptor,
        name: "generations",
        url: generations
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(generationsDescriptor) }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: generationsDescriptor,
      url: generations,
      limit: 1_024
    )
    let expected = Set(generationIDs)
    guard !inventory.truncated, inventory.entries.allSatisfy(expected.contains) else {
      throw SketchyBarGenerationError.invalid("SketchyBar generation inventory changed")
    }
    for generationID in generationIDs {
      try removeNamedGeneration(
        generationID,
        parentDescriptor: generationsDescriptor,
        generations: generations
      )
    }
    let remaining = try PinnedFilesystem.directoryEntries(
      descriptor: generationsDescriptor,
      url: generations,
      limit: 1
    )
    guard !remaining.truncated, remaining.entries.isEmpty else {
      throw SketchyBarGenerationError.invalid("SketchyBar generation inventory changed")
    }
    try removeBoundDirectory(
      parentDescriptor: providerDescriptor,
      directoryDescriptor: generationsDescriptor,
      name: "generations",
      url: generations
    )
  }

  private var providerRoot: URL {
    stateRoot.appending(path: "desktop/sketchybar", directoryHint: .isDirectory)
  }

  private func generationURL(_ generationID: String) -> URL {
    providerRoot.appending(
      path: "generations/\(generationID)",
      directoryHint: .isDirectory
    )
  }

  private func replaceCurrent(with generationID: String) throws {
    guard SketchyBarGenerationInspector.isGenerationID(generationID) else {
      throw SketchyBarGenerationError.invalid("cannot select an invalid generation identity")
    }
    try authenticateSelectableGeneration(generationID)
    let descriptor = try PinnedFilesystem.openDirectory(at: providerRoot)
    defer { Darwin.close(descriptor) }
    let temporaryName = Self.currentSelectionName(generationID)
    let temporary = providerRoot.appending(
      path: temporaryName
    )
    let destination = "generations/\(generationID)"
    let created = destination.withCString { target in
      temporaryName.withCString { Darwin.symlinkat(target, descriptor, $0) }
    }
    guard created == 0 else {
      throw SketchyBarGenerationError.system("create current pointer", temporary, errno)
    }
    defer { temporaryName.withCString { _ = Darwin.unlinkat(descriptor, $0, 0) } }
    let current = providerRoot.appending(path: "current")
    let replaced = temporaryName.withCString { source in
      "current".withCString { Darwin.renameat(descriptor, source, descriptor, $0) }
    }
    guard replaced == 0, fsync(descriptor) == 0 else {
      throw SketchyBarGenerationError.system("replace current pointer", current, errno)
    }
  }

  private func authenticateSelectableGeneration(_ generationID: String) throws {
    let generation = generationURL(generationID)
    let descriptor = try PinnedFilesystem.openDirectory(at: generation)
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & 0o777 == 0o555 else {
      throw SketchyBarGenerationError.invalid("selected generation is not sealed")
    }
    let manifest = try PinnedFilesystem.readRegularFile(
      parentDescriptor: descriptor,
      name: "manifest.json",
      url: generation.appending(path: "manifest.json"),
      maximumSize: 16_384
    )
    guard
      let decoded = try? JSONDecoder().decode(
        SketchyBarGenerationManifest.self,
        from: manifest.data
      ),
      decoded.generationID == generationID
    else {
      throw SketchyBarGenerationError.invalid("selected generation identity is invalid")
    }
  }

  private func removeNamedGeneration(_ name: String) throws {
    let generations = providerRoot.appending(path: "generations", directoryHint: .isDirectory)
    let generationsDescriptor: Int32
    do {
      generationsDescriptor = try PinnedFilesystem.openDirectory(at: generations)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(generationsDescriptor) }
    try removeNamedGeneration(
      name,
      parentDescriptor: generationsDescriptor,
      generations: generations
    )
  }

  private func removeNamedGeneration(
    _ name: String,
    parentDescriptor generationsDescriptor: Int32,
    generations: URL
  ) throws {
    let generation = generations.appending(path: name, directoryHint: .isDirectory)
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: generationsDescriptor,
        name: name,
        url: generation
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(descriptor) }

    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor,
      url: generation,
      limit: 3
    )
    let expectedRoot = Set(["manifest.json", "plugins", "sketchybarrc"])
    guard
      !inventory.truncated,
      Set(inventory.entries).isSubset(of: expectedRoot)
    else {
      throw SketchyBarGenerationError.invalid("generation removal inventory is unexpected")
    }
    guard fchmod(descriptor, 0o755) == 0 else {
      throw SketchyBarGenerationError.system("make generation removable", generation, errno)
    }

    if inventory.entries.contains("plugins") {
      let plugins = generation.appending(path: "plugins", directoryHint: .isDirectory)
      let pluginsDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: descriptor,
        name: "plugins",
        url: plugins
      )
      defer { Darwin.close(pluginsDescriptor) }
      let pluginsInventory = try PinnedFilesystem.directoryEntries(
        descriptor: pluginsDescriptor,
        url: plugins,
        limit: 3
      )
      let expectedPlugins = Set(["clock.sh", "space-indexes.sh", "user-hook.sh"])
      guard
        !pluginsInventory.truncated,
        Set(pluginsInventory.entries).isSubset(of: expectedPlugins)
      else {
        throw SketchyBarGenerationError.invalid("plugin removal inventory is unexpected")
      }
      guard fchmod(pluginsDescriptor, 0o755) == 0 else {
        throw SketchyBarGenerationError.system("make plugins removable", plugins, errno)
      }
      for plugin in pluginsInventory.entries {
        try removeBoundRegularFile(
          parentDescriptor: pluginsDescriptor,
          name: plugin,
          url: plugins.appending(path: plugin)
        )
      }
      try removeBoundDirectory(
        parentDescriptor: descriptor,
        directoryDescriptor: pluginsDescriptor,
        name: "plugins",
        url: plugins
      )
    }
    for file in inventory.entries where file != "plugins" {
      try removeBoundRegularFile(
        parentDescriptor: descriptor,
        name: file,
        url: generation.appending(path: file)
      )
    }
    try removeBoundDirectory(
      parentDescriptor: generationsDescriptor,
      directoryDescriptor: descriptor,
      name: name,
      url: generation
    )
  }

  private func removeBoundRegularFile(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws {
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw SketchyBarGenerationError.system("pin generation artifact", url, errno)
    }
    defer { Darwin.close(descriptor) }
    var pinned = stat()
    guard fstat(descriptor, &pinned) == 0, pinned.st_mode & S_IFMT == S_IFREG else {
      throw SketchyBarGenerationError.invalid("generation artifact is not a regular file")
    }
    let path = try PinnedFilesystem.metadata(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    guard pinned.st_dev == path.st_dev, pinned.st_ino == path.st_ino else {
      throw SketchyBarGenerationError.invalid("generation artifact identity changed")
    }
    guard name.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
      throw SketchyBarGenerationError.system("remove generation artifact", url, errno)
    }
  }

  private func removeBoundDirectory(
    parentDescriptor: Int32,
    directoryDescriptor: Int32,
    name: String,
    url: URL
  ) throws {
    var pinned = stat()
    guard fstat(directoryDescriptor, &pinned) == 0 else {
      throw SketchyBarGenerationError.system("pin generation directory", url, errno)
    }
    let path = try PinnedFilesystem.metadata(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    guard
      pinned.st_mode & S_IFMT == S_IFDIR,
      pinned.st_dev == path.st_dev,
      pinned.st_ino == path.st_ino
    else {
      throw SketchyBarGenerationError.invalid("generation directory identity changed")
    }
    guard name.withCString({ Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
      throw SketchyBarGenerationError.system("remove generation directory", url, errno)
    }
    guard fsync(parentDescriptor) == 0 else {
      throw SketchyBarGenerationError.system("sync generation removal", url, errno)
    }
  }

  private static func stagingName(_ generationID: String) -> String {
    ".staging-\(generationID)"
  }

  private static func currentSelectionName(_ generationID: String) -> String {
    ".current-\(generationID)"
  }
}
