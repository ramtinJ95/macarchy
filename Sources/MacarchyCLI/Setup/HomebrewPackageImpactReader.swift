import Darwin
import Foundation
import ThemeCore

/// Official acquisition and confined native execution shared by impact and install preparation.
struct HomebrewPackageImpactReader: Sendable {
  var processRunner: ProcessRunner = .live
  var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

  func read(_ identities: [HomebrewPackageIdentity]) -> SetupPackageImpact {
    do {
      let evidence = try withSession { session in
        try session.resolve(identities.filter(SetupPackageImpact.supports).map(\.name))
      }
      return SetupPackageImpact(identities: identities, evidence: evidence)
    } catch {
      return SetupPackageImpact(identities: identities, issue: String(describing: error))
    }
  }

  func validateRuntime() throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
      FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
    else { throw ImpactError("Required macOS 26 sandbox-exec is unavailable; operation blocked.") }
    #if !arch(arm64)
      throw ImpactError("Package impact is qualified only on Apple Silicon.")
    #endif
    // brew.env overrides even the explicit command environment in bin/brew.
    let environmentFiles = [
      URL(filePath: "/etc/homebrew/brew.env"),
      URL(filePath: "/opt/homebrew/etc/homebrew/brew.env"),
      homeDirectory.appending(path: ".homebrew/brew.env"),
    ]
    guard !environmentFiles.contains(where: { FileManager.default.fileExists(atPath: $0.path) })
    else {
      throw ImpactError("Homebrew brew.env configuration is not qualified for package impact.")
    }
    let head = try command("/usr/bin/git", ["-C", "/opt/homebrew", "rev-parse", "HEAD"])
    guard head == HomebrewFormulaResolver.revision else {
      throw ImpactError("Unsupported Homebrew revision \(head); no resolver executed.")
    }
    let changes = try command(
      "/usr/bin/git",
      [
        "-c", "core.fsmonitor=false", "-C", "/opt/homebrew",
        "status", "--porcelain", "--untracked-files=normal",
      ])
    guard changes.isEmpty else {
      throw ImpactError("Modified Homebrew checkout is not qualified; no resolver executed.")
    }
  }

  func withSession<Output>(_ operation: (inout Session) throws -> Output) throws -> Output {
    try validateRuntime()
    let scratch = FileManager.default.temporaryDirectory
      .appending(path: "macarchy-package-impact-\(UUID().uuidString)")
    do {
      for directory in ["", "cache/api/internal", "cache/downloads", "tmp", "logs"] {
        try FileManager.default.createDirectory(
          at: scratch.appending(path: directory), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      let root = URL(filePath: try Self.sandboxPath(scratch))
      try HomebrewFormulaResolver.script.write(
        to: root.appending(path: "resolver.rb"), atomically: true, encoding: .utf8)
      try HomebrewFormulaResolver.sandbox.write(
        to: root.appending(path: "resolver.sb"), atomically: true, encoding: .utf8)
      var session = Session(reader: self, scratch: root)
      try session.download(
        "https://formulae.brew.sh/api/internal/packages.arm64_tahoe.jws.json",
        to: root.appending(path: "cache/api/internal/packages.arm64_tahoe.jws.json"),
        maximumSize: 32 * 1024 * 1024)
      let result = try operation(&session)
      try FileManager.default.removeItem(at: root)
      return result
    } catch {
      if FileManager.default.fileExists(atPath: scratch.path) {
        do { try FileManager.default.removeItem(at: scratch) } catch let cleanup {
          throw ImpactError("\(error); scratch cleanup failed at \(scratch.path): \(cleanup)")
        }
      }
      throw error
    }
  }

  struct Session {
    let reader: HomebrewPackageImpactReader
    let scratch: URL
    // Metadata and archives have independent, cumulative transfer budgets.
    var remainingBytes = 64 * 1024 * 1024
    var remainingArchiveBytes = 64 * 1024 * 1024
    let deadline = Date().addingTimeInterval(180)

    var environment: [String] {
      [
        "HOMEBREW_CACHE=\(scratch.appending(path: "cache").path)",
        "HOMEBREW_TEMP=\(scratch.appending(path: "tmp").path)",
        "HOMEBREW_LOGS=\(scratch.appending(path: "logs").path)",
        "TMPDIR=\(scratch.appending(path: "tmp").path)",
        "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1",
        "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_COLOR=1",
        // Skip brew ruby's persistent developer-mode write without changing config.
        "HOMEBREW_DEV_CMD_RUN=1",
      ]
    }

    func native(script: String = "resolver.rb", phase: String, input: Data) throws -> Data {
      let source = scratch.appending(path: "\(phase)-input.json")
      let output = scratch.appending(path: "\(phase)-output.json")
      try input.write(to: source)
      _ = try reader.command(
        "/usr/bin/sandbox-exec",
        [
          "-D", "SCRATCH=\(scratch.path)", "-f", scratch.appending(path: "resolver.sb").path,
          "/opt/homebrew/bin/brew", "ruby", scratch.appending(path: script).path,
          phase, source.path, output.path,
        ], timeout: 45, environment: environment)
      let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size > 0, size <= 256 * 1024 else {
        throw ImpactError("Native resolver output exceeded its bounds or was empty.")
      }
      return try Data(contentsOf: output)
    }

    mutating func resolve(_ names: [String]) throws -> [SetupPackageImpact.FormulaEvidence] {
      guard names.count <= 64, Set(names).count == names.count else {
        throw ImpactError("Package impact request exceeds its qualified bounds.")
      }
      let input = try JSONEncoder().encode(names)
      let metadata = try JSONDecoder().decode(
        [SetupPackageImpact.FormulaEvidence].self, from: native(phase: "metadata", input: input))
      guard metadata.count == names.count, Set(metadata.map(\.name)) == Set(names) else {
        throw ImpactError("Native metadata response does not match the request.")
      }
      var evidence = [SetupPackageImpact.FormulaEvidence]()
      var staged = [String]()
      for result in metadata {
        do {
          guard result.status == "metadata_required", let address = result.url,
            let path = result.path
          else {
            throw ImpactError(result.issue ?? "Unsupported native metadata request.")
          }
          try registry(address, path: path, archive: false)
          staged.append(result.name)
        } catch {
          evidence.append(
            .init(name: result.name, status: "incomplete", issue: String(describing: error)))
        }
      }
      if !staged.isEmpty {
        evidence += try JSONDecoder().decode(
          [SetupPackageImpact.FormulaEvidence].self,
          from: native(phase: "resolve", input: JSONEncoder().encode(staged)))
      }
      return evidence
    }

    mutating func registry(_ address: String, path: String, archive: Bool) throws {
      guard let url = URL(string: address), url.scheme == "https", url.host == "ghcr.io",
        url.port == nil, url.user == nil, url.password == nil, url.query == nil,
        url.fragment == nil, url.path.hasPrefix("/v2/homebrew/core/"),
        let separator = url.path.range(of: archive ? "/blobs/" : "/manifests/")
      else { throw ImpactError("Unsupported native registry request.") }
      let destination = URL(filePath: path).standardizedFileURL
      guard
        try HomebrewPackageImpactReader.sandboxPath(destination.deletingLastPathComponent())
          == scratch.appending(path: "cache/downloads").path
      else { throw ImpactError("Native registry destination escaped scratch downloads.") }
      let repository = String(url.path[..<separator.lowerBound].dropFirst(4))
      var tokenURL = URLComponents(string: "https://ghcr.io/token")!
      tokenURL.queryItems = [
        URLQueryItem(name: "service", value: "ghcr.io"),
        URLQueryItem(name: "scope", value: "repository:\(repository):pull"),
      ]
      let tokenFile = scratch.appending(path: "token.json")
      try download(tokenURL.url!.absoluteString, to: tokenFile, maximumSize: 64 * 1024)
      struct Token: Decodable { let token: String }
      let token = try JSONDecoder().decode(Token.self, from: Data(contentsOf: tokenFile)).token
      guard !token.isEmpty,
        token.utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || "-._~+/=".utf8.contains($0)
        })
      else { throw ImpactError("Invalid public registry token.") }
      let headers = scratch.appending(path: "headers.conf")
      try
        ("header = \"Authorization: Bearer \(token)\"\n"
        + "header = \"Accept: application/vnd.oci.image.index.v1+json\"\n")
        .write(to: headers, atomically: true, encoding: .utf8)
      try download(
        address, to: destination,
        maximumSize: archive ? 32 * 1024 * 1024 : 2 * 1024 * 1024,
        headers: headers, archive: archive)
    }

    mutating func download(
      _ address: String, to destination: URL, maximumSize: Int,
      headers: URL? = nil, archive: Bool = false
    ) throws {
      let seconds = min(30, Int(deadline.timeIntervalSinceNow))
      let available = archive ? remainingArchiveBytes : remainingBytes
      guard seconds > 0, available > 0 else {
        throw ImpactError("Acquisition exhausted its 180-second / 64 MiB budget.")
      }
      var arguments = [
        "-q", "--fail", "--silent", "--show-error", "--proto", "=https",
        "--connect-timeout", "5", "--max-time", String(seconds),
        "--max-filesize", String(min(maximumSize, available)), "--output", destination.path,
      ]
      if let headers { arguments += ["--config", headers.path] }
      if archive { arguments += ["--location", "--max-redirs", "2", "--proto-redir", "=https"] }
      arguments.append(address)
      defer {
        if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
          if archive {
            remainingArchiveBytes = max(0, remainingArchiveBytes - size)
          } else {
            remainingBytes = max(0, remainingBytes - size)
          }
        }
      }
      _ = try reader.command("/usr/bin/curl", arguments, timeout: TimeInterval(seconds + 2))
      let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size > 0, size <= maximumSize, size <= available else {
        throw ImpactError("Metadata response exceeded its byte bound or was empty.")
      }
    }
  }

  static func sandboxPath(_ directory: URL) throws -> String {
    // Seatbelt needs the physical /private/var spelling, not Foundation's /var URL.
    guard let path = Darwin.realpath(directory.path, nil) else {
      throw ImpactError("Could not canonicalize the sandbox scratch directory.")
    }
    defer { free(path) }
    return String(cString: path)
  }

  private func command(
    _ executable: String, _ arguments: [String], timeout: TimeInterval = 10,
    environment: [String] = []
  ) throws -> String {
    let result = try processRunner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/env"),
        arguments: [
          "-i", "HOME=\(homeDirectory.path)", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
          "LC_ALL=C", "GIT_OPTIONAL_LOCKS=0",
        ] + environment + [executable] + arguments, timeout: timeout))
    guard result.terminationStatus == 0 else {
      throw ImpactError(
        "\(executable) failed (\(result.terminationStatus)): \(result.output.prefix(1500))")
    }
    guard result.output.utf8.count <= 4096 else {
      throw ImpactError("\(executable) exceeded the diagnostic output bound.")
    }
    return result.output
  }

  private struct ImpactError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}
