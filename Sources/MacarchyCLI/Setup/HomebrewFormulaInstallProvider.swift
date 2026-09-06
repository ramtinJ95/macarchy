import Foundation
import ThemeCore

struct HomebrewFormulaInstallEffects: Codable, Equatable, Sendable {
  struct Component: Codable, Equatable, Sendable {
    let name: String
    let version: String
    let sha256: String
    let dependencies: [String]
  }
  struct Link: Codable, Equatable, Sendable {
    let path: String
    let target: String
  }
  struct PathEvidence: Codable, Equatable, Sendable {
    let path: String
    let device: UInt64?
    let inode: UInt64?
    let mode: UInt32?
  }
  let components: [Component]
  let links: [Link]
  let directories: [String]
  let footprint: [PathEvidence]
  let dependentIssue: String?

  func verifiedComponents(in observation: HomebrewPackageObservation) -> [String] {
    guard observation.issues.isEmpty else { return [] }
    return components.compactMap { component in
      let matches = observation.packages.filter {
        $0.kind == .formula && $0.token == component.name
      }
      guard matches.count == 1, let package = matches.first,
        package.identity == .init(kind: .formula, name: component.name), package.issue == nil,
        package.versions == [component.version], !package.receipts.isEmpty
      else { return nil }
      let keg = "/opt/homebrew/Cellar/\(component.name)/\(component.version)"
      let expected = links.filter { $0.target == keg || $0.target.hasPrefix(keg + "/") }
      guard !expected.isEmpty,
        expected.allSatisfy({ link in
          guard let value = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
          else { return false }
          return URL(
            filePath: value, relativeTo: URL(filePath: link.path).deletingLastPathComponent()
          )
          .standardizedFileURL.path == link.target
        })
      else { return nil }
      return component.name
    }
  }

  func validate(roots: [String]) throws {
    if let dependentIssue { throw SetupPackageAdoptionError(dependentIssue) }
    let names = Set(components.map(\.name))
    guard !roots.isEmpty, !components.isEmpty, components.count <= 64,
      names.count == components.count, roots.allSatisfy(names.contains),
      components.allSatisfy({
        HomebrewPackageIdentity.validToken($0.name) && !$0.version.isEmpty
          && !$0.version.contains("/") && $0.version != "." && $0.version != ".."
          && $0.sha256.count == 64 && $0.sha256.allSatisfy { $0.isASCII && $0.isHexDigit }
          && $0.dependencies.allSatisfy(names.contains)
      }),
      !links.isEmpty, links.count <= 4096, Set(links.map(\.path)).count == links.count,
      footprint.count <= 8192, Set(footprint.map(\.path)).count == footprint.count,
      directories.count <= 4096, Set(directories).count == directories.count
    else { throw SetupPackageAdoptionError("Invalid complete formula effect evidence.") }
    func path(_ value: String) -> Bool {
      value.hasPrefix("/opt/homebrew/")
        && URL(filePath: value).standardizedFileURL.path == value
        && !value.contains("\0")
    }
    let absentPaths = Set(footprint.filter { $0.inode == nil }.map(\.path))
    guard
      links.allSatisfy({ link in
        path(link.path) && !link.path.hasPrefix("/opt/homebrew/Cellar/")
          && components.contains {
            let keg = "/opt/homebrew/Cellar/\($0.name)/\($0.version)"
            return link.target == keg || link.target.hasPrefix(keg + "/")
          } && path(link.target)
      }), directories.allSatisfy(path),
      footprint.allSatisfy({
        ($0.path == "/opt/homebrew" || path($0.path))
          && (($0.device == nil && $0.inode == nil && $0.mode == nil)
            || ($0.device != nil && $0.inode != nil && $0.mode != nil))
      }),
      links.allSatisfy({ absentPaths.contains($0.path) }),
      directories.allSatisfy(absentPaths.contains)
    else { throw SetupPackageAdoptionError("Formula effects escaped their qualified boundary.") }
  }
}

struct HomebrewFormulaInstallProvider: Sendable {
  struct Execution: Sendable {
    let status: Int32
    let diagnostic: String
  }
  var prepare: @Sendable ([String]) throws -> HomebrewFormulaInstallEffects
  var apply:
    @Sendable (
      [String], HomebrewFormulaInstallEffects, @Sendable () throws -> Void,
      @Sendable (Int32) throws -> Void
    ) throws -> Execution
  var verify: @Sendable (HomebrewFormulaInstallEffects, HomebrewPackageObservation) -> [String] = {
    $0.verifiedComponents(in: $1)
  }

