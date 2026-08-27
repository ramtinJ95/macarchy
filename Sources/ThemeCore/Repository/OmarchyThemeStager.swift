import Darwin
import Foundation

public struct OmarchyGitHubThemeSource: Equatable, Sendable {
  public let repositoryURL: URL
  public let themeID: String

  public init(_ source: String) throws {
    guard !source.isEmpty, source.utf8.count <= 2_048 else {
      throw OmarchyThemeStagingError.invalidSourceURL(
        "The repository URL must be between 1 and 2048 bytes")
    }
    guard
      let components = URLComponents(string: source),
      components.scheme == "https",
      components.host == "github.com",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.fragment == nil
    else {
      throw OmarchyThemeStagingError.invalidSourceURL(
        "Expected a public HTTPS GitHub repository URL")
    }

    var path = components.percentEncodedPath
    if path.hasSuffix("/") {
      path.removeLast()
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty,
      !path.contains("%")
    else {
      throw OmarchyThemeStagingError.invalidSourceURL(
        "Expected https://github.com/<owner>/<repository>")
    }

    let owner = String(parts[1])
    var repository = String(parts[2])
    if repository.hasSuffix(".git") {
      repository.removeLast(4)
    }
    guard Self.isGitHubOwner(owner), Self.isGitHubRepository(repository) else {
      throw OmarchyThemeStagingError.invalidSourceURL(
        "The GitHub owner or repository name is invalid")
    }

    var derivedID = repository
    if derivedID.hasPrefix("omarchy-") {
      derivedID.removeFirst("omarchy-".count)
    }
    if derivedID.hasSuffix("-theme") {
      derivedID.removeLast("-theme".count)
    }
    derivedID = derivedID.lowercased()
    guard ThemeSchema.isThemeID(derivedID) else {
      throw OmarchyThemeStagingError.unusableThemeID(derivedID)
    }

    guard let canonicalURL = URL(string: "https://github.com/\(owner)/\(repository)") else {
      throw OmarchyThemeStagingError.invalidSourceURL(
        "The GitHub repository URL could not be canonicalized")
    }
    repositoryURL = canonicalURL
    themeID = derivedID
  }

  private static func isGitHubOwner(_ value: String) -> Bool {
    guard (1...39).contains(value.utf8.count),
      value.first != "-", value.last != "-"
    else {
      return false
    }
    return value.allSatisfy { character in
      character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }
  }

  private static func isGitHubRepository(_ value: String) -> Bool {
    guard (1...100).contains(value.utf8.count), value != ".", value != ".." else {
      return false
    }
    return value.allSatisfy { character in
      character.isASCII
        && (character.isLetter || character.isNumber
          || character == "-" || character == "_" || character == ".")
    }
  }
}

public struct StagedOmarchyTheme: Sendable {
  public let themeID: String
  public let sourceURL: URL
  public let resolvedCommit: String
  public let checkoutURL: URL
}

public enum OmarchyThemeStagingError: Error, CustomStringConvertible, Equatable, Sendable {
  case invalidSourceURL(String)
  case unusableThemeID(String)
  case stagingFilesystem(String)
  case stagingLimitExceeded(String)
  case fetchFailed(String)
  case commitResolutionFailed(String)
  case cleanupFailed(String)

  public var description: String {
    switch self {
    case .invalidSourceURL(let reason):
      "Invalid Omarchy theme source: \(reason)"
    case .unusableThemeID(let id):
      "The repository name derives unusable Macarchy theme identifier '\(id)'"
    case .stagingFilesystem(let detail):
      "Cannot prepare the temporary theme staging directory: \(detail)"
    case .stagingLimitExceeded(let detail):
      "The staged GitHub theme exceeds Macarchy's limits: \(detail)"
    case .fetchFailed(let detail):
      "Cannot fetch the GitHub theme's default branch: \(detail)"
    case .commitResolutionFailed(let detail):
      "Cannot resolve the staged GitHub theme commit: \(detail)"
    case .cleanupFailed(let detail):
      "Cannot remove the temporary theme staging directory: \(detail)"
    }
  }
}

public struct OmarchyThemeStager: Sendable {
  private static let maximumDiagnosticBytes = 4_096
  private static let maximumStagingBytes: Int64 = 256 * 1_048_576
  private static let maximumStagingEntries = 10_000
  private static let gitExecutableURL = URL(filePath: "/usr/bin/git")
  private static let gitEnvironmentRemovals: Set<String> = [
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_ALLOW_PROTOCOL",
    "GIT_COMMON_DIR",
    "GIT_CONFIG_PARAMETERS",
    "GIT_DIR",
    "GIT_EXEC_PATH",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_PROXY_COMMAND",
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_SSL_NO_VERIFY",
    "GIT_TEMPLATE_DIR",
    "GIT_WORK_TREE",
  ]

  private let temporaryRoot: URL
  private let processRunner: ProcessRunner

  public init() {
    temporaryRoot = FileManager.default.temporaryDirectory
    processRunner = .live
  }

  package init(
    temporaryRoot: URL,
    processRunner: ProcessRunner
  ) {
    self.temporaryRoot = temporaryRoot
    self.processRunner = processRunner
  }

