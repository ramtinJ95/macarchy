import Foundation
import ThemeCore

enum InstallationOwnership: String, Encodable, Sendable {
  case development
  case homebrew
  case unmanaged
}

struct MacarchyBuildInformation: Equatable, Sendable {
  let version: String
  let revision: String
  let platform: String
  let installation: InstallationOwnership
}

struct InvalidBuildInformationError: Error, CustomStringConvertible, Equatable {
  let reason: String

  var description: String {
    "Invalid packaged build information: \(reason)"
  }
}

struct RuntimeEnvironment: Sendable {
  static let sourceVersion = "0.5.0"

  static let live = RuntimeEnvironment(
    executableURL: Bundle.main.executableURL
      ?? URL(filePath: CommandLine.arguments.first ?? "macarchy")
  )

  private let executableURL: URL

  init(executableURL: URL) {
    self.executableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
  }

  var builtInThemesURL: URL {
    builtInResourceURL(packagedName: "themes", developmentName: "Themes")
  }

  var builtInKeybindingsURL: URL {
    builtInResourceURL(packagedName: "keybindings", developmentName: "Keybindings")
  }

  var builtInDesktopURL: URL {
    builtInResourceURL(packagedName: "desktop", developmentName: "Desktop")
  }

  private func builtInResourceURL(packagedName: String, developmentName: String) -> URL {
    let packaged = packagedResourceRoot.appending(
      path: packagedName,
      directoryHint: .isDirectory
    )
    if FileManager.default.fileExists(atPath: packagedBuildInformationURL.path) {
      return packaged
    }
    if let developmentCheckoutURL {
      return developmentCheckoutURL.appending(
        path: developmentName,
        directoryHint: .isDirectory
      )
    }
    return packaged
  }

  private var packagedResourceRoot: URL {
    installationPrefixURL
      .appending(path: "share", directoryHint: .isDirectory)
      .appending(path: "macarchy", directoryHint: .isDirectory)
  }

  func buildInformation() throws -> MacarchyBuildInformation {
    let informationURL = packagedBuildInformationURL
    if FileManager.default.fileExists(atPath: informationURL.path) {
      let data: Data
      do {
        data = try BoundedRegularFile.read(at: informationURL).data
      } catch {
        throw InvalidBuildInformationError(
          reason: "cannot read \(informationURL.path)"
        )
      }
      let document: PackagedBuildInformation
      do {
        document = try JSONDecoder().decode(PackagedBuildInformation.self, from: data)
      } catch {
        throw InvalidBuildInformationError(
          reason: "cannot decode \(informationURL.path)"
        )
      }
      guard document.schemaVersion == 1 else {
        throw InvalidBuildInformationError(
          reason: "unsupported schema version \(document.schemaVersion); expected 1"
        )
      }
      guard document.version == Self.sourceVersion else {
        throw InvalidBuildInformationError(
          reason:
            "version \(document.version) does not match executable version \(Self.sourceVersion)"
        )
      }
      guard Self.isFullGitRevision(document.revision) else {
        throw InvalidBuildInformationError(
          reason: "revision must be a 40-character lowercase Git object ID"
        )
      }
      return MacarchyBuildInformation(
        version: document.version,
        revision: document.revision,
        platform: Self.platform,
        installation: installationOwnership(hasPackagedInformation: true)
      )
    }

    return MacarchyBuildInformation(
      version: "\(Self.sourceVersion)-dev",
      revision: "unknown",
      platform: Self.platform,
      installation: installationOwnership(hasPackagedInformation: false)
    )
  }

  private var packagedBuildInformationURL: URL {
    packagedResourceRoot.appending(path: "build-info.json")
  }

  private var installationPrefixURL: URL {
    let executableDirectory = executableURL.deletingLastPathComponent()
    if executableDirectory.lastPathComponent == "bin" {
      return executableDirectory.deletingLastPathComponent()
    }
    return executableDirectory
  }

  private var developmentCheckoutURL: URL? {
    var candidate = executableURL.deletingLastPathComponent()
    while candidate.path != "/" {
      if candidate.lastPathComponent == ".build" {
        let checkout = candidate.deletingLastPathComponent()
        let packageManifest = checkout.appending(path: "Package.swift")
        let themes = checkout.appending(path: "Themes", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: packageManifest.path),
          FileManager.default.fileExists(atPath: themes.path)
        {
          return checkout
        }
        return nil
      }
      candidate.deleteLastPathComponent()
    }

    return nil
  }

  private func installationOwnership(hasPackagedInformation: Bool) -> InstallationOwnership {
    let receipt = installationPrefixURL.appending(path: "INSTALL_RECEIPT.json")
    if hasPackagedInformation, (try? BoundedRegularFile.read(at: receipt)) != nil {
      return .homebrew
    }
    if hasPackagedInformation {
      return .unmanaged
    }
    return developmentCheckoutURL == nil ? .unmanaged : .development
  }

  private static var platform: String {
    #if arch(arm64)
      "macos-arm64"
    #else
      "macos-unsupported-architecture"
    #endif
  }

  private static func isFullGitRevision(_ value: String) -> Bool {
    value.count == 40
      && value.allSatisfy { character in
        ("0"..."9").contains(character) || ("a"..."f").contains(character)
      }
  }
}

private struct PackagedBuildInformation: Decodable {
  let schemaVersion: Int
  let version: String
  let revision: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case version
    case revision
  }
}
