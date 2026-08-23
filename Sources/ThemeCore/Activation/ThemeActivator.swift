import CryptoKit
import Darwin
import Foundation

enum ThemeActivationError: Error, CustomStringConvertible, Sendable {
  case cannotReplaceCurrent(Int32)

  var description: String {
    switch self {
    case .cannotReplaceCurrent(let code):
      "Cannot atomically replace current theme pointer (errno \(code)): \(String(cString: strerror(code)))"
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
  private static let rendererVersions = ["kitty": 1, "normalized_theme": 1]

  private let root: URL
  private let faultInjector: @Sendable (ActivationCheckpoint) throws -> Void

  public init(root: URL) {
    self.init(root: root, faultInjector: { _ in })
  }

  init(
    root: URL,
    faultInjector: @escaping @Sendable (ActivationCheckpoint) throws -> Void
  ) {
    self.root = root.standardizedFileURL
    self.faultInjector = faultInjector
  }

  public func activate(package: ThemePackage) throws -> GenerationManifest {
    let generationID = "g-\(UUID().uuidString.lowercased())"
    let inputDigest = try generationInputDigest(package: package)
    try faultInjector(.inputDigested)

    let rendered = try ThemeRenderer().render(package: package, generationID: generationID)
    try faultInjector(.outputsRendered)

    let manifest = GenerationManifest(
      generationID: generationID,
      themeID: package.id,
      themeSchemaVersion: package.schemaVersion,
      inputDigest: inputDigest,
      rendererVersions: Self.rendererVersions,
      artifacts: [
        "generated/kitty.conf": digest(Data(rendered.kittyConfiguration.utf8)),
        "theme.json": digest(rendered.themeJSON),
      ]
    )

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
    try encode(manifest).write(
      to: stagingURL.appending(path: "manifest.json"), options: [.atomic])
    try faultInjector(.generationWritten)

    try makeReadOnly(stagingURL)
    try faultInjector(.generationSealed)
    try FileManager.default.moveItem(at: stagingURL, to: generationURL)
    shouldRemoveStaging = false
    try faultInjector(.generationCommitted)

    let temporaryPointer = root.appending(path: ".current-\(generationID)")
    defer { try? FileManager.default.removeItem(at: temporaryPointer) }
    try FileManager.default.createSymbolicLink(
      atPath: temporaryPointer.path,
      withDestinationPath: "generations/\(generationID)"
    )
    try faultInjector(.currentPointerReady)
    try atomicallyReplaceCurrent(with: temporaryPointer)

    return manifest
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

  private func makeReadOnly(_ generationURL: URL) throws {
    let generated = generationURL.appending(path: "generated", directoryHint: .isDirectory)
    for file in [
      generationURL.appending(path: "manifest.json"),
      generationURL.appending(path: "theme.json"),
      generated.appending(path: "kitty.conf"),
    ] {
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
