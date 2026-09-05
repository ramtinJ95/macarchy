/// The strict labeled triplet shared by Codex and Herdr, not general SemVer.
enum AdapterVersionParser {
  static func parse(_ output: String, executableLabel: String) -> [Int]? {
    let tokens = output.split(whereSeparator: \Character.isWhitespace)
    guard tokens.count == 2, tokens[0] == executableLabel else { return nil }
    let components = tokens[1].split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    else { return nil }
    let version = components.compactMap { Int($0) }
    return version.count == 3 ? version : nil
  }
}
