import Foundation

/// The strict labeled triplet shared by Codex and Herdr, not general SemVer.
enum AdapterVersionParser {
  static func parse(_ output: String, executableLabel: String) -> [Int]? {
    let tokens = output.split(whereSeparator: \Character.isWhitespace)
    guard tokens.count == 2, tokens[0] == executableLabel else { return nil }
    guard let version = parseDottedVersion(tokens[1]), version.count == 3 else { return nil }
    return version
  }

  /// Runs `--version` and returns the normalized triplet when it is at least `minimumVersion`.
  static func supportedVersion<Failure: Error>(
    executableURL: URL,
    executableLabel: String,
    minimumVersion: String,
    processRunner: ProcessRunner,
    invalid: (String) -> Failure,
    unsupported: (String) -> Failure
  ) throws -> String {
    let result = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: ["--version"], timeout: 2)
    )
    guard result.terminationStatus == 0,
      let version = parse(result.output, executableLabel: executableLabel)
    else {
      throw invalid(result.output)
    }
    let minimum = parse("\(executableLabel) \(minimumVersion)", executableLabel: executableLabel)!
    guard !version.lexicographicallyPrecedes(minimum) else {
      throw unsupported(result.output)
    }
    return version.map(String.init).joined(separator: ".")
  }
}
