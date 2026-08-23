import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Synchronization

enum ThemeActivationError: Error, CustomStringConvertible, Sendable {
  case activationLock(operation: String, code: Int32)
  case cannotReplaceCurrent(Int32)
  case corruptGeneration(id: String, reason: String)
  case generatedFileTooLarge(path: String, size: Int)

  var description: String {
    switch self {
    case .activationLock(let operation, let code):
      "Cannot \(operation) activation lock (errno \(code)): \(String(cString: strerror(code)))"
    case .cannotReplaceCurrent(let code):
      "Cannot atomically replace current theme pointer (errno \(code)): \(String(cString: strerror(code)))"
    case .corruptGeneration(let id, let reason):
      "Generation '\(id)' matches the requested theme inputs but is corrupt: \(reason)"
    case .generatedFileTooLarge(let path, let size):
      "Generated file '\(path)' is \(size) bytes; limit is 1 MiB"
    }
  }
}

enum ActivationCheckpoint: CaseIterable, Sendable {
  case inputDigested
  case outputsRendered
  case generationWritten
  case generationSealed
  case generationCommitted
  case currentPointerReady
}

public struct ThemeActivator: Sendable {
  private static let maximumGenerationFileSize = 1_048_576
  // lockf is process-scoped, so sibling threads also need a mutex.
  private static let processActivationMutex = Mutex<Void>(())
  private static let rendererVersions = ["kitty": 1, "normalized_theme": 1]

  private let root: URL
  private let faultInjector: @Sendable (ActivationCheckpoint) throws -> Void
  private let onThemeChanged: @Sendable (ThemeChanged) -> Void
  private let postDarwinNotification: @Sendable (String) -> Void

  public init(
    root: URL,
    onThemeChanged: @escaping @Sendable (ThemeChanged) -> Void = { _ in }
  ) {
    self.init(
      root: root,
      faultInjector: { _ in },
      onThemeChanged: onThemeChanged,
      postDarwinNotification: Self.postDarwinNotification
    )
  }

  init(
    root: URL,
    faultInjector: @escaping @Sendable (ActivationCheckpoint) throws -> Void,
    onThemeChanged: @escaping @Sendable (ThemeChanged) -> Void = { _ in },
    postDarwinNotification: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.root = root.standardizedFileURL
    self.faultInjector = faultInjector
    self.onThemeChanged = onThemeChanged
    self.postDarwinNotification = postDarwinNotification
  }

  public func activate(package: ThemePackage) throws -> GenerationManifest {
    let manifest = try Self.processActivationMutex.withLock { _ in
      let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: runDirectory,
        withIntermediateDirectories: true
      )

      let lockURL = runDirectory.appending(path: "activation.lock")
      let descriptor = lockURL.path.withCString {
        Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      }
      guard descriptor >= 0 else {
        throw ThemeActivationError.activationLock(operation: "open", code: errno)
      }
      defer { Darwin.close(descriptor) }

      while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
        if errno == EINTR { continue }
        throw ThemeActivationError.activationLock(operation: "acquire", code: errno)
      }

