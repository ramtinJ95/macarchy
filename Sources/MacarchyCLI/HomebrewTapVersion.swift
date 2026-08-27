import Foundation
import ThemeCore

struct HomebrewTapVersion: Equatable, Encodable, Sendable {
  enum Status: String, Encodable, Sendable {
    case available
    case unavailable
  }

  let status: Status
  let version: String?
  let error: String?

  static func available(_ version: String) -> Self {
    Self(status: .available, version: version, error: nil)
  }

  static func unavailable(_ error: String) -> Self {
    Self(status: .unavailable, version: nil, error: boundedUpdateEvidence(error))
  }
}

struct HomebrewTapVersionReader: Sendable {
  static let formula = "ramtinj95/tap/macarchy"
  static let request = ProcessRequest(
    executableURL: URL(filePath: "/opt/homebrew/bin/brew"),
    arguments: ["info", "--json=v2", "--formula", formula],
    timeout: 10,
    environmentOverrides: [
      "HOMEBREW_NO_ANALYTICS": "1",
      "HOMEBREW_NO_AUTO_UPDATE": "1",
    ]
  )

  let processRunner: ProcessRunner
  let executableIsAvailable: @Sendable () -> Bool

  static let live = HomebrewTapVersionReader(
    processRunner: .live,
    executableIsAvailable: {
      FileManager.default.isExecutableFile(atPath: request.executableURL.path)
    }
  )

  func read() -> HomebrewTapVersion {
    guard executableIsAvailable() else {
      return .unavailable("Homebrew is not available at \(Self.request.executableURL.path)")
    }

    let result: ProcessResult
    do {
      result = try processRunner.run(Self.request)
    } catch {
      return .unavailable("Could not inspect the local Homebrew tap: \(error)")
    }
    guard result.terminationStatus == 0 else {
      let detail =
        result.output.isEmpty
        ? "Homebrew exited with status \(result.terminationStatus)"
        : result.output
      return .unavailable("Could not inspect the local Homebrew tap: \(detail)")
    }
    guard result.output.utf8.count <= BoundedRegularFile.maximumSize else {
      return .unavailable("Homebrew formula information exceeded the 1 MiB limit")
    }

    do {
      let document = try JSONDecoder().decode(
        HomebrewInformation.self,
        from: Data(result.output.utf8)
      )
      guard document.formulae.count == 1,
        document.formulae[0].fullName == Self.formula
      else {
        return .unavailable("Homebrew did not return exactly \(Self.formula)")
      }
      let version = document.formulae[0].versions.stable
      guard StableVersion(version) != nil else {
        return .unavailable("Homebrew returned invalid stable version '\(version)'")
      }
      return .available(version)
    } catch {
      return .unavailable("Could not decode local Homebrew formula information")
    }
  }
}

private struct HomebrewInformation: Decodable {
  let formulae: [Formula]

  struct Formula: Decodable {
    let fullName: String
    let versions: Versions

    enum CodingKeys: String, CodingKey {
      case fullName = "full_name"
      case versions
    }
  }

  struct Versions: Decodable {
    let stable: String
  }
}
