import Darwin
import Foundation
import ThemeCore

struct PreferencesContext: Sendable {
  let stateRoot: URL
  let targetIdentity: String

  static func live(stateRoot: URL, homeDirectory: URL) throws -> Self {
    var identifier: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var timeout = timespec(tv_sec: 1, tv_nsec: 0)
    guard gethostuuid(&identifier, &timeout) == 0 else {
      throw PreferencesError.unavailable("Cannot identify this Mac (errno \(errno)).")
    }
    return Self(
      stateRoot: stateRoot,
      targetIdentity: sha256Digest(
        Data(
          "\(UUID(uuid: identifier).uuidString)\0\(geteuid())\0\(homeDirectory.standardizedFileURL.path)"
            .utf8)))
  }
}

extension UnifiedSetupPlanContext {
  var preferencesContext: PreferencesContext {
    get throws { try .live(stateRoot: stateRoot, homeDirectory: homeDirectory) }
  }
}

struct PreferenceOwnership: Codable, Equatable, Sendable {
  let key: MacOSPreference
  let original: Bool
  let applied: Bool
}

struct PreferenceChange: Codable, Equatable, Sendable {
  let key: MacOSPreference
  let before: Bool
  let after: Bool
}

struct PreferencesTransaction: Codable, Equatable, Sendable {
  enum Phase: String, Codable {
    case applying, ready
    case rollingBack = "rolling_back"
  }
  var phase: Phase = .applying
  let after: [PreferenceOwnership]
  let changes: [PreferenceChange]
  var attemptedWrites = 0
  var uncertainWrite = false

  var writes: [PreferenceChange] { changes.filter { $0.before != $0.after } }
}

struct PreferencesState: Codable, Equatable, Sendable {
  var schemaVersion = 1
  let targetIdentity: String
  var owned: [PreferenceOwnership] = []
  var pending: PreferencesTransaction?

  func validate(target: String) throws {
    func canonical(_ records: [PreferenceOwnership]) -> Bool {
      records.map(\.key.rawValue) == Set(records.map(\.key.rawValue)).sorted()
    }
    guard schemaVersion == 1, targetIdentity == target, canonical(owned) else {
      throw PreferencesError.invalid(
        "Unsupported schema, different user/Mac, or duplicate/unordered ownership.")
    }
    guard let pending else { return }
    guard canonical(pending.after), !pending.changes.isEmpty,
      pending.changes.map(\.key.rawValue) == Set(pending.changes.map(\.key.rawValue)).sorted(),
      (0...pending.writes.count).contains(pending.attemptedWrites),
      pending.phase != .ready
        || (pending.attemptedWrites == pending.writes.count && !pending.uncertainWrite)
    else { throw PreferencesError.invalid("Malformed preference transaction.") }
    let before = Dictionary(uniqueKeysWithValues: owned.map { ($0.key, $0) })
    let after = Dictionary(uniqueKeysWithValues: pending.after.map { ($0.key, $0) })
    let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    guard Set(pending.changes.map(\.key)) == changed else {
      throw PreferencesError.invalid("Transaction does not match its ownership changes.")
    }
    for change in pending.changes {
      let old = before[change.key]
      let new = after[change.key]
      guard old == nil || old?.applied == change.before,
        new == nil || new?.applied == change.after,
        old != nil || new?.original == change.before,
        new != nil || old?.original == change.after,
        old == nil || new == nil || old?.original == new?.original
      else {
        throw PreferencesError.invalid(
          "Inconsistent restoration evidence for \(change.key.rawValue).")
      }
    }
  }
}

struct PreferencesStore: Sendable {
  let context: PreferencesContext
  var url: URL { context.stateRoot.appending(path: "state/preferences/state.json") }

  func read() throws -> PreferencesState {
    let data: Data
    do { data = try BoundedRegularFile.read(at: url).data } catch BoundedRegularFileError.system(
      operation: "open", code: ENOENT)
    {
      return PreferencesState(targetIdentity: context.targetIdentity)
    }
    do {
      _ = try StrictJSONObjectDocument(data: data, id: "macos_preferences", target: url)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let state = try decoder.decode(PreferencesState.self, from: data)
      try state.validate(target: context.targetIdentity)
      let canonical = Data(try renderJSON(state).utf8)
      guard let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
        let expected = try JSONSerialization.jsonObject(with: canonical) as? NSDictionary,
        actual == expected
      else { throw PreferencesError.invalid("Unknown, missing, or noncanonical receipt fields.") }
      return state
    } catch { throw PreferencesError.invalid("Cannot read \(url.path): \(error)") }
  }

  func write(_ state: PreferencesState) throws {
    try state.validate(target: context.targetIdentity)
    try writeBoundedEvidenceJSON(
      state, to: url, temporaryPrefix: ".preferences-",
      tooLargeError: PreferencesError.invalid("Receipt exceeds 1 MiB."),
      replaceError: { PreferencesError.invalid("Cannot replace receipt (errno \($0)).") })
  }
}
