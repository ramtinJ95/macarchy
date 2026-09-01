import Darwin
import Foundation

package struct YabaiGenerationManifest: Codable, Equatable, Sendable {
  package static let schemaVersion = 1
  package static let rendererVersion = 1

  package let schemaVersion: Int
  package let rendererVersion: Int
  package let generationID: String
  package let inputDigest: String
  package let renderedDigest: String

  package init(generationID: String, inputDigest: String, renderedDigest: String) {
    schemaVersion = Self.schemaVersion
    rendererVersion = Self.rendererVersion
    self.generationID = generationID
    self.inputDigest = inputDigest
    self.renderedDigest = renderedDigest
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case rendererVersion = "renderer_version"
    case generationID = "generation_id"
    case inputDigest = "input_digest"
    case renderedDigest = "rendered_digest"
  }
}

package enum YabaiGenerationStatus: String, Sendable {
  case missing
  case current
  case invalid
}

package struct YabaiGenerationInspection: Equatable, Sendable {
  package let status: YabaiGenerationStatus
  package let generationID: String?
  package let manifest: YabaiGenerationManifest?
  package let message: String

  package static let missing = Self(
    status: .missing,
    generationID: nil,
    manifest: nil,
    message: "No managed yabai generation is selected."
  )
}

package struct YabaiPreparedGeneration: Sendable {
  package let manifest: YabaiGenerationManifest
  package let created: Bool
}