  public func withStagedCheckout<Output>(
    from source: String,
    _ operation: (StagedOmarchyTheme) throws -> Output
  ) throws -> Output {
    let parsedSource = try OmarchyGitHubThemeSource(source)
    let sessionRoot = temporaryRoot.appending(
      path: "macarchy-theme-staging-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let checkoutURL = sessionRoot.appending(path: "checkout", directoryHint: .isDirectory)
    let isolatedHome = sessionRoot.appending(path: "home", directoryHint: .isDirectory)

    do {
      try FileManager.default.createDirectory(
        at: sessionRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.createDirectory(
        at: isolatedHome,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      try? FileManager.default.removeItem(at: sessionRoot)
      throw OmarchyThemeStagingError.stagingFilesystem(Self.bounded(error))
    }

    let environment = [
      "GIT_ASKPASS": "/usr/bin/false",
      "GIT_CONFIG_COUNT": "0",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_LFS_SKIP_SMUDGE": "1",
      "GIT_TERMINAL_PROMPT": "0",
      "HOME": isolatedHome.path,
      "SSH_ASKPASS": "/usr/bin/false",
      "XDG_CONFIG_HOME": isolatedHome.path,
    ]
    let staged: StagedOmarchyTheme
    do {
      let clone: ProcessResult
      do {
        clone = try processRunner.run(
          ProcessRequest(
            executableURL: Self.gitExecutableURL,
            arguments: [
              "-c", "core.hooksPath=/dev/null",
              "-c", "protocol.ext.allow=never",
              "-c", "protocol.file.allow=never",
              "clone",
              "--quiet",
              "--depth=1",
              "--single-branch",
              "--no-tags",
              "--no-recurse-submodules",
              "--",
              parsedSource.repositoryURL.absoluteString,
              checkoutURL.path,
            ],
            timeout: 120,
            environmentOverrides: environment,
            environmentRemovals: Self.gitEnvironmentRemovals
          )
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw OmarchyThemeStagingError.fetchFailed(Self.bounded(error))
      }
      guard clone.terminationStatus == 0 else {
        throw OmarchyThemeStagingError.fetchFailed(Self.bounded(clone.output))
      }

      try Self.validateStagingBounds(at: sessionRoot)

      let resolution: ProcessResult
      do {
        resolution = try processRunner.run(
          ProcessRequest(
            executableURL: Self.gitExecutableURL,
            arguments: [
              "-c", "core.hooksPath=/dev/null",
              "-C", checkoutURL.path,
              "rev-parse", "--verify", "HEAD^{commit}",
            ],
            timeout: 10,
            environmentOverrides: environment,
            environmentRemovals: Self.gitEnvironmentRemovals
          )
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw OmarchyThemeStagingError.commitResolutionFailed(Self.bounded(error))
      }
      guard resolution.terminationStatus == 0, Self.isSHA1Commit(resolution.output) else {
        throw OmarchyThemeStagingError.commitResolutionFailed(
          Self.bounded(resolution.output))
      }

      staged = StagedOmarchyTheme(
        themeID: parsedSource.themeID,
        sourceURL: parsedSource.repositoryURL,
        resolvedCommit: resolution.output.lowercased(),
        checkoutURL: checkoutURL
      )
    } catch {
      try? FileManager.default.removeItem(at: sessionRoot)
      throw error
    }

    let callbackResult: Result<Output, Error>
    do {
      callbackResult = .success(try operation(staged))
    } catch {
      callbackResult = .failure(error)
    }
    do {
      try FileManager.default.removeItem(at: sessionRoot)
    } catch {
      if case .success = callbackResult {
        throw OmarchyThemeStagingError.cleanupFailed(Self.bounded(error))
      }
    }
    return try callbackResult.get()
  }

  private static func validateStagingBounds(at root: URL) throws {
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw OmarchyThemeStagingError.stagingFilesystem(
        "Cannot inspect the staged checkout")
    }

    var entries = 0
    var bytes: Int64 = 0
    for case let child as URL in enumerator {
      try Task.checkCancellation()
      entries += 1
      guard entries <= maximumStagingEntries else {
        throw OmarchyThemeStagingError.stagingLimitExceeded(
          "more than \(maximumStagingEntries) filesystem entries")
      }

      var metadata = stat()
      guard lstat(child.path, &metadata) == 0 else {
        throw OmarchyThemeStagingError.stagingFilesystem(
          "Cannot inspect staged entry '\(child.lastPathComponent)': \(String(cString: strerror(errno)))"
        )
      }
      guard metadata.st_mode & S_IFMT != S_IFDIR else { continue }
      let (next, overflow) = bytes.addingReportingOverflow(max(0, metadata.st_size))
      guard !overflow, next <= maximumStagingBytes else {
        throw OmarchyThemeStagingError.stagingLimitExceeded(
          "more than 256 MiB of files")
      }
      bytes = next
    }
    if let enumerationError {
      throw OmarchyThemeStagingError.stagingFilesystem(Self.bounded(enumerationError))
    }
  }

  private static func isSHA1Commit(_ value: String) -> Bool {
    value.utf8.count == 40
      && value.allSatisfy { character in
        character.isASCII && (character.isNumber || ("a"..."f").contains(character.lowercased()))
      }
  }

  private static func bounded(_ error: any Error) -> String {
    bounded(String(describing: error))
  }

  private static func bounded(_ value: String) -> String {
    let sanitized = String(
      value.unicodeScalars.map { scalar in
        if scalar.value == 9 || scalar.value == 10
          || !CharacterSet.controlCharacters.contains(scalar)
        {
          return Character(String(scalar))
        }
        return Character(" ")
      })
    guard sanitized.utf8.count > maximumDiagnosticBytes else {
      return sanitized.isEmpty ? "no diagnostic output" : sanitized
    }
    var prefix = Data(sanitized.utf8.prefix(maximumDiagnosticBytes - 3))
    while String(data: prefix, encoding: .utf8) == nil {
      prefix.removeLast()
    }
    return String(data: prefix, encoding: .utf8)! + "..."
  }
}
