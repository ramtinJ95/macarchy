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
  private static let artifactPaths = [
    "plugins/clock.sh", "plugins/space-indexes.sh", "sketchybarrc",
  ]

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
    let generation = providerRoot.appending(path: target, directoryHint: .isDirectory)
    do {
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
        limit: 2
      )
      guard
        !pluginInventory.truncated,
        pluginInventory.entries == ["clock.sh", "space-indexes.sh"]
      else {
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
      guard
        manifest.schemaVersion == SketchyBarGenerationManifest.schemaVersion,
        manifest.rendererVersion == SketchyBarGenerationManifest.rendererVersion,
        manifest.generationID == generationID,
        manifest.inputDigest.hasPrefix("sha256:"),
        manifest.renderedDigest.hasPrefix("sha256:"),
        manifest.artifacts.keys.sorted() == Self.artifactPaths
      else {
        throw SketchyBarGenerationError.invalid("manifest identity or inventory is invalid")
      }
      for path in Self.artifactPaths {
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

  package static func isGenerationID(_ value: String) -> Bool {
    guard value.hasPrefix("s-") else { return false }
    let nonce = String(value.dropFirst(2))
    return nonce == nonce.lowercased() && UUID(uuidString: nonce) != nil
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
