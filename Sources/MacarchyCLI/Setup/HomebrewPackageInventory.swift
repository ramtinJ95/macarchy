import Foundation
import ThemeCore

struct HomebrewPackageIdentity: Hashable, Encodable, Sendable {
  enum Kind: String, CaseIterable, Encodable, Sendable {
    case formula, cask
  }

  let kind: Kind
  let name: String

  init(kind: Kind, name: String) {
    self.kind = kind
    let official = kind == .formula ? "homebrew/core/" : "homebrew/cask/"
    self.name = name.hasPrefix(official) ? String(name.dropFirst(official.count)) : name
  }

  var key: String { "\(kind.rawValue):\(name)" }
  var token: String { String(name.split(separator: "/").last ?? "") }

  static func validToken(_ value: String) -> Bool {
    !value.isEmpty && value.first != "." && value.first != "-"
      && value.utf8.allSatisfy {
        (97...122).contains($0) || (48...57).contains($0) || "-+_.@".utf8.contains($0)
      }
  }
}

struct HomebrewInstalledPackage: Encodable, Sendable {
  let kind: HomebrewPackageIdentity.Kind
  let token: String
  let identity: HomebrewPackageIdentity?
  let versions: [String]
  let receiptPaths: [String]
  let issue: String?
}

struct HomebrewPackageObservation: Encodable, Sendable {
  let packages: [HomebrewInstalledPackage]
  /// A failed list cannot prove absence, even if some receipts were readable.
  let issues: [String]
  let status: String

  init(packages: [HomebrewInstalledPackage], issues: [String]) {
    self.packages = packages
    self.issues = issues
    if !issues.isEmpty {
      status = "unavailable"
    } else {
      status = packages.contains { $0.issue != nil } ? "incomplete" : "available"
    }
  }

  static func unavailable(_ message: String) -> Self {
    Self(packages: [], issues: [message])
  }
}

/// Uses Homebrew's no-argument shell listing, not `info --installed`: the latter
/// evaluates package Ruby and silently drops some load failures. Names alone do
/// not prove installation identity; each listed name needs an inert receipt.
/// This observes installation records, not package integrity or adoption rights.
struct HomebrewPackageInventoryReader: Sendable {
  let prefix: URL
  let processRunner: ProcessRunner
  let executableIsAvailable: @Sendable () -> Bool

  static let live = Self(
    prefix: URL(filePath: "/opt/homebrew"),
    processRunner: .live,
    executableIsAvailable: {
      FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew")
    }
  )

  func read() -> HomebrewPackageObservation {
    guard executableIsAvailable() else {
      return .unavailable("Homebrew executable is unavailable.")
    }
    var packages = [HomebrewInstalledPackage]()
    var issues = [String]()
    for kind in HomebrewPackageIdentity.Kind.allCases {
      do {
        let result = try processRunner.run(
          ProcessRequest(
            executableURL: prefix.appending(path: "bin/brew"),
            arguments: ["list", "--\(kind.rawValue)", "-1"],
            timeout: 10,
            environmentOverrides: [
              "HOMEBREW_NO_AUTO_UPDATE": "1",
              "HOMEBREW_NO_ANALYTICS": "1",
              "LC_ALL": "C",
            ]
          )
        )
        guard result.terminationStatus == 0 else {
          throw InventoryError("Homebrew list exited with status \(result.terminationStatus).")
        }
        guard result.output.utf8.count <= 32_768 else {
          throw InventoryError("Homebrew list exceeded the 32 KiB limit.")
        }
        let names = result.output.isEmpty ? [] : result.output.components(separatedBy: "\n")
        guard names.count <= 1024, names.allSatisfy(HomebrewPackageIdentity.validToken),
          Set(names).count == names.count
        else {
          throw InventoryError(
            "Malformed, duplicate, or unsupported Homebrew listing; no absence inferred.")
        }
        packages += names.sorted().map { inspect(kind: kind, token: $0) }
      } catch {
        issues.append("\(kind.rawValue): \(error)")
      }
    }
    return HomebrewPackageObservation(packages: packages, issues: issues)
  }

  private func inspect(kind: HomebrewPackageIdentity.Kind, token: String)
    -> HomebrewInstalledPackage
  {
    var receiptPaths = [String]()
    do {
      let base = prefix.appending(path: kind == .formula ? "Cellar" : "Caskroom")
      let directory = base.appending(path: token)
      try requireDirectory(base)
      try requireDirectory(directory)
      var versions = [String]()
      var identities = Set<HomebrewPackageIdentity>()
      if kind == .formula {
        let children = try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil
        ).sorted { $0.path < $1.path }
        guard !children.isEmpty, children.count <= 64 else {
          throw InventoryError("Empty or unsupported formula rack (maximum 64 versions).")
        }
        for keg in children {
          try requireDirectory(keg)
          let receipt = keg.appending(path: "INSTALL_RECEIPT.json")
          receiptPaths.append(receipt.path)
          identities.insert(try identity(at: receipt, kind: kind, token: token).identity)
          versions.append(keg.lastPathComponent)
        }
      } else {
        let metadata = directory.appending(path: ".metadata")
        try requireDirectory(metadata)
        let receipt = metadata.appending(path: "INSTALL_RECEIPT.json")
        receiptPaths.append(receipt.path)
        let record = try identity(at: receipt, kind: kind, token: token)
        guard let version = record.version, !version.isEmpty,
          version != ".", version != "..", !version.contains("/"),
          !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw InventoryError("Missing or unsupported cask receipt version.") }
        try requireDirectory(metadata.appending(path: version))
        identities.insert(record.identity)
        versions.append(version)
      }
      guard identities.count == 1, let identity = identities.first else {
        throw InventoryError("Ambiguous installation: versions record different taps.")
      }
      return HomebrewInstalledPackage(
        kind: kind, token: token, identity: identity, versions: versions.sorted(),
        receiptPaths: receiptPaths, issue: nil
      )
    } catch {
      return HomebrewInstalledPackage(
        kind: kind, token: token, identity: nil, versions: [], receiptPaths: receiptPaths,
        issue: "Cannot establish recorded installation identity: \(error)"
      )
    }
  }

  private func requireDirectory(_ url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw InventoryError("Unsupported non-directory or symlink at \(url.path).")
    }
  }

  private func identity(
    at url: URL, kind: HomebrewPackageIdentity.Kind, token: String
  ) throws -> (identity: HomebrewPackageIdentity, version: String?) {
    let receipt = try JSONDecoder().decode(
      Receipt.self, from: BoundedRegularFile.read(at: url, maximumSize: 65_536).data
    )
    let tap = receipt.source.tap
    let parts = tap.components(separatedBy: "/")
    guard !receipt.homebrewVersion.isEmpty, parts.count == 2,
      parts.allSatisfy(HomebrewPackageIdentity.validToken),
      !(kind == .formula && tap == "homebrew/cask"),
      !(kind == .cask && tap == "homebrew/core")
    else { throw InventoryError("Missing or unsupported Homebrew receipt provenance.") }
    return (HomebrewPackageIdentity(kind: kind, name: "\(tap)/\(token)"), receipt.source.version)
  }

  private struct Receipt: Decodable {
    let homebrewVersion: String
    let source: Source
    struct Source: Decodable {
      let tap: String
      let version: String?
    }
    enum CodingKeys: String, CodingKey {
      case homebrewVersion = "homebrew_version"
      case source
    }
  }

  private struct InventoryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}
