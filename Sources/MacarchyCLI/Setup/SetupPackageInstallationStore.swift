import Darwin
import Foundation
import ThemeCore

/// An attempt is not ownership. Only packages.json records applied declarations.
struct SetupPackageInstallationAttempt: Codable, Sendable {
  struct Target: Codable, Sendable {
    let identity: HomebrewPackageIdentity
    let declarations: [SetupPackageAdoptionLedger.Declaration]
  }
  enum Phase: String, Codable, Sendable { case running, complete, partial }

  let schemaVersion: Int
  let contextDigest: String
  let approvalDigest: String
  let priorLedgerDigest: String
  let targets: [Target]
  let brewfile: String
  var phase: Phase = .running
  var nativeExit: Int32?
  var processSession: Int32?
  var diagnostic = ""
  var verifiedTargets: [String] = []

  struct Summary: Encodable, Sendable {
    let phase: Phase
    let targets: [String]
    let nativeExit: Int32?
    let verifiedTargets: [String]
    let diagnostic: String
  }
  var summary: Summary {
    .init(
      phase: phase, targets: targets.map(\.identity.key), nativeExit: nativeExit,
      verifiedTargets: verifiedTargets, diagnostic: diagnostic)
  }
}

struct SetupPackageInstallationStore: Sendable {
  let context: UnifiedSetupPlanContext
  var url: URL { context.stateRoot.appending(path: "state/setup/package-installation.json") }
  var brewfileURL: URL { context.stateRoot.appending(path: "state/setup/installation.Brewfile") }
  var contextDigest: String {
    SetupPackageAdoptionStore(stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
      .contextDigest
  }

  static func digest<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try sha256Digest(encoder.encode(value))
  }

  func read() throws -> SetupPackageInstallationAttempt? {
    let data: Data
    do { data = try BoundedRegularFile.read(at: url).data } catch BoundedRegularFileError.system(
      operation: "open", code: ENOENT)
    { return nil } catch {
      throw SetupPackageAdoptionError("Cannot read package installation attempt: \(error)")
    }
    do {
      _ = try StrictJSONObjectDocument(data: data, id: "package_installation", target: url)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      struct Version: Decodable { let schemaVersion: Int }
      let version = try decoder.decode(Version.self, from: data)
      guard version.schemaVersion == 3 else {
        throw SetupPackageAdoptionError(
          "Legacy exact-effect installation attempt at \(url.path). Preserve it and inspect the host before manually moving it aside; it cannot be replayed or adopted."
        )
      }
      let attempt = try decoder.decode(SetupPackageInstallationAttempt.self, from: data)
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      guard
        try JSONSerialization.jsonObject(with: data) as? NSDictionary
          == JSONSerialization.jsonObject(with: encoder.encode(attempt)) as? NSDictionary
      else {
        throw SetupPackageAdoptionError("Unknown package installation evidence fields.")
      }
      try validate(attempt)
      return attempt
    } catch {
      throw SetupPackageAdoptionError("Invalid package installation attempt: \(error)")
    }
  }

  func write(_ attempt: SetupPackageInstallationAttempt) throws {
    try validate(attempt)
    try writeBoundedEvidenceJSON(
      attempt, to: url, temporaryPrefix: ".package-installation-",
      tooLargeError: SetupPackageAdoptionError("Package installation evidence exceeds 1 MiB."),
      replaceError: {
        SetupPackageAdoptionError("Cannot publish installation attempt (errno \($0)).")
      })
  }

  func requireResolved() throws {
    guard try read()?.phase != .running else {
      throw SetupPackageAdoptionError(
        "Interrupted package installation requires setup install-packages --recover; Homebrew will not be rerun."
      )
    }
  }

  private func validate(_ attempt: SetupPackageInstallationAttempt) throws {
    func digest(_ value: String) -> Bool {
      value.hasPrefix("sha256:") && value.count == 71
        && value.dropFirst(7).allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }
    let names = attempt.targets.map(\.identity.name)
    let targetNames = Set(attempt.targets.map(\.identity.key))
    let verified = Set(attempt.verifiedTargets)
    guard attempt.schemaVersion == 3, attempt.contextDigest == contextDigest,
      digest(attempt.approvalDigest), digest(attempt.priorLedgerDigest),
      attempt.processSession == nil || attempt.processSession! > 1,
      !names.isEmpty, names == names.sorted(), Set(names).count == names.count,
      attempt.targets.allSatisfy({
        $0.identity.kind == .formula && HomebrewPackageIdentity.validToken($0.identity.name)
          && !$0.declarations.isEmpty && $0.declarations.count <= 64
          && $0.declarations.allSatisfy { !$0.source.isEmpty && !$0.layer.isEmpty }
      }), attempt.diagnostic.utf8.count <= 32 * 1024,
      verified.isSubset(of: targetNames), verified.count == attempt.verifiedTargets.count,
      attempt.phase != .complete
        || (attempt.nativeExit == 0 && verified == targetNames)
    else { throw SetupPackageAdoptionError("Invalid installation context, state or evidence.") }
    guard attempt.brewfile == SetupBrewfile(packages: attempt.targets.map(\.identity)).text else {
      throw SetupPackageAdoptionError(
        "Installation Brewfile does not match its named declarations.")
    }
  }
}
