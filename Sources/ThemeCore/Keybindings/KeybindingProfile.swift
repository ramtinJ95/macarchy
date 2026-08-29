import Darwin
import Foundation
import TOMLDecoder

package struct KeybindingProfile: Equatable, Sendable {
  package let sourceURL: URL?
  package let overrideURL: URL?
  package let metadataURL: URL?
  package let disabledIdentities: [String]

  package static let empty = KeybindingProfile(
    sourceURL: nil,
    overrideURL: nil,
    metadataURL: nil,
    disabledIdentities: []
  )
}

package enum KeybindingProfileError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL, String)
  case invalid(URL, String)

  package var description: String {
    switch self {
    case .cannotRead(let source, let reason):
      "\(source.path): cannot read keybinding profile: \(reason)"
    case .invalid(let source, let reason):
      "\(source.path): invalid keybinding profile: \(reason)"
    }
  }
}

package struct KeybindingProfileLoader: Sendable {
  package init() {}

  package func load(at source: URL, required: Bool) throws -> KeybindingProfile {
    var metadata = stat()
    guard lstat(source.path, &metadata) == 0 else {
      if errno == ENOENT, !required { return .empty }
      throw KeybindingProfileError.cannotRead(source, Self.systemError(errno))
    }

    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: resolved, maximumSize: 65_536).data
    } catch {
      throw KeybindingProfileError.cannotRead(source, String(describing: error))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw KeybindingProfileError.invalid(source, "profile is not valid UTF-8")
    }
    return try decode(text, source: source, resolvedSource: resolved)
  }

  package func decode(
    _ text: String,
    source: URL,
    resolvedSource: URL? = nil
  ) throws -> KeybindingProfile {
    let index: TOMLSourceIndex
    do {
      index = try TOMLSourceIndex(
        text: text,
        file: source,
        syntaxRole: "Keybinding profile"
      )
    } catch {
      throw KeybindingProfileError.invalid(source, String(describing: error))
    }

    if let table = index.tables.first(where: { $0.path != "keybindings" || $0.isArray }) {
      throw KeybindingProfileError.invalid(
        source,
        "line \(table.line), column \(table.column): unknown table '\(table.path)'"
      )
    }
    let allowedFields = Set([
      "schema_version",
      "keybindings.override",
      "keybindings.metadata",
      "keybindings.disabled",
    ])
    if let field = index.fields.first(where: { !allowedFields.contains($0.path) }) {
      throw KeybindingProfileError.invalid(
        source,
        "line \(field.line), column \(field.column): unknown key '\(field.path)'"
      )
    }

    let document: ProfileDocument
    do {
      document = try TOMLDecoder().decode(ProfileDocument.self, from: text)
    } catch {
      throw KeybindingProfileError.invalid(source, String(describing: error))
    }
    guard document.schemaVersion == 1 else {
      throw KeybindingProfileError.invalid(
        source,
        "unsupported schema_version \(document.schemaVersion); expected 1"
      )
    }

    let options = document.keybindings ?? KeybindingsDocument()
    guard options.disabled.count <= 1_024 else {
      throw KeybindingProfileError.invalid(source, "disabled contains more than 1024 identities")
    }
    guard Set(options.disabled).count == options.disabled.count else {
      throw KeybindingProfileError.invalid(source, "disabled identities must be unique")
    }
    let parser = SkhdConfigurationParser()
    if let identity = options.disabled.first(where: { !parser.isCanonicalIdentity($0) }) {
      throw KeybindingProfileError.invalid(
        source,
        "disabled identity '\(identity)' is not a normalized skhd chord"
      )
    }

    let base = (resolvedSource ?? source).standardizedFileURL.deletingLastPathComponent()
    return KeybindingProfile(
      sourceURL: source.standardizedFileURL,
      overrideURL: try options.override.map {
        try Self.resolvePortablePath($0, field: "keybindings.override", base: base, source: source)
      },
      metadataURL: try options.metadata.map {
        try Self.resolvePortablePath($0, field: "keybindings.metadata", base: base, source: source)
      },
      disabledIdentities: options.disabled
    )
  }

  private static func resolvePortablePath(
    _ path: String,
    field: String,
    base: URL,
    source: URL
  ) throws -> URL {
    guard path == path.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
      throw KeybindingProfileError.invalid(source, "\(field) must be a nonempty relative path")
    }
    guard !NSString(string: path).isAbsolutePath else {
      throw KeybindingProfileError.invalid(source, "\(field) must be a relative path")
    }
    let resolved = base.appending(path: path).standardizedFileURL
    let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
    guard resolved.path.hasPrefix(prefix) else {
      throw KeybindingProfileError.invalid(source, "\(field) must stay beside the profile")
    }
    return resolved
  }

  private static func systemError(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (errno \(code))"
  }
}

private struct ProfileDocument: Decodable {
  let schemaVersion: Int
  let keybindings: KeybindingsDocument?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case keybindings
  }
}

private struct KeybindingsDocument: Decodable {
  let override: String?
  let metadata: String?
  let disabled: [String]

  init(override: String? = nil, metadata: String? = nil, disabled: [String] = []) {
    self.override = override
    self.metadata = metadata
    self.disabled = disabled
  }

  enum CodingKeys: CodingKey {
    case override, metadata, disabled
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    override = try container.decodeIfPresent(String.self, forKey: .override)
    metadata = try container.decodeIfPresent(String.self, forKey: .metadata)
    disabled = try container.decodeIfPresent([String].self, forKey: .disabled) ?? []
  }
}
