import Foundation

public struct ThemeRepository: Sendable {
  private let builtInRoot: URL
  private let userRoot: URL?

  public init(builtInRoot: URL, userRoot: URL? = nil) {
    self.builtInRoot = builtInRoot
    self.userRoot = userRoot
  }

  public func packages() throws -> [ThemePackage] {
    var packages: [ThemePackage] = []
    for root in [builtInRoot, userRoot].compactMap({ $0 }) {
      let children: [URL]
      do {
        children = try FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      } catch {
        let cocoaError = error as NSError
        if root == userRoot,
          cocoaError.domain == NSCocoaErrorDomain,
          [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code)
        {
          continue
        }
        throw ThemeDiagnostic(
          location: .init(file: root),
          message: "Cannot discover theme packages: \(error.localizedDescription)")
      }

      for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let values = try child.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { continue }
        packages.append(try ThemePackageLoader().load(packageURL: child))
      }
    }

    var seen: [String: URL] = [:]
    for package in packages {
      if let first = seen[package.id] {
        throw ThemeDiagnostic(
          location: .init(file: package.packageURL.appending(path: "theme.toml")),
          field: "id",
          message: "Duplicate theme identifier '\(package.id)'; first declared by \(first.path)"
        )
      }
      seen[package.id] = package.packageURL
    }

    return packages.sorted(by: { $0.id < $1.id })
  }

  public func package(id: String) throws -> ThemePackage {
    let available = try packages()
    guard let package = available.first(where: { $0.id == id }) else {
      throw ThemeDiagnostic(
        location: .init(file: builtInRoot),
        field: "id",
        message: "Unknown theme '\(id)'; available: \(available.map(\.id).joined(separator: ", "))"
      )
    }
    return package
  }
}
