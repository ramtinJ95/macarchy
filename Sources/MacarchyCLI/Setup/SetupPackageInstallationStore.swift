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
  let effects: HomebrewFormulaInstallEffects
  let baseline: HomebrewPackageObservation
  var phase: Phase = .running
  var nativeExit: Int32?
  var processGroup: Int32?
  var diagnostic = ""
  var verifiedComponents: [String] = []

  struct Summary: Encodable, Sendable {
    let phase: Phase
    let targets: [String]
    let nativeExit: Int32?
    let verifiedComponents: [String]
    let diagnostic: String
  }
  var summary: Summary {
    .init(
      phase: phase, targets: targets.map(\.identity.key), nativeExit: nativeExit,
      verifiedComponents: verifiedComponents, diagnostic: diagnostic)
  }
}

struct SetupPackageInstallationStore: Sendable {
  let context: UnifiedSetupPlanContext
  var url: URL { context.stateRoot.appending(path: "state/setup/package-installation.json") }
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
    let componentNames = Set(attempt.effects.components.map(\.name))
    let verified = Set(attempt.verifiedComponents)
    guard attempt.schemaVersion == 1, attempt.contextDigest == contextDigest,
      digest(attempt.approvalDigest), digest(attempt.priorLedgerDigest),
      attempt.processGroup == nil || attempt.processGroup! > 1,
      !names.isEmpty, names == names.sorted(), Set(names).count == names.count,
      attempt.targets.allSatisfy({
        $0.identity.kind == .formula && HomebrewPackageIdentity.validToken($0.identity.name)
          && !$0.declarations.isEmpty && $0.declarations.count <= 64
          && $0.declarations.allSatisfy { !$0.source.isEmpty && !$0.layer.isEmpty }
      }), attempt.baseline.status == "available", attempt.baseline.issues.isEmpty,
      attempt.baseline.packages.allSatisfy({ $0.issue == nil && $0.identity != nil }),
      !attempt.baseline.packages.contains(where: {
        $0.kind == .formula && componentNames.contains($0.token)
      }), attempt.diagnostic.utf8.count <= 32 * 1024,
      verified.isSubset(of: componentNames), verified.count == attempt.verifiedComponents.count,
      attempt.phase != .complete
        || (attempt.nativeExit == 0 && verified == componentNames)
    else { throw SetupPackageAdoptionError("Invalid installation context, state or evidence.") }
    try attempt.effects.validate(roots: names)
  }
}
