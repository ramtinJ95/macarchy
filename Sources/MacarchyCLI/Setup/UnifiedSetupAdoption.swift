import Foundation
import ThemeCore

/// A configuration unified setup may adopt, named alike in plans, approvals and adoption files.
enum UnifiedSetupAdoptionTarget: String, CaseIterable, Sendable {
  case yabai
  case keybindings
  case sketchybar
  case environment
}

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

  /// Approves exactly the digests a reviewed plan listed, keyed by adoption target.
  init(digests: [String: String]) {
    self.init(
      yabai: digests[UnifiedSetupAdoptionTarget.yabai.rawValue],
      keybindings: digests[UnifiedSetupAdoptionTarget.keybindings.rawValue],
      sketchybar: digests[UnifiedSetupAdoptionTarget.sketchybar.rawValue],
      environment: digests[UnifiedSetupAdoptionTarget.environment.rawValue]
    )
  }

  func approval(for target: UnifiedSetupAdoptionTarget) -> String? {
    switch target {
    case .yabai: yabai
    case .keybindings: keybindings
    case .sketchybar: sketchybar
    case .environment: environment
    }
  }

  var values: [String: String] {
    Dictionary(
      uniqueKeysWithValues: UnifiedSetupAdoptionTarget.allCases.compactMap { target in
        approval(for: target).map { (target.rawValue, $0) }
      })
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
      let allowed = Set(["schema_version"] + UnifiedSetupAdoptionTarget.allCases.map(\.rawValue))
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
