import Darwin
import Foundation

package enum KeybindingGenerationStatus: String, Codable, Sendable {
  case missing
  case current
  case invalid
}

package struct KeybindingGenerationInspection: Equatable, Sendable {
  package let status: KeybindingGenerationStatus
  package let generationID: String?
  package let inputDigest: String?
  package let renderedDigest: String?
  package let message: String?

  package static let missing = KeybindingGenerationInspection(
    status: .missing,
    generationID: nil,
    inputDigest: nil,
    renderedDigest: nil,
    message: nil
  )
}

package struct KeybindingGenerationInspector: Sendable {
  package init() {}

  package func inspect(stateRoot: URL) -> KeybindingGenerationInspection {
    let keybindingsRoot = stateRoot.appending(
      path: "keybindings",
      directoryHint: .isDirectory
    )
    let current = keybindingsRoot.appending(path: "current")
    var currentMetadata = stat()
    guard lstat(current.path, &currentMetadata) == 0 else {
      if errno == ENOENT { return .missing }
      return invalid("cannot inspect current pointer: \(Self.systemError(errno))")
    }
    guard currentMetadata.st_mode & S_IFMT == S_IFLNK else {
      return invalid("current is not a symbolic link")
    }

    let destination: String
    do {
      destination = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
    } catch {
      return invalid("cannot read current pointer: \(error)")
    }
    let components = destination.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2, components[0] == "generations" else {
      return invalid("current target must be generations/k-<uuid>")
    }
    let generationID = String(components[1])
    guard Self.isGenerationID(generationID) else {
      return invalid("current generation identity is invalid")
    }

    let generation = keybindingsRoot.appending(
      path: destination,
      directoryHint: .isDirectory
    )
    var generationMetadata = stat()
    guard lstat(generation.path, &generationMetadata) == 0,
      generationMetadata.st_mode & S_IFMT == S_IFDIR
    else {
      return invalid("current generation directory is missing or unsafe")
    }
    guard generationMetadata.st_mode & 0o222 == 0 else {
      return invalid("current generation directory is writable")
    }

    let manifestURL = generation.appending(path: "manifest.json")
    let manifestData: Data
    do {
      let file = try BoundedRegularFile.read(at: manifestURL, maximumSize: 65_536)
      guard file.permissions & 0o222 == 0 else {
        return invalid("current generation manifest is writable")
      }
      manifestData = file.data
    } catch {
      return invalid("cannot read current generation manifest: \(error)")
    }

    let manifest: KeybindingGenerationManifest
    do {
      try Self.validateManifestKeys(manifestData)
      manifest = try JSONDecoder().decode(KeybindingGenerationManifest.self, from: manifestData)
    } catch {
      return invalid("invalid current generation manifest: \(error)")
    }
    guard manifest.schemaVersion == 1 else {
      return invalid("unsupported current generation schema \(manifest.schemaVersion)")
    }
    guard manifest.generationID == generationID else {
      return invalid("current pointer and manifest generation identities disagree")
    }
    guard manifest.rendererVersion == KeybindingComposer.rendererVersion else {
      return invalid("current generation renderer version is unsupported")
    }
    guard isSHA256Digest(manifest.inputDigest) else {
      return invalid("current generation input digest is invalid")
    }
    guard Set(manifest.artifacts.keys) == ["skhdrc"],
      let expectedDigest = manifest.artifacts["skhdrc"],
      isSHA256Digest(expectedDigest)
    else {
      return invalid("current generation artifact manifest is invalid")
    }

    let configurationURL = generation.appending(path: "skhdrc")
    do {
      let file = try BoundedRegularFile.read(at: configurationURL)
      guard file.permissions & 0o222 == 0 else {
        return invalid("current generated skhdrc is writable")
      }
      guard sha256Digest(file.data) == expectedDigest else {
        return invalid("current generated skhdrc digest does not match its manifest")
      }
    } catch {
      return invalid("cannot read current generated skhdrc: \(error)")
    }

    return KeybindingGenerationInspection(
      status: .current,
      generationID: generationID,
      inputDigest: manifest.inputDigest,
      renderedDigest: expectedDigest,
      message: nil
    )
  }

  private func invalid(_ message: String) -> KeybindingGenerationInspection {
    KeybindingGenerationInspection(
      status: .invalid,
      generationID: nil,
      inputDigest: nil,
      renderedDigest: nil,
      message: message
    )
  }

  private static func validateManifestKeys(_ data: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw KeybindingGenerationManifestError("manifest root must be an object")
    }
    let allowed = Set(KeybindingGenerationManifest.CodingKeys.allCases.map(\.stringValue))
    let unknown = Set(object.keys).subtracting(allowed)
    guard unknown.isEmpty else {
      throw KeybindingGenerationManifestError(
        "unknown fields: \(unknown.sorted().joined(separator: ", "))"
      )
    }
  }

  private static func isGenerationID(_ value: String) -> Bool {
    value.hasPrefix("k-")
      && value == value.lowercased()
      && UUID(uuidString: String(value.dropFirst(2))) != nil
  }

  private static func systemError(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (errno \(code))"
  }
}

package struct KeybindingGenerationManifest: Codable, Equatable, Sendable {
  package let schemaVersion: Int
  package let generationID: String
  package let rendererVersion: Int
  package let inputDigest: String
  package let artifacts: [String: String]

  package init(
    generationID: String,
    inputDigest: String,
    renderedDigest: String
  ) {
    schemaVersion = 1
    self.generationID = generationID
    rendererVersion = KeybindingComposer.rendererVersion
    self.inputDigest = inputDigest
    artifacts = ["skhdrc": renderedDigest]
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case rendererVersion = "renderer_version"
    case inputDigest = "input_digest"
    case artifacts
  }
}

private struct KeybindingGenerationManifestError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