  static func live(homeDirectory: URL) -> Self {
    let reader = HomebrewPackageImpactReader(homeDirectory: homeDirectory)
    return Self(
      prepare: { names in try reader.withSession { try $0.installationEffects(names) } },
      apply: { names, expected, revalidate, recordProcess in
        try reader.withSession { session in
          let current = try session.installationEffects(names)
          guard current == expected else {
            throw SetupPackageAdoptionError(
              "Native installation effects changed before Homebrew execution.")
          }
          try reader.validateRuntime()
          try revalidate()
          return try session.install(names, effects: current, recordProcess: recordProcess)
        }
      })
  }
}

extension HomebrewPackageImpactReader.Session {
  mutating func installationEffects(_ roots: [String]) throws -> HomebrewFormulaInstallEffects {
    struct Archive: Decodable {
      let name: String
      let dependencies: [String]
      let url: String
      let path: String
    }
    try HomebrewFormulaInstallationAdapter.script.write(
      to: scratch.appending(path: "installation.rb"), atomically: true, encoding: .utf8)
    var staged = Set<String>()
    var pending = roots.sorted()
    while !pending.isEmpty {
      guard staged.count + pending.count <= 64 else {
        throw SetupPackageAdoptionError("New dependency closure exceeds 64 formulae.")
      }
      let candidates = try resolve(pending)
      let report = SetupPackageImpact(
        identities: pending.map { .init(kind: .formula, name: $0) }, evidence: candidates)
      guard report.packages.allSatisfy({ $0.status == "resolved_dependencies" }) else {
        throw SetupPackageAdoptionError(
          report.packages.compactMap(\.issue).joined(separator: "; "))
      }
      let request = try JSONEncoder().encode(["names": pending])
      let archives = try JSONDecoder().decode(
        [Archive].self, from: native(script: "installation.rb", phase: "inspect", input: request))
      guard archives.count == pending.count, Set(archives.map(\.name)) == Set(pending) else {
        throw SetupPackageAdoptionError(
          "Native archive response changed the requested formula set.")
      }
      for archive in archives {
        try registry(archive.url, path: archive.path, archive: true)
      }
      staged.formUnion(pending)
      pending = Set(archives.flatMap(\.dependencies)).subtracting(staged).sorted()
    }
    let data = try native(
      script: "installation.rb", phase: "effects",
      input: JSONEncoder().encode(["names": staged.sorted()]))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(HomebrewFormulaInstallEffects.self, from: data)
  }

  func install(
    _ roots: [String], effects: HomebrewFormulaInstallEffects,
    recordProcess: @Sendable (Int32) throws -> Void,
    run: @escaping @Sendable (ProcessRequest, @Sendable (Int32) throws -> Void) throws -> Int32 =
      HomebrewFormulaInstallProcess.run
  ) throws
    -> HomebrewFormulaInstallProvider.Execution
  {
    try effects.validate(roots: roots)
    func literal(_ value: String) throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    var rules = [
      "(version 1)", "(allow default)", "(deny file-write*)", "(deny network*)",
      "(allow file-write* (subpath \(try literal(scratch.path))) (literal \"/dev/null\"))",
      "(allow file-write* (subpath \"/opt/homebrew/var/homebrew/locks\"))",
    ]
    for component in effects.components {
      rules.append(
        "(allow file-write* (subpath \(try literal("/opt/homebrew/Cellar/" + component.name))))")
    }
    for path in effects.directories + effects.links.map(\.path) {
      rules.append("(allow file-write* (literal \(try literal(path))))")
    }
    let sandbox = scratch.appending(path: "install.sb")
    try rules.joined(separator: "\n").write(to: sandbox, atomically: true, encoding: .utf8)
    let log = scratch.appending(path: "install.log")
    // The 128 MiB regular-file cap also covers any one extracted file; it must
    // not be smaller than the qualified aggregate expanded-payload bound.
    // Capture avoids a timed pipe's wait-before-drain seam. The shell execs brew.
    let arguments =
      [
        "-c", #"log=$1; shift; ulimit -f 262144; exec "$@" > "$log" 2>&1"#,
        "macarchy-formula-install", log.path, "/usr/bin/env", "-i",
        "HOME=\(reader.homeDirectory.path)", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL=C", "GIT_OPTIONAL_LOCKS=0",
      ] + environment + [
        "HOMEBREW_NO_AUTOREMOVE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1",
        "HOMEBREW_NO_INSTALL_UPGRADE=1", "/usr/bin/sandbox-exec", "-f", sandbox.path,
        "/opt/homebrew/bin/brew", "install", "--formula", "--no-ask", "--force-bottle",
      ] + roots.map { "homebrew/core/" + $0 }
    let status = try run(
      ProcessRequest(
        executableURL: URL(filePath: "/bin/sh"), arguments: arguments, timeout: 180), recordProcess)
    let handle = try FileHandle(forReadingFrom: log)
    defer { try? handle.close() }
    let diagnostic = String(
      decoding: try handle.read(upToCount: 16 * 1024) ?? Data(), as: UTF8.self)
    return .init(status: status, diagnostic: diagnostic)
  }
}
