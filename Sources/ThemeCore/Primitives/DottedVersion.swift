/// Parses dot-separated decimal components such as `1.2.3`. Every component must be non-empty and
/// all digits, so signs, `v` prefixes and pre-release suffixes are rejected. Callers own the
/// component count and any token extraction around the version.
package func parseDottedVersion(_ value: some StringProtocol) -> [Int]? {
  var parsed: [Int] = []
  for component in value.split(separator: ".", omittingEmptySubsequences: false) {
    guard !component.isEmpty, component.allSatisfy(\.isNumber), let number = Int(component) else {
      return nil
    }
    parsed.append(number)
  }
  return parsed
}
