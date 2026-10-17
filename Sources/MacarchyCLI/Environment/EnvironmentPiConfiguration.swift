import Darwin
import Foundation
import ThemeCore

struct EnvironmentPiOwnership: Codable, Equatable, Sendable {
  let path: String
  let originalFileExisted: Bool
  let originalMember: Data?

  enum CodingKeys: String, CodingKey {
    case path
    case originalFileExisted = "original_file_existed"
    case originalMember = "original_member"
  }

  var hasValidShape: Bool {
    guard path.hasPrefix("/"), originalFileExisted || originalMember == nil else { return false }
    guard let originalMember else { return true }
    guard originalMember.count <= 65_536 else { return false }
    return (try? EnvironmentPiDocument.member(in: Data("{".utf8) + originalMember + Data("}".utf8)))
      != nil
  }
}

struct EnvironmentPiDocument {
  private static let managedMember = Data(
    "\"\(PiAdapter.selectionKey)\": \"\(PiAdapter.themeName)\"".utf8
  )

  static func matchesManaged(_ data: Data, source: URL) throws -> Bool {
    try matchesManaged(parsed(data, source: source))
  }

  private static func matchesManaged(_ document: StrictJSONObjectDocument) -> Bool {
    guard let member = document.members.first(where: { $0.key == PiAdapter.selectionKey }) else {
      return false
    }
    return document.bytes[member.keyRange] == Array("\"\(PiAdapter.selectionKey)\"".utf8)[...]
      && document.bytes[member.valueRange] == Array("\"\(PiAdapter.themeName)\"".utf8)[...]
  }

  static func ownership(for data: Data, source: URL) throws -> EnvironmentPiOwnership {
    let document = try parsed(data, source: source)
    let original = document.members.first(where: { $0.key == PiAdapter.selectionKey }).map {
      Data(document.bytes[$0.keyRange.lowerBound..<$0.valueRange.upperBound])
    }
    return EnvironmentPiOwnership(
      path: source.path,
      originalFileExisted: true,
      originalMember: original
    )
  }

  static func applyingManaged(to data: Data, source: URL) throws -> Data {
    let document = try parsed(data, source: source)
    let candidate: Data
    if let member = document.members.first(where: { $0.key == PiAdapter.selectionKey }) {
      var bytes = Array(document.bytes[..<member.keyRange.lowerBound])
      bytes.append(contentsOf: managedMember)
      bytes.append(contentsOf: document.bytes[member.valueRange.upperBound...])
      candidate = Data(bytes)
    } else {
      do {
        candidate = try SetupOwnershipManager().addingJSONSelection(
          to: data,
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: SetupOwnershipManager.piSelectorID,
          target: source
        )
      } catch {
        throw EnvironmentLifecycleError.blocked("invalid Pi settings at \(source.path): \(error)")
      }
    }
    guard try matchesManaged(candidate, source: source) else {
      throw EnvironmentLifecycleError.blocked("cannot install the Pi theme member")
    }
    return candidate
  }

  static func restoringOriginal(
    in data: Data,
    ownership: EnvironmentPiOwnership,
    source: URL
  ) throws -> Data {
    let document = try parsed(data, source: source)
    guard let managed = document.members.first(where: { $0.key == PiAdapter.selectionKey }),
      matchesManaged(document)
    else { throw EnvironmentLifecycleError.drift(source.path) }
    let candidate: Data
    if let original = ownership.originalMember {
      var bytes = Array(document.bytes[..<managed.keyRange.lowerBound])
      bytes.append(contentsOf: original)
      bytes.append(contentsOf: document.bytes[managed.valueRange.upperBound...])
      candidate = Data(bytes)
    } else {
      do {
        candidate = try SetupOwnershipManager().removingJSONSelection(
          from: data,
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: SetupOwnershipManager.piSelectorID,
          target: source
        )
      } catch {
        throw EnvironmentLifecycleError.blocked("cannot remove the Pi theme member: \(error)")
      }
    }
    guard try matchesOriginal(candidate, ownership: ownership, source: source) else {
      throw EnvironmentLifecycleError.drift(source.path)
    }
    return candidate
  }

  static func matchesOriginal(
    _ data: Data,
    ownership: EnvironmentPiOwnership,
    source: URL
  ) throws -> Bool {
    let document = try parsed(data, source: source)
    guard let original = ownership.originalMember else {
      return !document.members.contains { $0.key == PiAdapter.selectionKey }
    }
    guard let member = document.members.first(where: { $0.key == PiAdapter.selectionKey }) else {
      return false
    }
    return Data(document.bytes[member.keyRange.lowerBound..<member.valueRange.upperBound])
      == original
  }

  static func isEmptyObject(_ data: Data, source: URL) throws -> Bool {
    try parsed(data, source: source).members.isEmpty
  }

  static func member(in data: Data, source: URL = URL(filePath: "/pi-settings.json")) throws
    -> StrictJSONObjectDocument.Member?
  {
    try parsed(data, source: source).members.first { $0.key == PiAdapter.selectionKey }
  }

  private static func parsed(_ data: Data, source: URL) throws -> StrictJSONObjectDocument {
    do {
      return try StrictJSONObjectDocument(
        data: data,
        id: SetupOwnershipManager.piSelectorID,
        target: source
      )
    } catch {
      throw EnvironmentLifecycleError.blocked("invalid Pi settings at \(source.path): \(error)")
    }
  }
}

typealias EnvironmentPiFileTransaction = EnvironmentPresetFileTransaction<EnvironmentPiOwnership>

extension EnvironmentPiOwnership: EnvironmentPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Pi settings",
    residueLabel: "Pi transaction residue",
    nonRegularMessage: "Pi settings are not an ordinary file"
  )
  static let driftLabel = "Pi"
  static let ownershipChangedMessage = "Pi ownership changed unexpectedly"
  static let replacementLabel = "Pi theme member"
  static let replacementFailureLabel: String? = nil

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.pi }

  static func managed(from current: Data?, at url: URL) throws -> Data {
    try EnvironmentPiDocument.applyingManaged(to: current ?? Data("{}\n".utf8), source: url)
  }

  static func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    try EnvironmentPiDocument.matchesManaged(data, source: url)
  }

  func restored(in current: Data, at url: URL) throws -> Data? {
    let restored = try EnvironmentPiDocument.restoringOriginal(
      in: current, ownership: self, source: url)
    if !originalFileExisted, try EnvironmentPiDocument.isEmptyObject(restored, source: url) {
      return nil
    }
    return restored
  }

  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return !originalFileExisted }
    return try EnvironmentPiDocument.matchesOriginal(data, ownership: self, source: url)
  }
}
