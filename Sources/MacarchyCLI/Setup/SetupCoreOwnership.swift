import Darwin
import Foundation
import ThemeCore

struct SetupCoreOwnership: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let themeGenerationID: String
  let originalAppearance: ThemeAppearance

  init(themeGenerationID: String, originalAppearance: ThemeAppearance) {
    schemaVersion = Self.schemaVersion
    self.themeGenerationID = themeGenerationID
    self.originalAppearance = originalAppearance
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case themeGenerationID = "theme_generation_id"
    case originalAppearance = "original_appearance"
  }
}

struct SetupCoreOwnershipStore: Sendable {
  let stateRoot: URL

  var url: URL {
    stateRoot.appending(path: "state/setup/core.json")
  }

  func read() throws -> SetupCoreOwnership? {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: url).data
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT) {
      return nil
    } catch {
      throw SetupCoreOwnershipError.invalid(String(describing: error))
    }
    do {
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard
        let object,
        Set(object.keys) == ["schema_version", "theme_generation_id", "original_appearance"]
      else {
        throw SetupCoreOwnershipError.invalid("contains unknown or missing fields")
      }
      let ownership = try JSONDecoder().decode(SetupCoreOwnership.self, from: data)
      guard ownership.schemaVersion == SetupCoreOwnership.schemaVersion else {
        throw SetupCoreOwnershipError.invalid(
          "unsupported schema version \(ownership.schemaVersion)"
        )
      }
      guard validGenerationID(ownership.themeGenerationID) else {
        throw SetupCoreOwnershipError.invalid("theme generation identifier is invalid")
      }
      return ownership
    } catch let error as SetupCoreOwnershipError {
      throw error
    } catch {
      throw SetupCoreOwnershipError.invalid(String(describing: error))
    }
  }

  func write(_ ownership: SetupCoreOwnership) throws {
    guard try read() == nil else { throw SetupCoreOwnershipError.alreadyExists }
    try writeBoundedEvidenceJSON(
      ownership,
      to: url,
      temporaryPrefix: ".core-",
      tooLargeError: SetupCoreOwnershipError.invalid("exceeds the 1 MiB file limit"),
      replaceError: { SetupCoreOwnershipError.system("replace ownership", $0) }
    )
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      throw SetupCoreOwnershipError.invalid(String(describing: error))
    }
  }

  private func validGenerationID(_ value: String) -> Bool {
    guard value.hasPrefix("g-"), value == value.lowercased() else { return false }
    return UUID(uuidString: String(value.dropFirst(2))) != nil
  }
}

enum SetupCoreOwnershipError: Error, CustomStringConvertible, Sendable {
  case alreadyExists
  case invalid(String)
  case system(String, Int32)

  var description: String {
    switch self {
    case .alreadyExists:
      "Setup core ownership already exists"
    case .invalid(let reason):
      "Invalid setup core ownership: \(reason)"
    case .system(let operation, let code):
      "Cannot \(operation) setup core ownership (errno \(code)): \(String(cString: strerror(code)))"
    }
  }
}
