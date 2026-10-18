import ArgumentParser

/// A duration option written as `<n>h`, `<n>m` or `<n>h<n>m`, from one minute to its maximum.
struct DurationOption: Sendable {
  /// Names the option in errors, such as `--for`.
  let flag: String
  let maximumMinutes: Int

  func parse(_ text: String) throws -> Duration {
    let invalid = ValidationError(
      "\(flag) takes a duration from 1m to \(Self.format(minutes: maximumMinutes)), such as 30m, "
        + "2h or 1h30m; got '\(text)'")
    let scale: [Character: Int] = ["h": 60, "m": 1]
    var minutes = 0
    var digits = ""
    var lastUnit: Character?
    for character in text {
      if character.isASCII, character.isNumber {
        digits.append(character)
        continue
      }
      guard let unit = scale[character], let value = Int(digits), digits.count <= 4,
        lastUnit == nil || (lastUnit == "h" && character == "m")
      else { throw invalid }
      minutes += value * unit
      digits = ""
      lastUnit = character
    }
    guard digits.isEmpty, lastUnit != nil, (1...maximumMinutes).contains(minutes) else {
      throw invalid
    }
    return .seconds(minutes * 60)
  }

  private static func format(minutes: Int) -> String {
    let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
    if hours == 0 { return "\(rest)m" }
    return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
  }
}
