import Darwin
import Foundation
import ThemeCore

struct SetupPackageAdoptionLedger: Codable, Equatable, Sendable {
  struct Declaration: Codable, Equatable, Sendable {
    let source: String
    let layer: String
    let sourcePath: String?
    let selectionField: String?
  }

  struct Entry: Codable, Equatable, Sendable {
    let identity: HomebrewPackageIdentity
    let versions: [String]
    let receipts: [HomebrewReceiptEvidence]
    let declarations: [Declaration]
    let approvalDigest: String

    func status(in observation: HomebrewPackageObservation) -> String {
      guard observation.issues.isEmpty else { return "unknown" }
      let sameToken = observation.packages.filter {
        $0.kind == identity.kind && $0.token == identity.token
      }
      guard !sameToken.isEmpty else { return "missing" }
      guard sameToken.count == 1, let installed = sameToken.first,
        installed.issue == nil, installed.identity != nil, !installed.receipts.isEmpty
      else { return "unknown" }
      return installed.identity == identity && installed.versions == versions
        && installed.receipts == receipts ? "adopted" : "changed"
    }
  }

  let schemaVersion: Int
  let contextDigest: String
  let entries: [Entry]

  init(contextDigest: String, entries: [Entry]) {
    schemaVersion = 1
    self.contextDigest = contextDigest
    self.entries = entries.sorted { $0.identity.key < $1.identity.key }
  }
}

enum SetupPackageAdoptionState: Sendable {
  case available(SetupPackageAdoptionLedger?)
  case unavailable(String)

  var ledger: SetupPackageAdoptionLedger? {
    if case .available(let ledger) = self { return ledger }
    return nil
  }

  var issue: String? {
    if case .unavailable(let issue) = self { return issue }
    return nil
  }
}

struct SetupPackageAdoptionStore: Sendable {
  let stateRoot: URL
  let homeDirectory: URL

  var url: URL { stateRoot.appending(path: "state/setup/packages.json") }

  var contextDigest: String {
    sha256Digest(
      Data(
        [homeDirectory, stateRoot].map(\.standardizedFileURL.path).joined(separator: "\0").utf8
      ))
  }

  func inspect() -> SetupPackageAdoptionState {
    do { return .available(try read()) } catch { return .unavailable(String(describing: error)) }
  }

  func read() throws -> SetupPackageAdoptionLedger? {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: url).data
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT) {
      return nil
    } catch {
      throw SetupPackageAdoptionError("Cannot read package adoption ledger: \(error)")
    }
    do {
      _ = try StrictJSONObjectDocument(data: data, id: "package_adoption", target: url)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let ledger = try decoder.decode(SetupPackageAdoptionLedger.self, from: data)
      // Round-trip the closed schema to reject unknown fields at every level,
      // not just at the top of the ownership document.
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
      let canonical =
        try JSONSerialization.jsonObject(with: encoder.encode(ledger)) as? NSDictionary
      let keys = ledger.entries.map(\.identity.key)
      guard original == canonical, ledger.schemaVersion == 1,
        ledger.contextDigest == contextDigest, !ledger.entries.isEmpty,
        ledger.entries.count <= 1024,
        keys == keys.sorted(), Set(keys).count == keys.count,
        ledger.entries.allSatisfy(validEntry)
      else {
        throw SetupPackageAdoptionError("Invalid package adoption schema, context or evidence.")
      }
      return ledger
    } catch let error as SetupPackageAdoptionError {
      throw error
    } catch {
      throw SetupPackageAdoptionError("Invalid package adoption ledger: \(error)")
    }
  }

  func write(_ ledger: SetupPackageAdoptionLedger) throws {
    try writeBoundedEvidenceJSON(
      ledger, to: url, temporaryPrefix: ".packages-",
      tooLargeError: SetupPackageAdoptionError("Package adoption ledger exceeds 1 MiB."),
      replaceError: { SetupPackageAdoptionError("Cannot publish package adoption (errno \($0)).") }
    )
  }

  private func validEntry(_ entry: SetupPackageAdoptionLedger.Entry) -> Bool {
    let parts = entry.identity.name.components(separatedBy: "/")
    return [1, 3].contains(parts.count) && parts.allSatisfy(HomebrewPackageIdentity.validToken)
      && HomebrewPackageIdentity(kind: entry.identity.kind, name: entry.identity.name)
        == entry.identity
      && !entry.versions.isEmpty && entry.versions.count <= 64
      && entry.versions == entry.versions.sorted()
      && Set(entry.versions).count == entry.versions.count
      && entry.versions.allSatisfy { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }
      && !entry.receipts.isEmpty && entry.receipts.count <= 64
      && Set(entry.receipts.map(\.path)).count == entry.receipts.count
      && entry.receipts.allSatisfy {
        $0.path.hasPrefix("/") && URL(filePath: $0.path).lastPathComponent == "INSTALL_RECEIPT.json"
          && validDigest($0.digest) && $0.inode > 0
      }
      && !entry.declarations.isEmpty && entry.declarations.count <= 64
      && entry.declarations.allSatisfy { !$0.source.isEmpty && !$0.layer.isEmpty }
      && validDigest(entry.approvalDigest)
  }

  private func validDigest(_ value: String) -> Bool {
    value.hasPrefix("sha256:") && value.count == 71
      && value.dropFirst(7).allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
  }
}

struct SetupPackageAdoptionError: Error, CustomStringConvertible, Sendable {
  let description: String
  init(_ description: String) { self.description = description }
}
