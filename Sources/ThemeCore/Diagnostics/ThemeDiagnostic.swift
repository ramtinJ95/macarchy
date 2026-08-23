import Foundation

public struct ThemeSourceLocation: Sendable {
  public let file: URL
  public let line: Int?
  public let column: Int?

  public init(file: URL, line: Int? = nil, column: Int? = nil) {
    self.file = file
    self.line = line
    self.column = column
  }
}

public struct ThemeDiagnostic: Error, CustomStringConvertible, Sendable {
  public let location: ThemeSourceLocation
  public let field: String?
  public let message: String

  public init(location: ThemeSourceLocation, field: String? = nil, message: String) {
    self.location = location
    self.field = field
    self.message = message
  }

  public var description: String {
    var prefix = location.file.path
    if let line = location.line {
      prefix += ":\(line)"
      if let column = location.column {
        prefix += ":\(column)"
      }
    }

    let fieldSuffix = field.map { " [\($0)]" } ?? ""
    return "\(prefix): \(message)\(fieldSuffix)"
  }
}