package enum YabaiGenerationError: Error, CustomStringConvertible, Sendable {
  case invalid(String)
  case system(String, URL, Int32)

  package var description: String {
    switch self {
    case .invalid(let reason):
      "invalid yabai generation: \(reason)"
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}

package struct YabaiGenerationInspector: Sendable {
  private let stateRoot: URL

  package init(stateRoot: URL) {
    self.stateRoot = stateRoot.standardizedFileURL
  }

  package func inspect() -> YabaiGenerationInspection {
    let providerRoot = stateRoot.appending(path: "desktop/yabai", directoryHint: .isDirectory)
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
      return invalid("current target is outside the yabai generation inventory")
    }
    let generationID = String(target.dropFirst(prefix.count))
    guard Self.isGenerationID(generationID), !generationID.contains("/") else {
      return invalid("current target has an invalid generation identity")
    }
    let generation = providerRoot.appending(path: target, directoryHint: .isDirectory)
    do {
      var generationMetadata = stat()
      guard
        lstat(generation.path, &generationMetadata) == 0,
        generationMetadata.st_mode & S_IFMT == S_IFDIR,
        generationMetadata.st_mode & 0o777 == 0o555
      else {
        throw YabaiGenerationError.invalid("generation root is not a sealed ordinary directory")
      }
      let inventory = try FileManager.default.contentsOfDirectory(atPath: generation.path).sorted()
      guard inventory == ["manifest.json", "yabairc"] else {
        throw YabaiGenerationError.invalid(
          "generation inventory is not exactly manifest.json and yabairc")
      }
      let manifestFile = try BoundedRegularFile.read(
        at: generation.appending(path: "manifest.json"),
        maximumSize: 16_384
      )
      guard manifestFile.permissions == 0o444 else {
        throw YabaiGenerationError.invalid("manifest is not read-only")
      }
      let manifest = try JSONDecoder().decode(
        YabaiGenerationManifest.self,
        from: manifestFile.data
      )
      guard
        manifest.schemaVersion == YabaiGenerationManifest.schemaVersion,
        manifest.rendererVersion == YabaiGenerationManifest.rendererVersion,
        manifest.generationID == generationID,
        manifest.inputDigest.hasPrefix("sha256:"),
        manifest.renderedDigest.hasPrefix("sha256:")
      else {
        throw YabaiGenerationError.invalid("manifest identity or version is invalid")
      }
      let configuration = try BoundedRegularFile.read(
        at: generation.appending(path: "yabairc")
      )
      guard configuration.permissions == 0o444 else {
        throw YabaiGenerationError.invalid("rendered yabairc is not read-only")
      }
      guard sha256Digest(configuration.data) == manifest.renderedDigest else {
        throw YabaiGenerationError.invalid("rendered yabairc digest does not match its manifest")
      }
      return YabaiGenerationInspection(
        status: .current,
        generationID: generationID,
        manifest: manifest,
        message: "Managed yabai generation \(generationID) is valid and selected."
      )
    } catch {
      return invalid("\(generationID): \(error)", generationID: generationID)
    }
  }

  package static func isGenerationID(_ value: String) -> Bool {
    guard value.hasPrefix("y-") else { return false }
    let nonce = String(value.dropFirst(2))
    return nonce == nonce.lowercased() && UUID(uuidString: nonce) != nil
  }

  private func invalid(
    _ message: String,
    generationID: String? = nil
  ) -> YabaiGenerationInspection {
    YabaiGenerationInspection(
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

package struct YabaiGenerationActivator: Sendable {
  private let stateRoot: URL

  package init(stateRoot: URL) {
    self.stateRoot = stateRoot.standardizedFileURL
  }

  package func prepare(_ composition: YabaiComposition) throws -> YabaiPreparedGeneration {
    let inspection = YabaiGenerationInspector(stateRoot: stateRoot).inspect()
    if inspection.status == .current,
      let manifest = inspection.manifest,
      manifest.inputDigest == composition.inputDigest,
      manifest.renderedDigest == composition.renderedDigest
    {
      return YabaiPreparedGeneration(
        manifest: manifest,
        created: false
      )
    }

    let generationID = "y-\(UUID().uuidString.lowercased())"
    let manifest = YabaiGenerationManifest(
      generationID: generationID,
      inputDigest: composition.inputDigest,
      renderedDigest: composition.renderedDigest
    )
    let providerRoot = stateRoot.appending(path: "desktop/yabai", directoryHint: .isDirectory)
    let generations = providerRoot.appending(path: "generations", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true)
    let staging = generations.appending(
      path: ".staging-\(generationID)",
      directoryHint: .isDirectory
    )
    let destination = generationURL(generationID)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    var published = false
    defer {
      if !published { try? FileManager.default.removeItem(at: staging) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let configurationURL = staging.appending(path: "yabairc")
    let manifestURL = staging.appending(path: "manifest.json")
    try Data(composition.renderedConfiguration.utf8).write(to: configurationURL)
    try encoder.encode(manifest).write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444], ofItemAtPath: configurationURL.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444], ofItemAtPath: manifestURL.path)

    guard rename(staging.path, destination.path) == 0 else {
      throw YabaiGenerationError.system("publish generation", destination, errno)
    }
    published = true
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: destination.path)
    } catch {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: destination.path)
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return YabaiPreparedGeneration(manifest: manifest, created: true)
  }

  package func select(_ generation: YabaiPreparedGeneration) throws {
    let providerRoot = stateRoot.appending(path: "desktop/yabai", directoryHint: .isDirectory)
    let temporary = providerRoot.appending(path: ".current-\(UUID().uuidString.lowercased())")
    try FileManager.default.createSymbolicLink(
      atPath: temporary.path,
      withDestinationPath: "generations/\(generation.manifest.generationID)"
    )
    defer { try? FileManager.default.removeItem(at: temporary) }
    let current = providerRoot.appending(path: "current")
    guard rename(temporary.path, current.path) == 0 else {
      throw YabaiGenerationError.system("select generation", current, errno)
    }
  }

  package func restoreCurrent(_ generationID: String?) throws {
    let providerRoot = stateRoot.appending(path: "desktop/yabai", directoryHint: .isDirectory)
    let current = providerRoot.appending(path: "current")
    guard let generationID else {
      if unlink(current.path) != 0, errno != ENOENT {
        throw YabaiGenerationError.system("remove current pointer", current, errno)
      }
      return
    }
    guard YabaiGenerationInspector.isGenerationID(generationID) else {
      throw YabaiGenerationError.invalid("cannot restore an invalid generation identity")
    }
    let temporary = providerRoot.appending(
      path: ".current-restore-\(UUID().uuidString.lowercased())")
    try FileManager.default.createSymbolicLink(
      atPath: temporary.path,
      withDestinationPath: "generations/\(generationID)"
    )
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard rename(temporary.path, current.path) == 0 else {
      throw YabaiGenerationError.system("restore current pointer", current, errno)
    }
  }

  package func removeGeneration(_ generationID: String) throws {
    guard YabaiGenerationInspector.isGenerationID(generationID) else {
      throw YabaiGenerationError.invalid("cannot remove an invalid generation identity")
    }
    let generation = generationURL(generationID)
    guard FileManager.default.fileExists(atPath: generation.path) else { return }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: generation.path)
    for name in ["manifest.json", "yabairc"] {
      let file = generation.appending(path: name)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
      }
    }
    try FileManager.default.removeItem(at: generation)
  }

  private func generationURL(_ generationID: String) -> URL {
    stateRoot.appending(
      path: "desktop/yabai/generations/\(generationID)",
      directoryHint: .isDirectory
    )
  }
}
