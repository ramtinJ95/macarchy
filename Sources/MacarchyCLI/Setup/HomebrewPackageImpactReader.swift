import Darwin
import Foundation
import ThemeCore

/// Explicit network staging is separate from the network-denied native adapter.
/// Never invoke install/dry-run, and never fall back to an unconfined resolver.
struct HomebrewPackageImpactReader: Sendable {
  var processRunner: ProcessRunner = .live
  var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

  func read(_ identities: [HomebrewPackageIdentity]) -> SetupPackageImpact {
    let scratch = FileManager.default.temporaryDirectory
      .appending(path: "macarchy-package-impact-\(UUID().uuidString)")
    var evidence = [SetupPackageImpact.FormulaEvidence]()
    var failure: String?
    do {
      guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
        throw ImpactError("Package impact confinement is qualified only on macOS 26.")
      }
      guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
        throw ImpactError("Required sandbox-exec is unavailable; inspection blocked.")
      }
      #if !arch(arm64)
        throw ImpactError("Package impact is qualified only on Apple Silicon.")
      #endif
      // brew.env overrides even explicit environment variables in bin/brew.
      // Do not silently ignore a configured wrapper, mirror, cache or API mode.
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
        ]
      )
      guard changes.isEmpty else {
        throw ImpactError("Modified Homebrew checkout is not qualified; no resolver executed.")
      }
      let names = identities.filter(SetupPackageImpact.supports).map(\.name)
      guard names.count <= 64, Set(names).count == names.count else {
        throw ImpactError("Package impact request exceeds its qualified bounds.")
      }
      for directory in ["", "cache/api/internal", "cache/downloads", "tmp", "logs"] {
        try FileManager.default.createDirectory(
          at: scratch.appending(path: directory), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      }
      try HomebrewFormulaResolver.script.write(
        to: scratch.appending(path: "resolver.rb"), atomically: true, encoding: .utf8
      )
      try HomebrewFormulaResolver.sandbox.write(
        to: scratch.appending(path: "resolver.sb"), atomically: true, encoding: .utf8
      )
      var remainingBytes = 64 * 1024 * 1024
      let deadline = Date().addingTimeInterval(180)
      try download(
        "https://formulae.brew.sh/api/internal/packages.arm64_tahoe.jws.json",
        to: scratch.appending(path: "cache/api/internal/packages.arm64_tahoe.jws.json"),
        maximumSize: 32 * 1024 * 1024, remainingBytes: &remainingBytes, deadline: deadline
      )
      // Homebrew verifies the signed API envelope itself; no borrowed user cache.
      let metadata = try resolve(phase: "metadata", names: names, scratch: scratch)
      guard metadata.count == names.count, Set(metadata.map(\.name)) == Set(names) else {
        throw ImpactError("Native metadata response does not match the request.")
      }
      var staged = [String]()
      for result in metadata {
        do {
          guard result.status == "metadata_required", let address = result.url,
            let url = URL(string: address), url.scheme == "https", url.host == "ghcr.io",
            url.port == nil, url.user == nil, url.password == nil, url.query == nil,
            url.fragment == nil, url.path.hasPrefix("/v2/homebrew/core/"),
            let separator = url.path.range(of: "/manifests/"), let path = result.path
          else {
            throw ImpactError(result.issue ?? "Unsupported native metadata request.")
          }
          let destination = URL(filePath: path).standardizedFileURL
          guard
            destination.deletingLastPathComponent()
              == scratch.appending(path: "cache/downloads").standardizedFileURL
          else { throw ImpactError("Native manifest destination escaped scratch downloads.") }
          let repository = String(url.path[..<separator.lowerBound].dropFirst(4))
          var tokenURL = URLComponents(string: "https://ghcr.io/token")!
          tokenURL.queryItems = [
            URLQueryItem(name: "service", value: "ghcr.io"),
            URLQueryItem(name: "scope", value: "repository:\(repository):pull"),
          ]
          let tokenFile = scratch.appending(path: "token.json")
          try download(
            tokenURL.url!.absoluteString, to: tokenFile, maximumSize: 64 * 1024,
            remainingBytes: &remainingBytes, deadline: deadline
          )
          struct Token: Decodable { let token: String }
          let token = try JSONDecoder().decode(Token.self, from: Data(contentsOf: tokenFile)).token
          guard !token.isEmpty,
            token.utf8.allSatisfy({
              (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || "-._~+/=".utf8.contains($0)
            })
          else { throw ImpactError("Invalid public registry token.") }
          // Keep the anonymous pull token out of process arguments and diagnostics.
          let headers = scratch.appending(path: "headers.conf")
          try
            "header = \"Authorization: Bearer \(token)\"\nheader = \"Accept: application/vnd.oci.image.index.v1+json\"\n"
            .write(to: headers, atomically: true, encoding: .utf8)
          try download(
            address, to: destination, maximumSize: 2 * 1024 * 1024,
            remainingBytes: &remainingBytes, deadline: deadline, headers: headers
          )
          staged.append(result.name)
        } catch {
          evidence.append(
            .init(name: result.name, status: "incomplete", issue: String(describing: error)))
        }
      }
      if !staged.isEmpty {
        evidence += try resolve(phase: "resolve", names: staged, scratch: scratch)
      }
    } catch {
      failure = String(describing: error)
    }
    if FileManager.default.fileExists(atPath: scratch.path) {
      do { try FileManager.default.removeItem(at: scratch) } catch {
        failure =
          "\(failure.map { $0 + "; " } ?? "")Scratch cleanup failed at \(scratch.path): \(error)"
      }
    }
    return SetupPackageImpact(identities: identities, evidence: evidence, issue: failure)
  }

  private func resolve(phase: String, names: [String], scratch: URL) throws
    -> [SetupPackageImpact.FormulaEvidence]
  {
    let input = scratch.appending(path: "\(phase)-input.json")
    let output = scratch.appending(path: "\(phase)-output.json")
    try JSONEncoder().encode(names).write(to: input)
    _ = try command(
      "/usr/bin/sandbox-exec",
      [
        "-D", "SCRATCH=\(try Self.sandboxPath(scratch))", "-f",
        scratch.appending(path: "resolver.sb").path,
        "/opt/homebrew/bin/brew", "ruby", scratch.appending(path: "resolver.rb").path,
        phase, input.path, output.path,
      ],
      timeout: 45,
      environment: [
        "HOMEBREW_CACHE=\(scratch.appending(path: "cache").path)",
        "HOMEBREW_TEMP=\(scratch.appending(path: "tmp").path)",
        "HOMEBREW_LOGS=\(scratch.appending(path: "logs").path)",
        "TMPDIR=\(scratch.appending(path: "tmp").path)",
        "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1",
        "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_COLOR=1",
        // Transient command-local state skips brew ruby's persistent dev-mode write.
        // The qualified brew.sh leaves this intact even when devcmdrun is absent.
        "HOMEBREW_DEV_CMD_RUN=1",
      ]
    )
    let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 256 * 1024 else {
      throw ImpactError("Native resolver output exceeded its bounds or was empty.")
    }
    return try JSONDecoder().decode(
      [SetupPackageImpact.FormulaEvidence].self, from: Data(contentsOf: output)
    )
  }

  private func download(
    _ address: String, to destination: URL, maximumSize: Int, remainingBytes: inout Int,
    deadline: Date, headers: URL? = nil
  ) throws {
    let seconds = min(20, Int(deadline.timeIntervalSinceNow))
    guard seconds > 0, remainingBytes > 0 else {
      throw ImpactError("Metadata acquisition exhausted its 180-second / 64 MiB budget.")
    }
    var arguments = [
      "-q", "--fail", "--silent", "--show-error", "--proto", "=https",
      "--connect-timeout", "5", "--max-time", String(seconds),
      "--max-filesize", String(min(maximumSize, remainingBytes)),
      "--output", destination.path,
    ]
    if let headers { arguments += ["--config", headers.path] }
    // Deliberately no redirects, retries, user curlrc, credentials or package archives.
    arguments.append(address)
    // Failed/truncated transfers consume the body budget too.
    defer {
      if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        remainingBytes = max(0, remainingBytes - size)
      }
    }
    _ = try command("/usr/bin/curl", arguments, timeout: TimeInterval(seconds + 2))
    let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= maximumSize, size <= remainingBytes else {
      throw ImpactError("Metadata response exceeded its byte bound or was empty.")
    }
  }

  static func sandboxPath(_ directory: URL) throws -> String {
    // Foundation URL normalization can retain /var; Seatbelt needs the actual
    // /private/var spelling. Resolve the created directory with POSIX realpath.
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
        ] + environment + [executable] + arguments,
        timeout: timeout
      )
    )
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