      return try activateLocked(package: package)
    }

    onThemeChanged(ThemeChanged(manifest: manifest))
    postDarwinNotification(ThemeChanged.darwinNotificationName)
    return manifest
  }

  private static func postDarwinNotification(named name: String) {
    // The filesystem remains authoritative; the Darwin notification carries no payload.
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(name as CFString),
      nil,
      nil,
      true
    )
  }

  private func activateLocked(package: ThemePackage) throws -> GenerationManifest {
    let inputDigest = try generationInputDigest(package: package)
    try faultInjector(.inputDigested)

    if let reusable = try reusableGeneration(inputDigest: inputDigest, package: package) {
      try replaceCurrent(with: reusable.generationID)
      return reusable
    }

    let generationID = "g-\(UUID().uuidString.lowercased())"
    let rendered = try ThemeRenderer().render(package: package, generationID: generationID)
    try faultInjector(.outputsRendered)
    for (path, data) in rendered.files {
      try requireGeneratedFileSize(data, path: path)
    }

    let manifest = GenerationManifest(
      generationID: generationID,
      themeID: package.id,
      themeSchemaVersion: package.schemaVersion,
      inputDigest: inputDigest,
      rendererVersions: Self.rendererVersions,
      artifacts: rendered.files.mapValues(digest)
    )
    let manifestData = try encode(manifest)
    try requireGeneratedFileSize(manifestData, path: "manifest.json")

    let generationsRoot = root.appending(path: "generations", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: generationsRoot, withIntermediateDirectories: true)

    let stagingURL = generationsRoot.appending(
      path: ".staging-\(generationID)", directoryHint: .isDirectory)
    let generationURL = generationsRoot.appending(path: generationID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)

    var shouldRemoveStaging = true
    defer {
      if shouldRemoveStaging {
        makeWritableForRemoval(stagingURL)
        try? FileManager.default.removeItem(at: stagingURL)
      }
    }

    try ThemeRenderer().write(rendered, to: stagingURL)
    try manifestData.write(to: stagingURL.appending(path: "manifest.json"), options: [.atomic])
    try faultInjector(.generationWritten)

    try makeReadOnly(stagingURL)
    try faultInjector(.generationSealed)
    try FileManager.default.moveItem(at: stagingURL, to: generationURL)
    shouldRemoveStaging = false
    try faultInjector(.generationCommitted)

    try replaceCurrent(with: generationID)

    return manifest
  }

  private func reusableGeneration(
    inputDigest: String,
    package: ThemePackage
  ) throws -> GenerationManifest? {
    let generationsRoot = root.appending(path: "generations", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: generationsRoot.path) else { return nil }

    let generationURLs = try FileManager.default.contentsOfDirectory(
      at: generationsRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

    var reusable: GenerationManifest?
    for generationURL in generationURLs {
      guard
        (try? generationURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else { continue }

      let manifestURL = generationURL.appending(path: "manifest.json")
      guard
        let manifestFile = safelyReadManifest(at: manifestURL),
        let object = manifestObject(in: manifestFile.data),
        object["input_digest"] as? String == inputDigest
      else { continue }

      try requireReusable(
        Set(object.keys) == GenerationManifest.encodedKeys,
        generationURL,
        "manifest.json contains unknown or missing fields"
      )
      try requireReusable(
        manifestFile.permissions & 0o222 == 0,
        generationURL,
        "manifest.json is writable"
      )

      let manifest: GenerationManifest
      do {
        manifest = try JSONDecoder().decode(GenerationManifest.self, from: manifestFile.data)
      } catch {
        throw corruptGeneration(
          generationURL,
          reason: "manifest.json cannot be decoded: \(String(describing: error))"
        )
      }
      try validateReusableGeneration(
        manifest, at: generationURL, inputDigest: inputDigest, package: package)
      reusable = reusable ?? manifest
    }
    return reusable
  }

  private func safelyReadManifest(at url: URL) -> BoundedFile? {
    try? readBoundedRegularFile(at: url)
  }

  private func manifestObject(in data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func readBoundedRegularFile(at url: URL) throws -> BoundedFile {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw BoundedFileError.system(operation: "open", code: errno)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw BoundedFileError.system(operation: "fstat", code: errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw BoundedFileError.notRegular
    }
    guard metadata.st_size >= 0, metadata.st_size <= Self.maximumGenerationFileSize else {
      throw BoundedFileError.tooLarge
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count <= Self.maximumGenerationFileSize {
      let remaining = min(
        buffer.count, Self.maximumGenerationFileSize + 1 - data.count)
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, remaining)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw BoundedFileError.system(operation: "read", code: errno)
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count <= Self.maximumGenerationFileSize else {
      throw BoundedFileError.tooLarge
    }
    return BoundedFile(data: data, permissions: Int(metadata.st_mode & 0o777))
  }

  private func validateReusableGeneration(
    _ manifest: GenerationManifest,
    at generationURL: URL,
    inputDigest: String,
    package: ThemePackage
  ) throws {
    let generationID = generationURL.lastPathComponent
    try requireReusable(
      manifest.manifestSchemaVersion == GenerationManifest.currentSchemaVersion,
      generationURL,
      "unsupported manifest schema version \(manifest.manifestSchemaVersion)"
    )
    try requireReusable(
      manifest.generationID == generationID,
      generationURL,
      "manifest generation_id '\(manifest.generationID)' does not match its directory"
    )
    try requireReusable(
      generationID.hasPrefix("g-")
        && generationID == generationID.lowercased()
        && UUID(uuidString: String(generationID.dropFirst(2))) != nil,
      generationURL,
      "generation identifier is not in g-<uuid> form"
    )
    try requireReusable(
      manifest.themeID == package.id,
      generationURL,
      "manifest theme_id '\(manifest.themeID)' does not match '\(package.id)'"
    )
    try requireReusable(
      manifest.inputDigest == inputDigest,
      generationURL,
      "decoded input digest does not match the requested inputs"
    )
    try requireReusable(
      manifest.themeSchemaVersion == package.schemaVersion,
      generationURL,
      "manifest theme schema version does not match the package"
    )
    try requireReusable(
      manifest.rendererVersions == Self.rendererVersions,
      generationURL,
      "renderer versions do not match the current renderers"
    )

    try requireReusable(
      Set(manifest.artifacts.keys) == ThemeRenderer.outputPaths,
      generationURL,
      "artifact manifest does not contain exactly the required outputs"
    )

    _ = try validateReadOnlyItem(
      generationURL, expectedType: .typeDirectory, generationURL: generationURL)
    let generatedURL = generationURL.appending(path: "generated", directoryHint: .isDirectory)
    _ = try validateReadOnlyItem(
      generatedURL, expectedType: .typeDirectory, generationURL: generationURL)

    for path in ThemeRenderer.outputPaths.sorted() {
      let artifactURL = generationURL.appending(path: path)
      let artifact: BoundedFile
      do {
        artifact = try readBoundedRegularFile(at: artifactURL)
      } catch {
        throw corruptGeneration(
          generationURL,
          reason: "cannot safely read \(path): \(String(describing: error))"
        )
      }
      try requireReusable(
        artifact.permissions & 0o222 == 0,
        generationURL,
        "\(path) is writable"
      )
      try requireReusable(
        manifest.artifacts[path] == digest(artifact.data),
        generationURL,
        "artifact digest does not match \(path)"
      )
    }
  }

  @discardableResult
  private func validateReadOnlyItem(
    _ itemURL: URL,
    expectedType: FileAttributeType,
    generationURL: URL
  ) throws -> [FileAttributeKey: Any] {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: itemURL.path)
    } catch {
      throw corruptGeneration(
        generationURL,
        reason: "cannot inspect \(itemURL.lastPathComponent): \(error.localizedDescription)"
      )
    }
    try requireReusable(
      attributes[.type] as? FileAttributeType == expectedType,
      generationURL,
      "\(itemURL.lastPathComponent) has an invalid filesystem type"
    )
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    try requireReusable(
      permissions.map { $0 & 0o222 == 0 } == true,
      generationURL,
      "\(itemURL.lastPathComponent) is writable"
    )
    return attributes
  }

  private func requireReusable(
    _ condition: @autoclosure () -> Bool,
    _ generationURL: URL,
    _ reason: String
  ) throws {
    guard condition() else { throw corruptGeneration(generationURL, reason: reason) }
  }

  private func corruptGeneration(_ generationURL: URL, reason: String) -> ThemeActivationError {
    .corruptGeneration(id: generationURL.lastPathComponent, reason: reason)
  }

  private func replaceCurrent(with generationID: String) throws {
    let temporaryPointer = root.appending(
      path: ".current-\(generationID)-\(UUID().uuidString.lowercased())")
    defer { try? FileManager.default.removeItem(at: temporaryPointer) }
    try FileManager.default.createSymbolicLink(
      atPath: temporaryPointer.path,
      withDestinationPath: "generations/\(generationID)"
    )
    try faultInjector(.currentPointerReady)
    try atomicallyReplaceCurrent(with: temporaryPointer)
  }

  private func generationInputDigest(package: ThemePackage) throws -> String {
    let wallpaperURL = package.packageURL.appending(path: package.wallpaper.path)
    let input = GenerationInput(
      manifestSchemaVersion: GenerationManifest.currentSchemaVersion,
      themeSchemaVersion: package.schemaVersion,
      themeID: package.id,
      appearance: package.appearance,
      semantic: package.semantic,
      terminal: package.terminal,
      wallpaperDigest: digest(try Data(contentsOf: wallpaperURL)),
      mappings: package.mappings,
      rendererVersions: Self.rendererVersions
    )
    return digest(try encode(input))
  }

  private func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0a)
    return data
  }

  private func digest(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func requireGeneratedFileSize(_ data: Data, path: String) throws {
    guard data.count <= Self.maximumGenerationFileSize else {
      throw ThemeActivationError.generatedFileTooLarge(path: path, size: data.count)
    }
  }

  private func makeReadOnly(_ generationURL: URL) throws {
    let generated = generationURL.appending(path: "generated", directoryHint: .isDirectory)
    let files =
      [generationURL.appending(path: "manifest.json")]
      + ThemeRenderer.outputPaths.map { generationURL.appending(path: $0) }
    for file in files {
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: generated.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: generationURL.path)
  }

  private func makeWritableForRemoval(_ generationURL: URL) {
    let generated = generationURL.appending(path: "generated", directoryHint: .isDirectory)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: generationURL.path)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: generated.path)
  }

  private func atomicallyReplaceCurrent(with temporaryPointer: URL) throws {
    let current = root.appending(path: "current")
    let result = temporaryPointer.path.withCString { source in
      current.path.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard result == 0 else {
      throw ThemeActivationError.cannotReplaceCurrent(errno)
    }
  }
}

private struct BoundedFile {
  let data: Data
  let permissions: Int
}

private enum BoundedFileError: Error, CustomStringConvertible, Sendable {
  case notRegular
  case system(operation: String, code: Int32)
  case tooLarge

  var description: String {
    switch self {
    case .notRegular:
      "not a regular file"
    case .system(let operation, let code):
      "\(operation) failed (errno \(code)): \(String(cString: strerror(code)))"
    case .tooLarge:
      "exceeds the 1 MiB generation file limit"
    }
  }
}

private struct GenerationInput: Encodable {
  let manifestSchemaVersion: Int
  let themeSchemaVersion: Int
  let themeID: String
  let appearance: ThemeAppearance
  let semantic: SemanticColors
  let terminal: TerminalColors
  let wallpaperDigest: String
  let mappings: [String: String]
  let rendererVersions: [String: Int]

  enum CodingKeys: String, CodingKey {
    case manifestSchemaVersion = "manifest_schema_version"
    case themeSchemaVersion = "theme_schema_version"
    case themeID = "theme_id"
    case appearance, semantic, terminal, mappings
    case wallpaperDigest = "wallpaper_digest"
    case rendererVersions = "renderer_versions"
  }
}
