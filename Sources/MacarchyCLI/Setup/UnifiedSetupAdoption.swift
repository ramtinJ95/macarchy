import Foundation
import ThemeCore

struct UnifiedSetupAdoptionApprovals: Equatable, Sendable {
  static let none = Self()

  let yabai: String?
  let keybindings: String?
  let sketchybar: String?
  let environment: String?

  init(
    yabai: String? = nil,
    keybindings: String? = nil,
    sketchybar: String? = nil,
    environment: String? = nil
  ) {
    self.yabai = yabai
    self.keybindings = keybindings
    self.sketchybar = sketchybar
    self.environment = environment
  }

  var values: [String: String] {
    [
      "yabai": yabai,
      "keybindings": keybindings,
      "sketchybar": sketchybar,
      "environment": environment,
    ].compactMapValues { $0 }
  }

  func validate(required evidence: [UnifiedSetupAdoptionEvidence]) throws {
    let required = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0.digest) })
    let provided = values
    for (id, digest) in provided {
      guard let expected = required[id] else {
        throw UnifiedSetupAdoptionError("No adoption is currently required for '\(id)'.")
      }
      guard digest == expected else {
        throw UnifiedSetupAdoptionError(
          "Adoption approval for '\(id)' does not match the current reviewed plan."
        )
      }
    }
    let missing = required.keys.filter { provided[$0] == nil }.sorted()
    guard missing.isEmpty else {
      throw UnifiedSetupAdoptionError(
        "Missing adoption approval for: \(missing.joined(separator: ", "))."
      )
    }
  }
}

struct UnifiedSetupAdoptionFile {
  static func load(at url: URL) throws -> UnifiedSetupAdoptionApprovals {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: url).data
    } catch {
      throw UnifiedSetupAdoptionError("Cannot read adoption file: \(error)")
    }

    do {
      _ = try StrictJSONObjectDocument(data: data, id: "adoption_file", target: url)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw UnifiedSetupAdoptionError("Adoption file must contain one JSON object.")
      }
      let allowed = Set([
        "schema_version", "yabai", "keybindings", "sketchybar", "environment",
      ])
      guard Set(object.keys).isSubset(of: allowed), object["schema_version"] != nil else {
        throw UnifiedSetupAdoptionError("Adoption file contains unknown or missing fields.")
      }
      let file = try JSONDecoder().decode(Contents.self, from: data)
      guard file.schemaVersion == 1 else {
        throw UnifiedSetupAdoptionError(
          "Unsupported adoption file schema version \(file.schemaVersion)."
        )
      }
      return UnifiedSetupAdoptionApprovals(
        yabai: file.yabai,
        keybindings: file.keybindings,
        sketchybar: file.sketchybar,
        environment: file.environment
      )
    } catch let error as UnifiedSetupAdoptionError {
      throw error
    } catch {
      throw UnifiedSetupAdoptionError("Invalid adoption file: \(error)")
    }
  }

  private struct Contents: Decodable {
    let schemaVersion: Int
    let yabai: String?
    let keybindings: String?
    let sketchybar: String?
    let environment: String?

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case yabai, keybindings, sketchybar, environment
    }
  }
}

struct UnifiedSetupAdoptionError: Error, CustomStringConvertible, Sendable {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
